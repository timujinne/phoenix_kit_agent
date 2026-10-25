defmodule PhoenixKitAgent.Turns.Runner do
  @moduledoc """
  The rounds of one turn (spec §6.1, "раунд r = 1..max_tool_rounds"), run in
  the turn's task. The task first stores the user's message (spec §6.1 step
  4) and links its attachments, so a turn that never ran leaves nothing in the
  chat. Then each round:

    a. checks the session again (`Conversations.authorize_session/2`), that
       the chat is still there, that the AI module is on and that the turn
       still holds its locks (`Locks.held?/3`) — a revoked session, a blocked
       user, a lost `agent` permission, a switched-off assistant or a lock
       taken over end the turn with a notice; a deleted chat ends it quietly;
    b. lists the session's tools (`Executor.visible_for/3`, `allow: :all`: the
       read tools, and the write tools of the modules that let a session
       write, `api_session_write_modules` in core) and shows them to the model
       (`PhoenixKitAgent.Turns.Tools`);
    c. sends the system prompt, the history and this turn's messages — of the
       results of earlier rounds of this turn only as many as fit, together
       with the newest round's, in `10 × agent_tool_result_chars` characters
       (spec §6.4): an older one beyond that is sent as a short stub that says
       it was left out (the database keeps it whole); the pictures of the
       user's message, if it has any, go along with it as image parts (or a
       note, where the model cannot see them or a picture cannot be made) in
       every round of this turn only — the history keeps the text — and such a
       turn is never captured into the AI journal
       (`PhoenixKitAgent.Attachments.model_parts/3`); a first model call with
       pictures that the provider refuses as a request (`api_error` 400, 413,
       415 or 422; not a 404 or a 5xx) takes the message's files off it, to be
       sent again; a model that is not known to take images when the turn
       starts is not called: the files go back, with a `pictures_not_seen`
       notice;
    d. calls the model (`PhoenixKitAI.complete/3`, `source: "agent"`, the user,
       the AI task `agent.chat` with the turn's admission
       (`guard_admission:`, from `PhoenixKitAI.Guard.admit/4` in
       `PhoenixKitAgent.Turns`), no cache, the module's content capture, and
       the uuid the answer will be stored under and the turn's ref as
       `attribution`); a failed call is a notice under its code, all in one
       place (`model_failed/4`) — `phoenix_kit_ai` itself tells its watchers
       of a refusal of its budget;
    e. stores the answer; a marker `⟦off_purpose: <reason>⟧` at its very end
       (the model flagging the request, `PhoenixKitAgent.Prompt`) is cut off
       before it is stored and reported to the guard
       (`PhoenixKitAI.Guard.report_off_purpose/4`, keyed by the turn's ref,
       so one flag per turn); a marker anywhere else is left as it is and
       flags nothing. Without tool calls the turn is over. A tool call
       without a name is dropped (not run, stored or sent back); an answer
       with neither text nor a named tool call is stored as an
       `empty_answer` notice, not as an empty answer;
    f. runs each tool call — only a name shown in **this** round reaches the
       executor (`execute_as/5`, `allow: :all`, `via: "agent"`), any other is
       `denied`, and so is every call past the 10th of the round — and stores
       each result, truncated. Before each call the turn checks that it still
       holds its locks: a lock taken over ends the turn there, with a notice.

  ## A write

  Core never runs a write of a live session on its call: it answers the
  preview and holds the call in a confirmation row bound to the user
  (`"status": "confirmation_required"`, `"confirmation_id"`). The call is
  stored as a `tool` message `needs_confirmation` with that uuid in
  `confirmation_uuid` and the answer that asked for it in
  `assistant_message_uuid`; its `tool_result` keeps the status and the uuid
  only — never a code, the preview or the arguments. The card in the chat
  shows it (`PhoenixKitAgent.Confirmations`).

    * At most one write of a round waits: a write after it in the same answer
      is `denied` ("confirm the earlier change first"), and so is a write whose
      call id another call of the answer shares (the click finds its arguments
      by that id). A read after it is `denied` too ("held for confirmation"):
      the turn ends with the round, the model would never read its result.
    * A write of the same tool with the same arguments as a card of the chat
      that still waits is `denied` ("already waiting for confirmation"): no
      second card of one change.
    * A round that left a write waiting ends the turn: the model is not called
      again, so no answer can say that the change was made. The card is the
      end of the turn; what the click did reaches the model as a notice in the
      history of the next turn (`PhoenixKitAgent.Turns.History`).

  ## Stopping between steps

  "Stop" and the deadline do not kill the task at once: the monitor asks it to
  stop (`PhoenixKitAgent.Turns.Monitor`), and the task looks for that request
  before it stores the user's message, before each round, as soon as the
  model has answered and before each tool call — and then ends as
  `{:shutdown, :stopped | :deadline}` without storing anything more (a
  partial answer is not kept). A model call under way is let finish, so its
  row in the AI journal — what the call cost — is written. Only a task that
  does not get there within the grace period is killed.

  A message the database refuses ends the task as `{:shutdown,
  :store_failed}` (the log gets the field names and validation codes only),
  and the monitor writes an `interrupted` notice; a chat deleted mid-turn
  ends it as `{:shutdown, :chat_gone}`, with nothing written and no further
  model call.

  Every stored message is broadcast by `PhoenixKitAgent.Conversations`. Ending
  the task (stop, deadline, crash) and the locks are
  `PhoenixKitAgent.Turns.Monitor`'s business.

  ## The AI request of a message

  An answer of `complete/3` names its journal row (`"request_uuid"`), and
  the message is stored with it as `ai_request_uuid`. The row itself
  reaches `record_usage/1` (`PhoenixKitAgent.handle_ai_usage/1`, a
  `phoenix_kit_ai` usage sink) with the `attribution` the call carried,
  synchronously, in the calling process and before `complete/3` returns. So
  the turn says which message uuid it waits for, and `record_usage/1` keeps
  the row for it in the process: the message gets the row's model, tokens,
  cost and latency, and a failed call's notice its row (an error answer
  names none). A row the guard refused never reaches a sink: its notice
  has no `ai_request_uuid`. A row for an already stored message —
  from any other process — sets its `ai_request_uuid` in the database, only
  for a message of the row's own user that has none yet.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKit.API.ControlFields
  alias PhoenixKit.API.Executor
  alias PhoenixKit.API.MCP.Names
  alias PhoenixKit.RepoHelper
  alias PhoenixKitAgent.{Attachments, Config, Confirmations, Conversations}
  alias PhoenixKitAgent.Schemas.{Conversation, Message}
  alias PhoenixKitAgent.Turns.{Locks, Monitor, Tools}

  @awaiting {__MODULE__, :awaiting_ai_request}

  # The statuses of a provider's refusal of the request itself, the ones a
  # model that cannot take the pictures answers with (`unsend/2`).
  @picture_refusals [400, 413, 415, 422]

  # The most tool calls of one round that reach the executor; the rest are
  # denied. One answer of the model must not fan out into hundreds of calls.
  @max_calls_per_round 10

  # What an older result of this turn is sent as once the turn's results are
  # over their budget.
  @omitted Jason.encode!(%{
             "omitted" => true,
             "hint" =>
               "This earlier result was left out to keep the conversation short. " <>
                 "Call the tool again if you still need it."
           })

  # The model errors of `PhoenixKitAI.complete/3` kept as their own code in
  # `messages.error`; any other is "model_error".
  @model_errors ~w(request_timeout invalid_api_key api_key_forbidden rate_limited
                   insufficient_credits invalid_json_response invalid_response_format
                   no_choices_in_response endpoint_not_found endpoint_disabled
                   endpoint_no_model integration_not_configured integration_deleted
                   not_configured)a

  # The model errors that only an administrator can end: the notice does not
  # say to try again (`PhoenixKitAgent.Web.Dock.Texts`).
  @endpoint_unusable ~w(invalid_api_key api_key_forbidden endpoint_not_found endpoint_disabled
                        endpoint_no_model integration_not_configured integration_deleted
                        not_configured)a

  # The refusals of the AI guard (`PhoenixKitAI.Guard`), each a code of its
  # own in `messages.error`: `{reason, …}` is stored as `reason`.
  @guard_errors ~w(model_unfit model_unverified no_provider_for_params task_blocked
                   task_limit_exceeded)a

  # The model's flag of an off-purpose request: the last thing in its
  # answer (spec §8.2 B, `PhoenixKitAgent.Prompt`).
  @off_purpose ~r/⟦off_purpose:([^⟧]*)⟧\s*\z/u

  @typedoc "Everything a turn needs; built by `PhoenixKitAgent.Turns.start/6`."
  @type turn :: %{
          turn_ref: String.t(),
          session_ref: PhoenixKit.Users.Auth.SessionRef.t(),
          user_uuid: String.t(),
          conversation_uuid: String.t(),
          endpoint_uuid: String.t(),
          text: String.t(),
          attachment_uuids: [String.t()],
          system_prompt: String.t() | nil,
          history: [map()],
          request_context: keyword(),
          max_rounds: pos_integer(),
          result_chars: pos_integer(),
          capture?: boolean(),
          guard_admission: String.t() | nil
        }

  @doc """
  Stores the user's message of `turn`, then runs its rounds until the model
  answers without tool calls.
  """
  @spec run(turn()) :: :ok
  def run(turn) do
    :ok = Monitor.check_stop()
    message = store_user_message!(turn)
    turn = Map.put(turn, :user_message_uuid, message.uuid)

    case with_pictures(turn) do
      {:ok, turn, transcript} -> round(turn, 1, transcript)
      {:error, :not_seen} -> pictures_not_seen(turn)
    end
  end

  # The pictures of this message's attachments go along with its text, in this
  # turn only (spec §9): the history keeps the extracted text, not the pixels.
  # A turn that carries pictures is never captured into the AI journal, whatever
  # the module's setting: the pixels would be written there as base64. One that
  # carries only notes about pictures it could not show has no pixels to write.
  #
  # `pictures?` holds until the model has answered once: a first call that
  # fails as the provider's refusal may be a refusal of the pictures, and then
  # the files are taken off the message, to be sent again (`unsend/2`).
  #
  # A model that is not known to take images now gets no pixels and is not
  # called (`pictures_not_seen/1`).
  defp with_pictures(%{attachment_uuids: []} = turn),
    do: {:ok, Map.put(turn, :pictures?, false), turn.history}

  defp with_pictures(turn) do
    turn = Map.put(turn, :pictures?, false)

    case Attachments.model_parts(turn.attachment_uuids, turn.user_uuid, turn.endpoint_uuid) do
      {:error, :not_seen} = not_seen ->
        not_seen

      {:ok, []} ->
        {:ok, turn, turn.history}

      {:ok, parts} ->
        {earlier, [current]} = Enum.split(turn.history, -1)
        {notes, pictures} = Enum.split_with(parts, &(&1["type"] == "text"))
        text = Enum.reduce(notes, current.content, &(&2 <> "\n\n" <> &1["text"]))

        content =
          if pictures == [],
            do: text,
            else: [%{"type" => "text", "text" => text} | pictures]

        turn = if pictures == [], do: turn, else: %{turn | capture?: false, pictures?: true}
        {:ok, turn, earlier ++ [%{current | content: content}]}
    end
  end

  # The pictures were kept as pixels for a model that saw them when they were
  # uploaded; the user's model does not (or is not known to) now. They go back
  # to wait for a message, and the chat says to attach them again: a new upload
  # is described by the vision model.
  defp pictures_not_seen(turn) do
    :ok =
      Conversations.unlink_attachments(
        turn.user_uuid,
        turn.conversation_uuid,
        turn.user_message_uuid
      )

    notice(
      turn,
      "pictures_not_seen",
      "The model does not take pictures now, so they were not sent. " <>
        "Remove them and attach them again to have them described, or choose a model that sees."
    )
  end

  @doc """
  The usage sink behind `PhoenixKitAgent.handle_ai_usage/1`: links an AI
  request row to the message its `attribution` names (see the moduledoc).
  """
  @spec record_usage(struct()) :: :ok
  def record_usage(%{uuid: request_uuid} = request) when is_binary(request_uuid) do
    case attributed_message(request) do
      nil ->
        :ok

      message_uuid ->
        if Process.get(@awaiting) == message_uuid,
          do: Process.put({@awaiting, message_uuid}, request),
          else: link_stored(message_uuid, request)

        :ok
    end
  end

  def record_usage(_other), do: :ok

  # ── the rounds ──────────────────────────────────────────────────

  defp round(%{max_rounds: max} = turn, r, _transcript) when r > max,
    do: notice(turn, "max_tool_rounds", "The assistant used all its tool rounds for this turn.")

  defp round(turn, r, transcript) do
    with :ok <- may_go_on(turn),
         {:ok, tools} <- visible_tools(turn) do
      {definitions, allowed} = Tools.for_model(tools)

      case ask_model(turn, transcript, definitions) do
        {:ok, %Message{role: "assistant", tool_calls: calls} = message}
        when is_list(calls) and calls != [] ->
          case run_calls(turn, message, calls, allowed) do
            {:ok, _results, :waiting} ->
              :ok

            {:ok, results, :none} ->
              latest = [assistant_entry(message) | results]
              turn = %{turn | pictures?: false}
              round(turn, r + 1, fit_turn(transcript, latest, turn.result_chars) ++ latest)

            {:error, reason} ->
              stopped(turn, reason)
          end

        _answered_or_failed ->
          :ok
      end
    else
      {:error, :chat_gone} -> exit({:shutdown, :chat_gone})
      {:error, reason} -> stopped(turn, reason)
    end
  end

  defp may_go_on(turn) do
    :ok = Monitor.check_stop()

    with {:ok, _user_uuid} <-
           Conversations.authorize_session(turn.session_ref, impersonated: false) do
      cond do
        not chat_alive?(turn) ->
          {:error, :chat_gone}

        not PhoenixKitAI.enabled?() ->
          {:error, :ai_disabled}

        not Locks.held?(turn.user_uuid, turn.conversation_uuid, turn.turn_ref) ->
          {:error, :lock_lost}

        true ->
          :ok
      end
    end
  end

  defp chat_alive?(turn) do
    RepoHelper.repo().exists?(
      from(c in Conversation,
        where:
          c.uuid == ^turn.conversation_uuid and c.user_uuid == ^turn.user_uuid and
            c.status != "deleted"
      )
    )
  end

  # The earlier transcript, with the oldest results of this turn turned into
  # stubs until the results still in it and those of the newest round fit
  # `@max_calls_per_round` results. The newest round is never cut: the model
  # has not seen it yet. The history holds no `tool` entries.
  defp fit_turn(earlier, latest, result_chars) do
    budget = @max_calls_per_round * result_chars
    used = results_size(earlier) + results_size(latest)

    {fitted, _used} =
      Enum.map_reduce(earlier, used, fn
        %{role: "tool", content: content} = entry, used
        when used > budget and content != @omitted ->
          {%{entry | content: @omitted}, used - String.length(content)}

        entry, used ->
          {entry, used}
      end)

    fitted
  end

  defp results_size(entries) do
    entries
    |> Enum.filter(&(&1.role == "tool" and &1.content != @omitted))
    |> Enum.map(&String.length(&1.content))
    |> Enum.sum()
  end

  defp visible_tools(turn) do
    case Executor.visible_for(turn.session_ref, :admin, allow: :all) do
      {:ok, tools, _headers} -> {:ok, tools}
      {:error, :unauthorized, _detail, %{reason: reason}, _headers} -> {:error, reason}
      {:error, code, _detail, _context, _headers} -> {:error, code}
    end
  end

  # ── the model call ──────────────────────────────────────────────

  defp ask_model(turn, transcript, definitions) do
    message_uuid = UUIDv7.generate()
    started = System.monotonic_time(:millisecond)

    opts =
      [
        user_uuid: turn.user_uuid,
        source: "agent",
        task: "agent.chat",
        guard_admission: turn[:guard_admission],
        cache: false,
        capture_request_content: turn.capture?,
        attribution: %{"agent_message_uuid" => message_uuid, "turn_ref" => turn.turn_ref}
      ] ++ if(definitions == [], do: [], else: [tools: definitions])

    Process.put(@awaiting, message_uuid)

    result =
      try do
        PhoenixKitAI.complete(turn.endpoint_uuid, system(turn) ++ transcript, opts)
      after
        Process.delete(@awaiting)
      end

    # The call is over and its journal row written: a stop asked for while it
    # ran ends the turn here, before the answer is stored.
    :ok = Monitor.check_stop()

    request = Process.delete({@awaiting, message_uuid})
    latency_ms = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, response} ->
        store_answer(turn, message_uuid, response, request, latency_ms)

      {:error, reason} ->
        model_failed(turn, reason, message_uuid, request)
    end
  end

  # The one place a failed model call is handled: its notice under a fixed
  # code (`error_code/1`), and the pictures taken off the message when the
  # provider refused them. A refusal of the AI budget is told to the
  # watchers by `phoenix_kit_ai`.
  defp model_failed(turn, reason, message_uuid, request) do
    unsent? = unsend(turn, reason)

    notice(turn, error_code(reason), model_error_text(reason, unsent?),
      uuid: message_uuid,
      ai_request_uuid: request && request.uuid
    )

    {:error, reason}
  end

  defp system(%{system_prompt: nil}), do: []
  defp system(%{system_prompt: prompt}), do: [%{role: "system", content: prompt}]

  defp store_answer(turn, message_uuid, response, request, latency_ms) do
    content =
      case PhoenixKitAI.extract_content(response) do
        {:ok, text} when is_binary(text) -> text |> Message.strip_nul() |> off_purpose(turn)
        _no_text -> nil
      end

    # A call without a name can be neither run nor sent back: strict
    # providers refuse a replayed call named "".
    calls =
      response
      |> PhoenixKitAI.extract_tool_calls()
      |> Enum.with_index(1)
      |> Enum.map(&stored_call/1)
      |> Enum.reject(&is_nil(&1["name"]))

    fields = [uuid: message_uuid, ai_request_uuid: request_uuid(response, request)]
    usage = usage(request, response, latency_ms)

    attrs =
      if calls == [] and (content == nil or String.trim(content) == "") do
        %{
          role: "notice",
          content: "The model gave no answer. Try again.",
          error: "empty_answer"
        }
      else
        %{role: "assistant", content: content, tool_calls: if(calls == [], do: nil, else: calls)}
      end

    {:ok, store!(turn, attrs |> Map.put(:turn_ref, turn.turn_ref) |> Map.merge(usage), fields)}
  end

  # The answer's own journal row, else the one the usage sink caught.
  defp request_uuid(%{"request_uuid" => uuid}, _request) when is_binary(uuid), do: uuid
  defp request_uuid(_response, request), do: request && request.uuid

  # The model's off-purpose marker, cut off the end of the answer and
  # reported, once per turn (the guard keys the flag by the turn's ref). The
  # guard's answer is not the turn's business: whatever it says (the task
  # does not flag now, the database failed), the answer is stored.
  defp off_purpose(text, turn) do
    case Regex.run(@off_purpose, text, return: :index) do
      [{start, _length}, {reason_start, reason_length}] ->
        reason = text |> binary_part(reason_start, reason_length) |> String.trim()

        _ =
          PhoenixKitAI.Guard.report_off_purpose("agent.chat", turn.user_uuid, reason, %{
            "turn_ref" => turn.turn_ref
          })

        text |> binary_part(0, start) |> String.trim_trailing()

      nil ->
        text
    end
  end

  # Model, tokens, cost and latency: from the journal row when the usage sink
  # caught it (its cost is dollars, kept here in whole micro-dollars), else
  # from the response.
  defp usage(nil, response, latency_ms) do
    usage = response["usage"] || %{}

    %{
      model: response["model"],
      input_tokens: usage["prompt_tokens"],
      output_tokens: usage["completion_tokens"],
      latency_ms: latency_ms
    }
  end

  defp usage(request, response, latency_ms) do
    %{
      model: request.model || response["model"],
      input_tokens: request.input_tokens,
      output_tokens: request.output_tokens,
      cost_micro_usd: Config.cost_to_micro(request.cost),
      latency_ms: request.latency_ms || latency_ms
    }
  end

  # A tool call as stored and replayed: `{id, name, arguments}` as the model
  # sent them (a missing id gets a stand-in, so the result can answer it).
  defp stored_call({raw, index}) do
    raw = if is_map(raw), do: raw, else: %{}
    function = if is_map(raw["function"]), do: raw["function"], else: %{}

    %{
      "id" => non_blank(raw["id"]) || "call_#{index}",
      "name" => non_blank(function["name"]),
      "arguments" => function["arguments"]
    }
  end

  defp assistant_entry(%Message{content: content, tool_calls: calls}) do
    %{
      role: "assistant",
      content: content,
      tool_calls:
        Enum.map(calls, fn call ->
          %{
            "id" => call["id"],
            "type" => "function",
            "function" => %{
              "name" => call["name"],
              "arguments" => encoded_arguments(call["arguments"])
            }
          }
        end)
    }
  end

  defp encoded_arguments(arguments) when is_binary(arguments), do: arguments
  defp encoded_arguments(nil), do: "{}"
  defp encoded_arguments(arguments), do: Jason.encode!(arguments)

  # ── a tool call ─────────────────────────────────────────────────

  # The calls of one answer, in order; before each, a stop asked for ends the
  # turn and a lock taken over ends it with a notice. `:waiting` when one of
  # them is a write that waits for the user's confirmation.
  defp run_calls(turn, message, calls, allowed) do
    answer = %{message: message, shared_ids: shared_ids(calls)}

    calls
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, [], :none}, fn {call, n}, {:ok, results, waiting} ->
      :ok = Monitor.check_stop()

      if Locks.held?(turn.user_uuid, turn.conversation_uuid, turn.turn_ref) do
        answer = Map.put(answer, :waiting, waiting)

        {result, outcome} =
          if n <= @max_calls_per_round,
            do: run_call(turn, answer, call, allowed),
            else: run_call(turn, answer, call, %{}, too_many_calls())

        waiting = if outcome == "needs_confirmation", do: :waiting, else: waiting
        {:cont, {:ok, [result | results], waiting}}
      else
        {:halt, {:error, :lock_lost}}
      end
    end)
    |> case do
      {:ok, results, waiting} -> {:ok, Enum.reverse(results), waiting}
      {:error, _reason} = error -> error
    end
  end

  # The call ids that more than one call of the answer carries.
  defp shared_ids(calls) do
    calls
    |> Enum.frequencies_by(& &1["id"])
    |> Enum.filter(fn {_id, count} -> count > 1 end)
    |> MapSet.new(fn {id, _count} -> id end)
  end

  # `answer`: the assistant message the call is part of, the call ids it
  # shares, and whether a write of it waits already.
  defp run_call(turn, answer, call, allowed, denial \\ denied()) do
    {registry_name, outcome, result} =
      case Map.fetch(allowed, call["name"]) do
        {:ok, tool} -> call_tool(turn, tool, call, answer)
        :error -> {denied_name(call["name"]), "denied", denial}
      end

    tool_result = Tools.fit(result, turn.result_chars)

    store!(
      turn,
      %{
        turn_ref: turn.turn_ref,
        role: "tool",
        tool_call_id: call["id"],
        tool_name: registry_name,
        tool_outcome: outcome,
        tool_result: tool_result
      },
      assistant_message_uuid: answer.message.uuid,
      confirmation_uuid: waiting_uuid(outcome, tool_result)
    )

    {%{
       role: "tool",
       tool_call_id: call["id"],
       name: call["name"],
       content: Jason.encode!(tool_result)
     }, outcome}
  end

  # Once a write of this answer waits, no call of it reaches the executor:
  # the turn ends with the round, so the model would never read a read's
  # result, and it would only spend the rate limit. A write gets no executor
  # call either when its call id is not its own (the click would not find its
  # arguments), nor when a card of the chat waits for the same write already.
  defp call_tool(turn, tool, call, answer) do
    write? = ControlFields.write_tool?(tool)

    cond do
      answer.waiting == :waiting and not write? -> {tool.name, "denied", held_first()}
      not write? -> execute(turn, tool, call["arguments"])
      answer.waiting == :waiting -> {tool.name, "denied", confirm_first()}
      MapSet.member?(answer.shared_ids, call["id"]) -> {tool.name, "denied", shared_id()}
      waiting_already?(turn, tool, call) -> {tool.name, "denied", already_waiting()}
      true -> execute(turn, tool, call["arguments"])
    end
  end

  defp waiting_already?(turn, tool, call) do
    case Tools.arguments(call["arguments"]) do
      {:ok, input} -> Confirmations.waiting_same?(turn, tool.name, input)
      :error -> false
    end
  end

  defp waiting_uuid("needs_confirmation", %{"confirmation_id" => uuid}), do: uuid
  defp waiting_uuid(_outcome, _result), do: nil

  defp execute(turn, tool, arguments) do
    case Tools.arguments(arguments) do
      {:ok, input} ->
        case Executor.execute_as(turn.session_ref, :admin, tool.name, input,
               allow: :all,
               via: "agent",
               request_context: turn.request_context
             ) do
          {:ok, %{result: result}, _headers} ->
            executed(tool, result)

          {:error, code, detail, context, _headers} ->
            {tool.name, "error", refusal(code, detail, context)}
        end

      :error ->
        {tool.name, "error",
         %{"error" => "invalid_arguments", "message" => "The arguments must be a JSON object."}}
    end
  end

  # The prompt of a confirmation is kept as its status and uuid only.
  defp executed(tool, result) do
    with true <- ControlFields.write_tool?(tool),
         {:ok, uuid} <- Tools.held(result) do
      {tool.name, "needs_confirmation", Tools.held_result(uuid)}
    else
      _read_or_ran -> {tool.name, "ok", result}
    end
  end

  defp refusal(code, detail, context) do
    base = %{"error" => to_string(code), "message" => detail}

    with %{errors: errors} when is_list(errors) <- context,
         {:ok, _json} <- Jason.encode(errors) do
      Map.put(base, "errors", errors)
    else
      _ -> base
    end
  end

  defp denied,
    do: %{"error" => "denied", "message" => "This tool is not available to you here."}

  defp confirm_first do
    %{
      "error" => "denied",
      "message" =>
        "Confirm the earlier change first: only one change at a time waits for the user."
    }
  end

  defp held_first do
    %{
      "error" => "denied",
      "message" =>
        "Not run: a change of this answer is held for confirmation, and the turn ends with " <>
          "it. Ask for this again in the next turn."
    }
  end

  defp already_waiting do
    %{
      "error" => "denied",
      "message" =>
        "This change is already waiting for confirmation: the user runs or cancels it on its " <>
          "card in the chat. Do not ask for it again."
    }
  end

  defp shared_id do
    %{
      "error" => "denied",
      "message" => "A change needs a tool call id of its own; this one is used twice."
    }
  end

  defp too_many_calls do
    %{
      "error" => "denied",
      "message" => "Too many tool calls at once; at most #{@max_calls_per_round} run per round."
    }
  end

  # The registry name when the model's name maps to one, else its own name.
  defp denied_name(name), do: name |> Names.resolve(:admin) |> clip()

  # ── storing ─────────────────────────────────────────────────────

  # A message of the turn, or the end of the turn: a deleted chat ends it
  # quietly; a refused message ends it with only the field names and
  # validation codes in the log, never the values.
  defp store_user_message!(turn) do
    attrs = %{turn_ref: turn.turn_ref, role: "user", content: turn.text}

    turn.user_uuid
    |> Conversations.add_user_turn_message(turn.conversation_uuid, attrs, turn.attachment_uuids)
    |> stored!(attrs)
  end

  defp store!(turn, attrs, fields) do
    turn.user_uuid
    |> Conversations.add_turn_message(turn.conversation_uuid, attrs, fields)
    |> stored!(attrs)
  end

  defp stored!(result, attrs) do
    case result do
      {:ok, message} ->
        message

      {:error, :not_found} ->
        exit({:shutdown, :chat_gone})

      {:error, %Ecto.Changeset{} = changeset} ->
        codes =
          Enum.map(changeset.errors, fn {field, {_text, opts}} -> {field, opts[:validation]} end)

        Logger.warning(
          "[PhoenixKitAgent] a #{attrs.role} message of a turn was not stored: #{inspect(codes)}"
        )

        exit({:shutdown, :store_failed})
    end
  end

  # ── notices ─────────────────────────────────────────────────────

  defp stopped(turn, reason) when is_atom(reason) do
    notice(turn, Atom.to_string(reason), stop_text(reason))
  end

  defp stop_text(reason)
       when reason in [:session_gone, :mismatch, :inactive, :unconfirmed, :referral_required],
       do: "Your session has ended, so the assistant stopped."

  defp stop_text(:forbidden), do: "The assistant is no longer available to you."
  defp stop_text(:ai_disabled), do: "The AI module is switched off."
  defp stop_text(:rate_limited), do: "Too many requests at once; try again in a minute."
  defp stop_text(:not_found), do: "This chat is gone."
  defp stop_text(:lock_lost), do: "The answer was interrupted. Try again."
  defp stop_text(_other), do: "The assistant stopped."

  defp notice(turn, error, content, fields \\ []) do
    _ =
      Conversations.add_turn_message(
        turn.user_uuid,
        turn.conversation_uuid,
        %{turn_ref: turn.turn_ref, role: "notice", content: content, error: error},
        fields
      )

    :ok
  end

  defp error_code({:budget_exceeded, _scope}), do: "budget_exceeded"

  defp error_code(reason) when is_tuple(reason) and elem(reason, 0) in @guard_errors,
    do: reason |> elem(0) |> Atom.to_string()

  defp error_code({:api_error, _status}), do: "api_error"
  defp error_code({:connection_error, _reason}), do: "connection_error"
  defp error_code(reason) when reason in @model_errors, do: Atom.to_string(reason)
  defp error_code(_reason), do: "model_error"

  defp model_error_text({:budget_exceeded, _scope}, _unsent?), do: "The AI budget is used up."
  defp model_error_text({:model_unfit, _missing}, _unsent?), do: guard_text(:model_unfit)

  defp model_error_text({:model_unverified, _unclear}, _unsent?),
    do: guard_text(:model_unverified)

  defp model_error_text({:no_provider_for_params, _params}, _unsent?),
    do: guard_text(:no_provider_for_params)

  defp model_error_text({:task_blocked, _group}, _unsent?), do: guard_text(:task_blocked)

  defp model_error_text({:task_limit_exceeded, _scope, _unit, _period}, _unsent?),
    do: guard_text(:task_limit_exceeded)

  defp model_error_text(:insufficient_credits, _unsent?),
    do:
      "The AI account behind the assistant has run out of credit. " <>
        "An administrator has to top it up or choose another model."

  defp model_error_text(reason, _unsent?) when reason in @endpoint_unusable,
    do:
      "The AI endpoint behind the assistant cannot be used right now. " <>
        "An administrator has to check its settings."

  defp model_error_text(_reason, true),
    do:
      "The model did not answer; it may not take the pictures. " <>
        "The files were not sent with the message: you can send them again."

  defp model_error_text(_reason, false), do: "The model did not answer. Try again."

  @doc false
  # The stored (English) text of a notice of the AI guard; the panel shows
  # it in the user's language by its code (`PhoenixKitAgent.Web.Dock.Texts`).
  @spec guard_text(atom()) :: String.t()
  def guard_text(:model_unfit),
    do:
      "The model chosen for the assistant cannot do what it needs. An administrator chooses another one."

  def guard_text(:model_unverified),
    do:
      "It is not known whether the model chosen for the assistant can do what it needs. " <>
        "An administrator marks what the model can do on its AI endpoint, or chooses another one."

  def guard_text(:no_provider_for_params),
    do:
      "No provider of the model takes the request as its AI endpoint is set up. " <>
        "An administrator checks the endpoint's settings."

  def guard_text(:task_blocked),
    do: "The AI assistant is blocked for you. An administrator can lift the block."

  def guard_text(:task_limit_exceeded),
    do: "The AI assistant has reached its limit for now. Try again later."

  def guard_text(:model_error), do: "The model did not answer. Try again."

  # The first model call that carried the message's pictures was refused by
  # the provider as a request it does not take (spec §9: a model that cannot
  # take them, pictures too large or of a type it does not read): the files are
  # taken off the message and wait to be sent again. A missing model (404), a
  # failure of the provider (5xx), a budget, a key, a timeout or the network say
  # nothing of the pictures, and leave them where they are.
  defp unsend(%{pictures?: true} = turn, {:api_error, status})
       when status in @picture_refusals do
    :ok =
      Conversations.unlink_attachments(
        turn.user_uuid,
        turn.conversation_uuid,
        turn.user_message_uuid
      )

    true
  end

  defp unsend(_turn, _reason), do: false

  # ── the AI request link ─────────────────────────────────────────

  defp attributed_message(%{metadata: metadata}) when is_map(metadata) do
    attribution = metadata["attribution"] || metadata[:attribution]

    with %{} <- attribution,
         uuid when is_binary(uuid) <- attribution["agent_message_uuid"],
         {:ok, uuid} <- Ecto.UUID.cast(uuid) do
      uuid
    else
      _ -> nil
    end
  end

  defp attributed_message(_request), do: nil

  defp link_stored(message_uuid, %{uuid: request_uuid, user_uuid: user_uuid})
       when is_binary(user_uuid) do
    RepoHelper.repo().update_all(
      from(m in Message,
        join: c in Conversation,
        on: c.uuid == m.conversation_uuid,
        where: m.uuid == ^message_uuid and is_nil(m.ai_request_uuid) and c.user_uuid == ^user_uuid
      ),
      set: [ai_request_uuid: request_uuid]
    )

    :ok
  rescue
    error ->
      Logger.warning("[PhoenixKitAgent] AI request not linked: #{inspect(error.__struct__)}")
      :ok
  end

  defp link_stored(_message_uuid, _request_without_user), do: :ok

  defp non_blank(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: clip(value)
  end

  defp non_blank(_value), do: nil

  defp clip(text), do: String.slice(text, 0, 200)
end
