defmodule PhoenixKitAgent.Telegram.Bridge do
  @moduledoc """
  What the bot does with an update it read: decides (`handle_update/3`, from
  the update alone and the link of its chat) and carries the decision out
  (`dispatch/3`).

  An update is acted on only when it is a `message` in the **private chat of
  the person who wrote it** (`Linking.chat_for_update/1`) or, where the core
  lets a chat hold a change (`PhoenixKitAgent.Config.writes?/0`), the press of
  a button under a card of the bot there; a group, a channel, an edit or a
  service update is `:ignore` (a press from a group is answered empty), as is a message
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

  A press is `{:press, ref, …}` (`PhoenixKitAgent.Telegram.Press`, in a task of
  the reply supervisor, never in the queue of the chat) after, in this order:
  the pace of the chat (ten a minute, before anything is read), the chat being
  a private one of the person who pressed, linked, and the button's data being
  `c:` or `x:` and a uuid exactly as the bot wrote it (else a toast "unknown
  button"). The age of a press is no matter: the row's own time decides.

  A linked person's message becomes a job for the serial queue of their chat
  (`PhoenixKitAgent.Telegram.ChatQueue`): `:turn` for text, `:photo` for a
  picture (a photo, or a document that is a jpeg, png or webp: the largest
  size of up to ten megabytes, with its caption as the text and the album it
  belongs to), `:voice` for a voice
  message or an audio file (written down, shown, then run as the text it
  became, in the same place of the queue), `:new` for `/new`;
  `/help` and a bare `/start` are the help; a forwarded message and anything
  else that is not text are answered with a short refusal. A voice job holds
  the file's identifier, its length and size and its format (none of the
  audio): the checks that come before the download are the job's
  (`PhoenixKitAgent.Telegram.Turn`). Nothing of an update is
  kept after this module has dealt with it, and nothing of it is logged.
  """

  alias PhoenixKit.Integrations.Telegram.Linking
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.RecipientLocale
  alias PhoenixKitAgent.Config
  alias PhoenixKitAgent.Telegram.{ChatQueue, Client, Format, Limiter, Press, Texts}

  @max_age_s 600
  # The largest size of a photo that is taken (the smallest is, when none is under it).
  @max_picture_bytes 10 * 1_048_576
  @picture_types ~w(image/jpeg image/png image/webp)

  @forwarded ~w(forward_origin forward_date forward_from forward_from_chat forward_sender_name)

  @doc "The largest picture the bot takes, in bytes."
  @spec max_picture_bytes() :: pos_integer()
  def max_picture_bytes, do: @max_picture_bytes

  @typedoc "The actor reference of core: `{:telegram_link, user_uuid, connection_uuid, chat_id}`."
  @type ref :: {:telegram_link, String.t(), String.t(), integer()}

  @typedoc """
  What the chat's queue runs; a `:voice` job also has the `voice` file, and a
  `:photo` job the `photo` (the text is its caption, or `nil`) and, for one of
  an album, the `group`.
  """
  @type job :: %{
          required(:kind) => :turn | :new | :voice,
          required(:message_id) => integer(),
          required(:text) => String.t() | nil,
          optional(:group) => String.t(),
          optional(:photo) => %{file_id: String.t(), size: integer() | nil},
          optional(:voice) => %{
            file_id: String.t(),
            duration: integer() | nil,
            size: integer() | nil,
            format: String.t() | nil
          }
        }

  @type decision ::
          :ignore
          | {:unlinked, integer()}
          | {:static, ref(), integer(), integer(), :help | :forwarded | :text_only}
          | {:job, ref(), job()}
          | {:press, ref(), Press.press()}
          | {:answer, String.t(), nil | :unknown_button | {:unlinked, integer()}}

  @doc """
  The decision for `update` read from the bot `connection_uuid`. Option
  `:now` (unix seconds) stands in for the clock.
  """
  @spec handle_update(String.t(), term(), keyword()) :: decision()
  def handle_update(connection_uuid, update, opts \\ [])

  def handle_update(connection_uuid, %{"callback_query" => query} = update, _opts)
      when is_binary(connection_uuid) do
    if Config.writes?(), do: press(connection_uuid, update, query), else: :ignore
  end

  def handle_update(connection_uuid, update, opts) when is_binary(connection_uuid) do
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

  # A press of a button (only where the core lets a chat hold a change). In
  # this order, the cheap checks first: the pace of the chat; whether it is
  # a private chat of the person who pressed; whether it is linked; the
  # data of the button. A press that is not for the bot's cards is answered
  # with nothing (an empty answer takes the "clock" off the button).
  defp press(connection_uuid, update, query) do
    callback_id = if is_binary(query["id"]), do: query["id"]

    with true <- callback_id != nil,
         true <- Limiter.allow_press?(connection_uuid, press_chat(query)),
         {:ok, chat_id} <- Linking.chat_for_update(update),
         {:ok, ref} <- linked_press(connection_uuid, update, chat_id),
         {:ok, action, uuid} <- parse_data(query["data"]),
         message_id when is_integer(message_id) <- get_in(query, ["message", "message_id"]) do
      {:press, ref,
       %{
         callback_id: callback_id,
         message_id: message_id,
         action: action,
         confirmation_uuid: uuid
       }}
    else
      :unlinked -> {:answer, callback_id, {:unlinked, press_chat(query)}}
      :bad_data -> {:answer, callback_id, :unknown_button}
      _not_for_us -> if callback_id, do: {:answer, callback_id, nil}, else: :ignore
    end
  end

  defp press_chat(%{"message" => %{"chat" => %{"id" => id}}}) when is_integer(id), do: id
  defp press_chat(_query), do: 0

  defp linked_press(connection_uuid, update, chat_id) do
    case linked_ref(connection_uuid, update, chat_id) do
      {:ok, ref} -> {:ok, ref}
      :error -> :unlinked
    end
  end

  # `c:` or `x:` and the uuid of a confirmation, in the form the bot wrote.
  defp parse_data(<<action, ?:, uuid::binary-size(36)>>) when action in [?c, ?x] do
    case Ecto.UUID.cast(uuid) do
      {:ok, ^uuid} -> {:ok, if(action == ?c, do: :confirm, else: :reject), uuid}
      _other -> :bad_data
    end
  end

  defp parse_data(_data), do: :bad_data

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

      {:press, {:telegram_link, _user, _connection, _chat} = ref, press} ->
        if start(fn -> Press.run(connection_uuid, ref, press) end) == :busy,
          do: busy_press(connection_uuid, press.callback_id)

        :ok

      {:answer, callback_id, kind} ->
        answer_press(connection_uuid, callback_id, kind)

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

  # The answer to a press the bot does not carry out: a toast only for a
  # chat that is not linked (within the pace of that answer) and for data the
  # bot never wrote; else nothing.
  defp answer_press(connection_uuid, callback_id, kind) do
    toast = press_toast(connection_uuid, kind)
    async(fn -> safely(fn -> send_answer(connection_uuid, callback_id, toast) end) end)
  end

  defp send_answer(connection_uuid, callback_id, toast) do
    in_locale(nil, fn _locale ->
      text = if toast, do: Texts.toast(toast)
      _ = Client.impl().answer_callback(connection_uuid, callback_id, text)
    end)
  end

  defp press_toast(_connection_uuid, :unknown_button), do: :unknown_button
  defp press_toast(_connection_uuid, nil), do: nil

  defp press_toast(connection_uuid, {:unlinked, chat_id}),
    do: if(Limiter.allow_unlinked_reply?(connection_uuid, chat_id), do: :unlinked)

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

  # Voice and pictures are taken only where the core can give the bot a file.
  defp kind(message) do
    cond do
      forwarded?(message) -> :forwarded
      not Client.impl().can_download?() -> :text_only
      voice(message) -> :voice
      picture(message) -> :photo
      true -> :text_only
    end
  end

  # A voice message, or an audio file: the file and what Telegram says of it.
  defp voice(message) do
    Enum.find_value(["voice", "audio"], fn key ->
      case message[key] do
        %{"file_id" => file_id} = media when is_binary(file_id) ->
          %{
            file_id: file_id,
            duration: integer_or_nil(media["duration"]),
            size: integer_or_nil(media["file_size"]),
            format: if(key == "voice", do: "ogg", else: audio_format(media["mime_type"]))
          }

        _other ->
          nil
      end
    end)
  end

  # A photo (the sizes Telegram made of it), or a document that is a picture.
  defp picture(%{"photo" => [_ | _] = sizes} = message) do
    case for(%{"file_id" => id} = size when is_binary(id) <- sizes, do: size) do
      [] -> nil
      sizes -> sizes |> pick_size() |> picture_of(message)
    end
  end

  defp picture(%{"document" => %{"file_id" => id, "mime_type" => type} = doc} = message)
       when is_binary(id) and type in @picture_types do
    picture_of(doc, message)
  end

  defp picture(_message), do: nil

  # The largest that fits (by its size in bytes, not by its place in the list);
  # else the smallest (the job refuses it as too large).
  defp pick_size(sizes) do
    case Enum.filter(sizes, &fits?/1) do
      [] -> Enum.min_by(sizes, &weight/1)
      fitting -> Enum.max_by(fitting, &weight/1)
    end
  end

  # The area first (Telegram always tells it), then the bytes.
  defp weight(size) do
    {(integer_or_nil(size["width"]) || 0) * (integer_or_nil(size["height"]) || 0),
     integer_or_nil(size["file_size"]) || 0}
  end

  defp fits?(%{"file_size" => size}) when is_integer(size), do: size <= @max_picture_bytes
  defp fits?(_size), do: true

  defp picture_of(%{"file_id" => file_id} = file, message) do
    picture = %{
      file_id: file_id,
      size: integer_or_nil(file["file_size"])
    }

    %{
      photo: picture,
      text: if(is_binary(message["caption"]), do: message["caption"]),
      group: if(is_binary(message["media_group_id"]), do: message["media_group_id"])
    }
  end

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_other), do: nil

  # The format of an audio file where its type says it; else the bytes tell.
  defp audio_format(type) when is_binary(type) do
    case String.downcase(type) do
      "audio/mpeg" -> "mp3"
      "audio/mp3" -> "mp3"
      "audio/ogg" -> "ogg"
      "audio/opus" -> "ogg"
      "audio/wav" -> "wav"
      "audio/x-wav" -> "wav"
      "audio/flac" -> "flac"
      "audio/mp4" -> "m4a"
      "audio/x-m4a" -> "m4a"
      "audio/aac" -> "aac"
      _unknown -> nil
    end
  end

  defp audio_format(_none), do: nil

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

  defp decide(:photo, ref, _chat_id, message_id, message) do
    %{photo: photo, text: caption, group: group} = picture(message)
    job = %{kind: :photo, message_id: message_id, text: caption, photo: photo}
    {:job, ref, if(group, do: Map.put(job, :group, group), else: job)}
  end

  defp decide(:voice, ref, _chat_id, message_id, message),
    do: {:job, ref, %{kind: :voice, message_id: message_id, text: nil, voice: voice(message)}}

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

      case send_part(connection_uuid, chat_id, part, []) do
        {:ok, _message} -> {:cont, :ok}
        :error -> {:halt, :error}
      end
    end)
  end

  @doc false
  # Sends a card (`text` under the inline keyboard `markup`, or without one) the
  # way `say/3` sends a text: `{:ok, message_id}` (`nil` when Telegram's answer
  # names none) or `:error`.
  @spec send_card(String.t(), integer(), String.t(), map() | nil) ::
          {:ok, integer() | nil} | :error
  def send_card(connection_uuid, chat_id, text, markup) do
    opts = if markup, do: [reply_markup: markup], else: []

    case send_part(connection_uuid, chat_id, text, opts) do
      {:ok, %{"message_id" => message_id}} when is_integer(message_id) -> {:ok, message_id}
      {:ok, _other} -> {:ok, nil}
      :error -> :error
    end
  end

  defp send_part(connection_uuid, chat_id, part, opts, retried? \\ false) do
    case Client.impl().send_message(connection_uuid, chat_id, part, opts) do
      {:ok, message} ->
        {:ok, message}

      {:error, reason} when is_binary(reason) and not retried? ->
        case retry_after_ms(reason) do
          nil ->
            failed(:refused)

          ms ->
            Process.sleep(ms)
            send_part(connection_uuid, chat_id, part, opts, true)
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
    _ = start(fun)
    :ok
  end

  # `:busy` when the reply supervisor is full.
  defp start(fun) do
    case Task.Supervisor.start_child(PhoenixKitAgent.Telegram.ReplySupervisor, fun) do
      {:error, :max_children} -> :busy
      _started -> :ok
    end
  end

  # A press that cannot be carried out for want of a place is still answered
  # (the button would spin), in a task of its own that nothing waits for.
  defp busy_press(connection_uuid, callback_id) do
    require Logger
    Logger.warning("[PhoenixKitAgent] telegram reply tasks are full: a press was not carried out")

    _ = Task.start(fn -> safely(fn -> send_answer(connection_uuid, callback_id, :busy) end) end)
    :ok
  end

  defp part_pause_ms, do: Application.get_env(:phoenix_kit_agent, :telegram_part_pause_ms, 1_000)
  defp max_retry_ms, do: Application.get_env(:phoenix_kit_agent, :telegram_max_retry_ms, 30_000)
end
