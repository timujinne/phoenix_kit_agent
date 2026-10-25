defmodule PhoenixKitAgent.Turns do
  @moduledoc """
  A turn of the assistant (spec §6.1): the user's message, then rounds of
  model calls and tool calls until the model answers, or until a write waits
  for the user's confirmation (`PhoenixKitAgent.Confirmations`).

  Like `PhoenixKitAgent.Conversations`, every function acts for a **live
  browser session** — the `{session_token_uuid, user_uuid}` reference of
  `PhoenixKit.Users.Auth.SessionRef.from_session/1` — and takes the answer of
  `PhoenixKitWeb.Users.MultiSession.impersonated?/1` for it, a boolean (anything
  else raises `ArgumentError`). An impersonated session is refused before
  anything is read or written.

  `start/6`, in order (the first failure is the answer; a start that fails
  leaves no lock behind and writes nothing to the chat — except for a limit
  reached, below):

    0-1. the checks of `Conversations` — impersonation, the session's scope,
         the `agent` permission, the module and the user's switch, the chat is
         the user's;
       - a non-blank message of at most `agent_history_chars` characters, the
         AI module on, an endpoint chosen (the user's own, else
         `agent_default_endpoint_uuid`; `PhoenixKitAgent.UserConfig`), no more
         attachments than `max_attachments_per_message` allows, and each one
         ready, the user's own, of this chat and not sent yet
         (`PhoenixKitAgent.Attachments`);
    2. the locks (`PhoenixKitAgent.Turns.Locks`): one turn per chat
       (`:conversation_busy`) and per user (`:turn_in_flight`, or
       `:click_in_flight` while a click on a confirmation card runs); the history
       is read only once they are taken, so it holds the previous turn's end;
    3. the limits (`PhoenixKitAgent.Limits.check/3`), under the locks: the
       user's previous turn is over, so all it spent is in the AI journal. A
       limit used up is `{:error, {:limit_reached, kind}}`: the locks are
       released, the model is not called, the user's text is not stored, and
       — the one refusal that writes — a `notice` goes into the chat (error
       `daily_cost_limit`, `monthly_cost_limit` or `daily_turn_limit`) and the
       limit is announced (`PhoenixKitAgent.Limits.announce_reached/2`);
    3a. the AI guard admits the turn (`PhoenixKitAI.Guard.admit/4`, task
       `agent.chat`, for as long as the turn's lock may live): the user's
       block (`{:error, :task_blocked}`) and the task's own limits
       (`{:error, :task_limit_exceeded}`) are checked here once, and the
       rounds pass the admission on (`guard_admission:`), so a turn admitted
       before a block or a limit runs to its end. A refusal is like a limit
       reached: nothing runs or is stored but a `notice` (error
       `task_blocked` or `task_limit_exceeded`), once a day per chat (a
       monthly limit: once a month); an answer of the guard this module does
       not know starts no turn either (`model_error`, a log line without
       it);
    4. the task starts (`PhoenixKitAgent.Turns.Monitor`), and `{:ok,
       turn_ref}` is returned; there the user message is stored (and the
       attachments linked to it), then the rounds run
       (`PhoenixKitAgent.Turns.Runner`). A turn that started under its limits
       runs to its end.

  The chat's topic (`Conversations.topic/1`) hears every stored message
  (`{:agent_message_added, conversation_uuid, message_uuid}`) and the end of
  the turn (`{:agent_turn_finished, conversation_uuid, turn_ref}`), after its
  locks are released. A listener matches the `turn_ref` it got from
  `start/6`: a start that failed half-way is announced as finished too.

  A refusal never carries turn data: an unavailable monitor or a task that
  did not start is `{:monitor_unavailable, class}` / `{:not_started, class}`
  with only the class of the exit (`t:PhoenixKitAgent.Turns.Monitor.exit_class/0`).
  NUL characters are cut from the text before anything else.

  The assistant acts with the session's rights only: tools are listed and run
  by `PhoenixKit.API.Executor.visible_for/3` / `execute_as/5` with `allow:
  :all`, for this session; there is no service user and no API key. A write
  is never run by the turn: core holds it for the user's click
  (`PhoenixKitAgent.Turns.Runner`, "A write"), and only modules that let a
  session write (core's `api_session_write_modules`) show any.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKit.PubSub.Manager, as: PubSub
  alias PhoenixKit.RepoHelper
  alias PhoenixKitAgent.{Config, Confirmations, Conversations, Limits, Prompt, Spend, UserConfig}
  alias PhoenixKitAgent.Schemas.{Attachment, Conversation, Message}
  alias PhoenixKitAgent.Turns.{History, Locks, Monitor, Runner}

  @registry PhoenixKitAgent.Turns.Registry

  # A lock outlives the deadline of its turn by this much before another turn
  # may take it over (spec §6.1 step 3).
  @lock_grace_s 60

  @typedoc "Why a turn was not started, or not stopped."
  @type refusal ::
          Conversations.refusal()
          | :empty_message
          | :message_too_long
          | :ai_disabled
          | :no_endpoint
          | :invalid_attachments
          | :too_many_attachments
          | :conversation_busy
          | :turn_in_flight
          | :click_in_flight
          | {:limit_reached, Limits.kind()}
          | :task_blocked
          | :task_limit_exceeded
          | :model_error
          | :not_running
          | {:not_started, Monitor.exit_class()}
          | {:monitor_unavailable, Monitor.exit_class()}

  @doc """
  Starts a turn in the user's chat with `text` and the attachments
  `attachment_uuids` (see the moduledoc). Returns `{:ok, turn_ref}` as soon as
  the turn runs; its first act is to store the user message (the chat's topic
  hears it).

  Options:

    * `:request_context` — what the tools' handlers get as context
      (`PhoenixKit.API.Executor.execute_as/5`): `:language`, `:base_url`,
      `:hosts`, `:currency`, `:ip`; `:request_id` defaults to the turn ref;
    * `:deadline_ms` — a shorter deadline than `agent_turn_deadline_s`; it can
      only shorten it;
    * `:page` — where the user is, for the model's context: the page's path
      (what the host says of it comes from its `page_context` hook, called
      with this session's scope — `PhoenixKitAgent.Prompt`);
    * `:locale` — the user's locale; else the `:language` of the request
      context, else the process's Gettext locale. Both come from a browser and
      are checked by `PhoenixKitAgent.Prompt`.
  """
  @spec start(Conversations.session_ref(), boolean(), term(), term(), [term()], keyword()) ::
          {:ok, String.t()} | {:error, refusal()}
  def start(
        session_ref,
        impersonated?,
        conversation_uuid,
        text,
        attachment_uuids \\ [],
        opts \\ []
      )
      when is_list(attachment_uuids) and is_list(opts) do
    with {:ok, conversation} <-
           Conversations.owned_conversation(session_ref, conversation_uuid,
             impersonated: impersonated?
           ),
         {:ok, text} <- message_text(text),
         {:ok, scope} <- Conversations.authorized_scope(session_ref, impersonated: impersonated?),
         :ok <- ai_enabled(),
         settings = UserConfig.effective(conversation.user_uuid),
         {:ok, endpoint_uuid} <- endpoint(settings),
         :ok <- attachment_count(settings, attachment_uuids),
         {:ok, attachments} <- new_attachments(conversation, attachment_uuids) do
      user = %{scope: scope, settings: settings, endpoint_uuid: endpoint_uuid}
      launch(session_ref, conversation, text, attachments, user, opts)
    end
  end

  @doc """
  Stops the turn running in the user's chat. The turn is asked to stop and
  ends at its next step — a model call under way is let finish, so the AI
  journal records what it cost, but its answer is not kept — or is killed if
  it has not stopped within the grace period
  (`PhoenixKitAgent.Turns.Monitor`). Its locks are then released and the
  chat's topic hears `:agent_turn_finished`; `:ok` means the request was
  made. With `turn_ref`, only that turn is stopped — a newer one in the chat
  keeps running. `{:error, :not_running}` when no such turn runs there (or
  the monitor is restarting); someone else's chat is `{:error, :not_found}`.

  Who may stop is checked here, with the session's scope as it is now; the
  turn is the one the chat's lock names. When its task is not on this node
  while the lock is younger than its TTL, the turn may run on another node:
  the request goes out over PubSub (`PhoenixKitAgent.Turns.Monitor.broadcast_stop/1`,
  the turn ref only) and `:ok` is returned — the node that runs the turn stops
  it the same way, and the chat's topic hears its end. A lock past its TTL is
  a turn no node runs: `{:error, :not_running}`.
  """
  @spec stop(Conversations.session_ref(), boolean(), term(), String.t() | nil) ::
          :ok | {:error, refusal()}
  def stop(session_ref, impersonated?, conversation_uuid, turn_ref \\ nil) do
    with {:ok, user_uuid} <-
           Conversations.authorize_session(session_ref, impersonated: impersonated?),
         {:ok, conversation_uuid, running} <- running_turn(user_uuid, conversation_uuid),
         :ok <- same_turn(running, turn_ref) do
      case Registry.lookup(@registry, running) do
        [{pid, ^conversation_uuid}] ->
          Monitor.request_stop(pid, :stopped)

        [] ->
          stop_elsewhere(conversation_uuid, running)

        _another_chats ->
          {:error, :not_running}
      end
    end
  end

  @doc """
  What became of the turn the user's chat is locked by, for a client that
  opens the chat (decision of 2026-10-20, spec §6.1): `{:ok, :idle}` — no
  turn; `{:ok, {:running, turn_ref}}` — a turn runs (its task is here, or its
  lock is younger than its TTL: it may run on another node);
  `{:ok, :interrupted}` — the turn was lost (its node went down, its monitor
  with it): its lock is older than the TTL and no task runs it here, so its
  locks are released, the chat gets the notice "the answer was interrupted"
  (error `interrupted`) and its topic hears `{:agent_turn_finished,
  conversation_uuid, turn_ref}`. Of two clients that open the chat at once,
  only one writes the notice. Refusals are those of `Conversations`.
  """
  @spec settle_interrupted(Conversations.session_ref(), boolean(), term()) ::
          {:ok, :idle | :interrupted | {:running, String.t()}} | {:error, refusal()}
  def settle_interrupted(session_ref, impersonated?, conversation_uuid) do
    with {:ok, conversation} <-
           Conversations.owned_conversation(session_ref, conversation_uuid,
             impersonated: impersonated?
           ) do
      {:ok, settle(conversation)}
    end
  end

  defp settle(%Conversation{busy_turn_ref: nil}), do: :idle

  defp settle(%Conversation{busy_turn_ref: turn_ref} = conversation) do
    cond do
      Registry.lookup(@registry, turn_ref) != [] ->
        {:running, turn_ref}

      Locks.release_stale(conversation.user_uuid, conversation.uuid, turn_ref, lock_ttl_s()) ->
        interrupted(conversation, turn_ref)
        :interrupted

      true ->
        # Not stale, or released (or taken) since the row was read.
        case busy_turn_ref(conversation.user_uuid, conversation.uuid) do
          {:ok, running} -> {:running, running}
          {:error, _none} -> :idle
        end
    end
  end

  defp interrupted(conversation, turn_ref) do
    _ =
      Conversations.add_turn_message(conversation.user_uuid, conversation.uuid, %{
        turn_ref: turn_ref,
        role: "notice",
        content: "The answer was interrupted. Try again.",
        error: "interrupted"
      })

    PubSub.broadcast(
      Conversations.topic(conversation.uuid),
      {:agent_turn_finished, conversation.uuid, turn_ref}
    )
  end

  # ── start ───────────────────────────────────────────────────────

  # The current message always goes to the model whole (spec §6.6), so it may
  # not be longer than the whole history window.
  defp message_text(text) when is_binary(text) do
    text = Message.strip_nul(text)

    cond do
      String.trim(text) == "" -> {:error, :empty_message}
      String.length(text) > Config.history_chars() -> {:error, :message_too_long}
      true -> {:ok, text}
    end
  end

  defp message_text(_not_text), do: {:error, :empty_message}

  defp ai_enabled, do: if(PhoenixKitAI.enabled?(), do: :ok, else: {:error, :ai_disabled})

  # The user's own model, else the module's (spec §7.2), as of this start: a
  # change takes effect with the next turn of any chat.
  defp endpoint(%{endpoint_uuid: nil}), do: {:error, :no_endpoint}
  defp endpoint(%{endpoint_uuid: uuid}), do: {:ok, uuid}

  # No more files than the user may send in one message (their own limit, else
  # the module's), whatever was accepted when they were uploaded.
  defp attachment_count(settings, uuids) do
    if length(Enum.uniq(uuids)) <= settings.max_attachments_per_message,
      do: :ok,
      else: {:error, :too_many_attachments}
  end

  # Every uuid must name a ready attachment of this user in this chat that is
  # not part of a message yet.
  defp new_attachments(_conversation, []), do: {:ok, []}

  defp new_attachments(conversation, uuids) do
    with {:ok, uuids} <- cast_uuids(uuids) do
      found =
        repo().all(
          from(a in Attachment,
            where:
              a.uuid in ^uuids and a.user_uuid == ^conversation.user_uuid and
                a.conversation_uuid == ^conversation.uuid and is_nil(a.message_uuid) and
                a.status == "ready",
            order_by: [asc: a.inserted_at, asc: a.uuid]
          )
        )

      if length(found) == length(uuids), do: {:ok, found}, else: {:error, :invalid_attachments}
    end
  end

  defp cast_uuids(uuids) do
    uuids
    |> Enum.reduce_while([], fn uuid, acc ->
      case Ecto.UUID.cast(uuid) do
        {:ok, uuid} -> {:cont, [uuid | acc]}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      :error -> {:error, :invalid_attachments}
      cast -> {:ok, cast |> Enum.reverse() |> Enum.uniq()}
    end
  end

  defp launch(session_ref, conversation, text, attachments, user, opts) do
    turn_ref = UUIDv7.generate()

    with :ok <- Locks.acquire(conversation.user_uuid, conversation.uuid, turn_ref, lock_ttl_s()) do
      conversation
      |> locked(turn_ref, fn ->
        with :ok <- Limits.check(user.settings, user.endpoint_uuid),
             {:ok, admission} <- admit(conversation.user_uuid, turn_ref) do
          user = Map.put(user, :guard_admission, admission)
          begin(session_ref, conversation, text, attachments, user, turn_ref, opts)
        end
      end)
      |> started(conversation, turn_ref, user)
    end
  end

  defp started({:ok, _pid}, _conversation, turn_ref, _user), do: {:ok, turn_ref}

  # The notice is written while the locks are still held, so two refused
  # starts cannot both find the chat without one.
  defp started({:error, {:limit_reached, reached}}, conversation, turn_ref, user) do
    try do
      limit_reached(conversation, turn_ref, user.settings, reached)
    after
      Locks.release(conversation.user_uuid, conversation.uuid, turn_ref)
    end

    {:error, {:limit_reached, reached.kind}}
  end

  defp started({:error, {:guard, reason, period}}, conversation, turn_ref, _user) do
    try do
      guard_refused(conversation, turn_ref, reason, period)
    after
      Locks.release(conversation.user_uuid, conversation.uuid, turn_ref)
    end

    {:error, reason}
  end

  defp started({:error, _reason} = error, conversation, turn_ref, _user) do
    Locks.release(conversation.user_uuid, conversation.uuid, turn_ref)
    error
  end

  # Runs `fun` with the locks held: an exception frees them before it goes on
  # (the task has not started, or never got its go-ahead).
  defp locked(conversation, turn_ref, fun) do
    fun.()
  catch
    kind, reason ->
      stacktrace = __STACKTRACE__
      release_quietly(conversation.user_uuid, conversation.uuid, turn_ref)
      :erlang.raise(kind, reason, stacktrace)
  end

  # The chat says why nothing happened — once per limit and period, however
  # often the user tries again; the user (and, if they are to be told, the
  # watchers) hear of the limit once per period.
  defp limit_reached(conversation, turn_ref, settings, reached) do
    code = limit_code(reached.kind)

    unless notice_in_period?(conversation, code, limit_period(reached.kind)) do
      _ =
        Conversations.add_turn_message(conversation.user_uuid, conversation.uuid, %{
          turn_ref: turn_ref,
          role: "notice",
          content: limit_text(reached.kind),
          error: code
        })
    end

    Limits.announce_reached(settings, reached)
  end

  # The guard's refusal of the turn (spec §6.2), as `{:guard, reason,
  # period}` for `started/4`: the refusal of `PhoenixKitAI.Guard.admit/4`
  # names the block group or the limit, which the chat does not need.
  defp admit(user_uuid, turn_ref) do
    "agent.chat"
    |> PhoenixKitAI.Guard.admit(user_uuid, turn_ref, lock_ttl_s())
    |> admission()
  end

  @doc false
  # The answer of `PhoenixKitAI.Guard.admit/4` as `launch/6` takes it. An
  # answer this module does not know (a later version of the guard) starts
  # no turn: it is a `model_error` notice, and the log gets one line without
  # the answer, which may name the user.
  @spec admission(term()) :: {:ok, String.t()} | {:error, {:guard, atom(), :day | :month}}
  def admission({:ok, admission}) when is_binary(admission), do: {:ok, admission}
  def admission({:error, {:task_blocked, _group}}), do: {:error, {:guard, :task_blocked, :day}}

  def admission({:error, {:task_limit_exceeded, _scope, _unit, period}})
      when period in [:day, :month],
      do: {:error, {:guard, :task_limit_exceeded, period}}

  def admission(_unknown) do
    Logger.warning(
      "[PhoenixKitAgent] the AI guard's admission answered in an unknown form; no turn"
    )

    {:error, {:guard, :model_error, :day}}
  end

  # Once a day per chat (a monthly limit: once a month), like a limit of the
  # module's own; the guard tells the user and the watchers itself.
  defp guard_refused(conversation, turn_ref, reason, period) do
    code = Atom.to_string(reason)

    unless notice_in_period?(conversation, code, period) do
      _ =
        Conversations.add_turn_message(conversation.user_uuid, conversation.uuid, %{
          turn_ref: turn_ref,
          role: "notice",
          content: Runner.guard_text(reason),
          error: code
        })
    end

    :ok
  end

  defp notice_in_period?(conversation, code, period) do
    windows = Spend.windows()
    {from, _to} = if period == :month, do: windows.month, else: windows.day

    repo().exists?(
      from(m in Message,
        where:
          m.conversation_uuid == ^conversation.uuid and m.role == "notice" and m.error == ^code and
            m.inserted_at >= ^from
      )
    )
  end

  defp limit_period(:monthly_cost), do: :month
  defp limit_period(_daily), do: :day

  defp limit_code(:daily_cost), do: "daily_cost_limit"
  defp limit_code(:monthly_cost), do: "monthly_cost_limit"
  defp limit_code(:daily_turns), do: "daily_turn_limit"

  defp limit_text(:daily_cost),
    do: "You have reached your daily spending limit for the assistant. It resets at midnight."

  defp limit_text(:monthly_cost),
    do:
      "You have reached your monthly spending limit for the assistant. " <>
        "It resets on the first day of next month."

  defp limit_text(:daily_turns),
    do: "You have used all your assistant turns for today. They reset at midnight."

  defp begin(session_ref, conversation, text, attachments, user, turn_ref, opts) do
    user_uuid = conversation.user_uuid

    # Under the user's lock: no click settles a card meanwhile.
    :ok = Confirmations.settle_lapsed_in_turn(session_ref, conversation)

    request_context =
      opts |> Keyword.get(:request_context, []) |> Keyword.put_new(:request_id, turn_ref)

    turn = %{
      turn_ref: turn_ref,
      session_ref: session_ref,
      user_uuid: user_uuid,
      conversation_uuid: conversation.uuid,
      endpoint_uuid: user.endpoint_uuid,
      text: text,
      attachment_uuids: Enum.map(attachments, & &1.uuid),
      system_prompt: system_prompt(user, request_context, opts),
      history: history(conversation, text, attachments),
      request_context: request_context,
      max_rounds: Config.max_tool_rounds(),
      result_chars: Config.tool_result_chars(),
      capture?: Config.capture_ai_content?(),
      guard_admission: user.guard_admission
    }

    Monitor.start_turn(turn, deadline_ms(opts), [self() | Process.get(:"$callers", [])])
  end

  defp release_quietly(user_uuid, conversation_uuid, turn_ref) do
    Locks.release(user_uuid, conversation_uuid, turn_ref)
  rescue
    _db_error -> :ok
  catch
    _kind, _reason -> :ok
  end

  # §7.1: see `PhoenixKitAgent.Prompt`. The locale is the one the host passed,
  # else the language of the request context, else the process's.
  defp system_prompt(user, request_context, opts) do
    Prompt.build(%{
      user_uuid: user.settings.user_uuid,
      scope: user.scope,
      settings: user.settings,
      locale:
        Keyword.get(opts, :locale) || request_context[:language] ||
          Gettext.get_locale(PhoenixKitWeb.Gettext),
      page: Keyword.get(opts, :page)
    })
  end

  defp history(conversation, text, attachments) do
    messages =
      repo().all(
        from(m in Message,
          where:
            m.conversation_uuid == ^conversation.uuid and
              (m.role in ["user", "assistant"] or
                 (m.role in ["notice", "tool"] and not is_nil(m.confirmation_uuid))),
          order_by: [asc: m.inserted_at, asc: m.uuid],
          select:
            struct(m, [
              :uuid,
              :role,
              :content,
              :tool_calls,
              :tool_name,
              :tool_outcome,
              :confirmation_uuid
            ])
        )
      )

    earlier =
      repo().all(
        from(a in Attachment,
          where:
            a.conversation_uuid == ^conversation.uuid and a.status == "ready" and
              not is_nil(a.message_uuid),
          order_by: [asc: a.inserted_at, asc: a.uuid]
        )
      )

    limit = Config.history_chars()
    current = %{role: "user", content: History.user_content(text, attachments, limit)}
    History.build(messages, earlier, current, limit)
  end

  defp deadline_ms(opts) do
    configured = Config.turn_deadline_s() * 1_000

    case Keyword.get(opts, :deadline_ms) do
      ms when is_integer(ms) and ms > 0 -> min(ms, configured)
      _ -> configured
    end
  end

  @doc false
  # How old a turn's lock must be before another may take it over (spec §6.1
  # step 3); `PhoenixKitAgent.Confirmations` takes the user's lock with it.
  @spec lock_ttl_s() :: pos_integer()
  def lock_ttl_s, do: Config.turn_deadline_s() + @lock_grace_s

  # ── stop ────────────────────────────────────────────────────────

  defp stop_elsewhere(conversation_uuid, turn_ref) do
    if Locks.fresh?(conversation_uuid, turn_ref, lock_ttl_s()),
      do: Monitor.broadcast_stop(turn_ref),
      else: {:error, :not_running}
  end

  defp same_turn(_running, nil), do: :ok
  defp same_turn(running, running), do: :ok
  defp same_turn(_running, _other), do: {:error, :not_running}

  defp running_turn(user_uuid, conversation_uuid) do
    with {:ok, uuid} <- Ecto.UUID.cast(conversation_uuid),
         {:ok, turn_ref} <- busy_turn_ref(user_uuid, uuid) do
      {:ok, uuid, turn_ref}
    else
      :error -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp busy_turn_ref(user_uuid, uuid) do
    from(c in Conversation,
      where: c.uuid == ^uuid and c.user_uuid == ^user_uuid and c.status != "deleted",
      select: {c.uuid, c.busy_turn_ref}
    )
    |> repo().one()
    |> case do
      nil -> {:error, :not_found}
      {_uuid, nil} -> {:error, :not_running}
      {_uuid, turn_ref} -> {:ok, turn_ref}
    end
  end

  defp repo, do: RepoHelper.repo()
end
