defmodule PhoenixKitAgent.Telegram.Bridge do
  @moduledoc """
  What the bot does with an update it read: decides (`handle_update/3`, from
  the update alone and the link of its chat) and carries the decision out
  (`dispatch/3`).

  An update is acted on only when it is a `message` in the **private chat of
  the person who wrote it** (`Linking.chat_for_update/1`); a group, a channel,
  an edit, a button press or a service update is `:ignore`, as is a message
  older than ten minutes (a backlog after the bot stood idle) and a `/start`
  with a link token, which `Linking.handle_updates/3` has answered already.
  The reference of the actor is `Linking.actor_ref/2` and nothing else: no
  text or button data ever builds one. A chat that is not linked (or whose
  link was reset: the two cannot be told apart) is answered once in ten
  minutes, with a budget of twenty such answers a minute for the bot
  (`PhoenixKitAgent.Telegram.Limiter`).

  The answers that need no turn run under their own task supervisor
  (`PhoenixKitAgent.Telegram.ReplySupervisor`), so they cannot take the place
  of a turn. `handle_update/3` reads the database (the link) and remembers an
  unlinked chat in the limiter's table, but changes nothing else and sends
  nothing.

  A linked person's message becomes a job for the serial queue of their chat
  (`PhoenixKitAgent.Telegram.ChatQueue`): `:turn` for text, `:new` for `/new`;
  `/help` and a bare `/start` are the help; a forwarded message and anything
  that is not text are answered with a short refusal. Nothing of an update is
  kept after this module has dealt with it, and nothing of it is logged.
  """

  alias PhoenixKit.Integrations.Telegram.Linking
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.RecipientLocale
  alias PhoenixKitAgent.Telegram.{ChatQueue, Client, Format, Limiter, Texts}

  @max_age_s 600

  @forwarded ~w(forward_origin forward_date forward_from forward_from_chat forward_sender_name)

  @typedoc "The actor reference of core: `{:telegram_link, user_uuid, connection_uuid, chat_id}`."
  @type ref :: {:telegram_link, String.t(), String.t(), integer()}

  @type decision ::
          :ignore
          | {:unlinked, integer()}
          | {:static, ref(), integer(), integer(), :help | :forwarded | :text_only}
          | {:job, ref(), %{kind: :turn | :new, message_id: integer(), text: String.t() | nil}}

  @doc """
  The decision for `update` read from the bot `connection_uuid`. Option
  `:now` (unix seconds) stands in for the clock.
  """
  @spec handle_update(String.t(), term(), keyword()) :: decision()
  def handle_update(connection_uuid, update, opts \\ []) when is_binary(connection_uuid) do
    now = Keyword.get(opts, :now, System.system_time(:second))

    with %{"message" => %{"message_id" => message_id} = message} when is_integer(message_id) <-
           update,
         {:ok, chat_id} <- Linking.chat_for_update(update),
         true <- fresh?(message, now),
         kind when kind != :ignore <- kind(message) do
      case linked_ref(connection_uuid, update, chat_id) do
        {:ok, ref} -> decide(kind, ref, chat_id, message_id, message)
        :error -> {:unlinked, chat_id}
      end
    else
      _not_for_us -> :ignore
    end
  end

  @doc """
  Carries `handle_update/3` out: queues the job, or answers in a task of its
  own (a call to Telegram never holds the reader). An answer that cannot be
  started or queued is dropped silently, but for the "busy" ones.
  """
  @spec dispatch(String.t(), term(), keyword()) :: :ok
  def dispatch(connection_uuid, update, opts \\ []) do
    case handle_update(connection_uuid, update, opts) do
      :ignore ->
        :ok

      {:unlinked, chat_id} ->
        if Limiter.allow_unlinked_reply?(connection_uuid, chat_id) do
          async(fn -> reply(connection_uuid, chat_id, nil, :unlinked, nil) end)
        end

        :ok

      {:static, {:telegram_link, user_uuid, _, chat_id}, chat_id, message_id, kind} ->
        quick_reply(connection_uuid, chat_id, user_uuid, kind, message_id)

      {:job, {:telegram_link, user_uuid, _, chat_id} = ref, job} ->
        case ChatQueue.submit(connection_uuid, ref, job) do
          :ok ->
            :ok

          :full ->
            quick_reply(connection_uuid, chat_id, user_uuid, :wait, job.message_id)

          :busy ->
            quick_reply(connection_uuid, chat_id, user_uuid, :bot_busy, job.message_id)
        end
    end
  end

  # The answer of a linked person that needs no turn: once in a few seconds
  # for a chat and a kind of answer (a flood of `/help` is not answered each time), and never on
  # the supervisor that runs the turns.
  defp quick_reply(connection_uuid, chat_id, user_uuid, kind, message_id) do
    if Limiter.allow_quick_reply?(connection_uuid, chat_id, kind),
      do: async(fn -> reply(connection_uuid, chat_id, user_uuid, kind, message_id) end),
      else: :ok
  end

  @doc false
  # The "bot is busy" answer for a job that could not be run.
  @spec busy(String.t(), ref(), map()) :: :ok
  def busy(connection_uuid, {:telegram_link, user_uuid, _, chat_id}, job),
    do: async(fn -> reply(connection_uuid, chat_id, user_uuid, :bot_busy, job.message_id) end)

  @doc """
  The locale to speak to `user_uuid` in: theirs, else the site's; the site's
  for a stranger (`nil`).
  """
  @spec locale(String.t() | nil) :: String.t()
  def locale(nil), do: RecipientLocale.for_rendering(nil)

  def locale(user_uuid) when is_binary(user_uuid) do
    RecipientLocale.for_rendering(Auth.get_user(user_uuid))
  rescue
    _ -> RecipientLocale.for_rendering(nil)
  end

  @doc "Runs `fun` with the language of `user_uuid` installed (see `locale/1`)."
  @spec in_locale(String.t() | nil, (String.t() -> result)) :: result when result: term()
  def in_locale(user_uuid, fun) do
    locale = locale(user_uuid)
    RecipientLocale.in_locale(locale, fn -> fun.(locale) end)
  end

  # ── the decision ──────────────────────────────────────────────────

  defp fresh?(%{"date" => date}, now) when is_integer(date), do: now - date <= @max_age_s
  defp fresh?(_message, _now), do: false

  # What a message is; `:ignore` for a `/start` that carries a token.
  defp kind(%{"text" => text} = message) when is_binary(text) do
    if forwarded?(message), do: :forwarded, else: text_kind(text)
  end

  defp kind(message), do: if(forwarded?(message), do: :forwarded, else: :text_only)

  defp text_kind(text) do
    case Regex.run(~r/\A\/([A-Za-z0-9_]+)(?:@[A-Za-z0-9_]+)?(?:\s+(.*))?\z/su, text) do
      [_, "start", args] -> if String.trim(args) == "", do: :help, else: :ignore
      [_, "start"] -> :help
      [_, "help" | _] -> :help
      [_, "new" | _] -> :new
      _plain_text -> :turn
    end
  end

  defp forwarded?(message), do: Enum.any?(@forwarded, &Map.has_key?(message, &1))

  defp linked_ref(connection_uuid, update, chat_id) do
    if Limiter.unlinked?(connection_uuid, chat_id) do
      :error
    else
      case Linking.actor_ref(connection_uuid, update) do
        {:ok, ref} ->
          {:ok, ref}

        :error ->
          Limiter.put_unlinked(connection_uuid, chat_id)
          :error
      end
    end
  end

  defp decide(kind, ref, chat_id, message_id, _message)
       when kind in [:help, :forwarded, :text_only],
       do: {:static, ref, chat_id, message_id, kind}

  defp decide(:new, ref, _chat_id, message_id, _message),
    do: {:job, ref, %{kind: :new, message_id: message_id, text: nil}}

  defp decide(:turn, ref, _chat_id, message_id, %{"text" => text}),
    do: {:job, ref, %{kind: :turn, message_id: message_id, text: text}}

  # ── the replies that need no turn ─────────────────────────────────

  defp reply(connection_uuid, chat_id, user_uuid, kind, message_id) do
    safely(fn ->
      in_locale(user_uuid, fn _locale ->
        say(connection_uuid, chat_id, Texts.static(kind))
        if message_id && kind != :help, do: react(connection_uuid, chat_id, message_id, "🤷")
      end)
    end)
  end

  @doc false
  # Sends `text` (cut into messages), with one more try when Telegram says to
  # wait. Only the kind of a failure is logged.
  @spec say(String.t(), integer(), String.t()) :: :ok | :error
  def say(connection_uuid, chat_id, text) do
    text
    |> Format.chunks()
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {part, index}, :ok ->
      if index > 0, do: Process.sleep(part_pause_ms())

      case send_part(connection_uuid, chat_id, part) do
        :ok -> {:cont, :ok}
        :error -> {:halt, :error}
      end
    end)
  end

  defp send_part(connection_uuid, chat_id, part, retried? \\ false) do
    case Client.impl().send_message(connection_uuid, chat_id, part) do
      {:ok, _message} ->
        :ok

      {:error, reason} when is_binary(reason) and not retried? ->
        case retry_after_ms(reason) do
          nil ->
            failed(:refused)

          ms ->
            Process.sleep(ms)
            send_part(connection_uuid, chat_id, part, true)
        end

      {:error, reason} ->
        failed(if(reason == :unreachable, do: :unreachable, else: :refused))
    end
  end

  defp retry_after_ms(description) do
    case Regex.run(~r/\Atoo many requests.*retry after (\d+)/i, description) do
      [_, seconds] -> min(String.to_integer(seconds) * 1_000, max_retry_ms())
      _other -> nil
    end
  end

  defp failed(kind) do
    require Logger
    Logger.warning("[PhoenixKitAgent] telegram send failed: #{kind}")
    :error
  end

  @doc false
  # A reaction; the message may be gone, which is no matter.
  @spec react(String.t(), integer(), integer(), String.t() | nil) :: :ok
  def react(connection_uuid, chat_id, message_id, emoji) do
    _ = Client.impl().react(connection_uuid, chat_id, message_id, emoji)
    :ok
  end

  @doc false
  # Runs `fun`; an exception is logged by its class and nothing else.
  @spec safely((-> term())) :: :ok
  def safely(fun) do
    fun.()
    :ok
  rescue
    exception -> log_crash(exception.__struct__)
  catch
    kind, _reason -> log_crash(kind)
  end

  defp log_crash(kind) do
    require Logger
    Logger.warning("[PhoenixKitAgent] telegram reply failed: #{inspect(kind)}")
    :ok
  end

  defp async(fun) do
    _ = Task.Supervisor.start_child(PhoenixKitAgent.Telegram.ReplySupervisor, fun)
    :ok
  end

  defp part_pause_ms, do: Application.get_env(:phoenix_kit_agent, :telegram_part_pause_ms, 1_000)
  defp max_retry_ms, do: Application.get_env(:phoenix_kit_agent, :telegram_max_retry_ms, 30_000)
end
