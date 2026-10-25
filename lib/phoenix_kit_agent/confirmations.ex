defmodule PhoenixKitAgent.Confirmations do
  @moduledoc """
  The confirmation cards of the chat (spec §12 Ф2, Б2.2): a write the model
  asked for waits for the user, who runs it, turns it down or asks for it
  again.

  A turn never writes (`PhoenixKitAgent.Turns.Runner`): core answers a write of
  a live session with a preview and holds the call in a confirmation row bound
  to the user (`PhoenixKit.API.Executor.execute_as/5`, `allow: :all`), and the
  turn stores a `tool` message `needs_confirmation` with the row's uuid
  (`confirmation_uuid`) and the answer that asked for it
  (`assistant_message_uuid`), and ends there. A card is that message; it
  waits while the chat has no `notice` with the same `confirmation_uuid`.

  Like `PhoenixKitAgent.Conversations`, every function acts for a **live
  browser session** and takes the answer of `MultiSession.impersonated?/1` for
  it: an impersonated session, a session that cannot act, a user who may not
  use the assistant, someone else's chat, or a message that is not a card of
  it, are refused before anything else is read (the refusals of
  `Conversations.owned_conversation/3`, then `:not_waiting`).

  ## A click

  `confirm/5`, `reject/5` and `repeat/5` take the user's turn lock for the
  click (`PhoenixKitAgent.Turns.Locks.acquire_user/4`): while a turn of the
  user runs, a click is `{:error, :turn_running}`, while another click runs
  `{:error, :click_running}`, and no turn starts while a click runs (the turn
  is refused `:click_in_flight`). The lock blocks a turn for 30 s from the
  moment it was last kept: a process next to the click, under
  `PhoenixKitAgent.Confirmations.TaskSupervisor`, keeps it fresh every 10 s
  for as long as the click runs (`Locks.keep_user/4`; `config
  :phoenix_kit_agent, click_keep_ms:`, held between 100 ms and 15 s, half the
  hold), and stops with it, so a lock never released (its node went down)
  frees the user's turns 30 s after its last keep. Should the database refuse
  the keeps for longer than the hold, a turn may start while the click still
  runs. A click calls no model and stores no user message, so it spends
  neither money nor a turn of the user's limits. The card is read again under
  the lock.

    * `confirm/5` redeems the row (`Executor.redeem_as/6`) with the same tool
      and the arguments the model sent — the registry name of the card and
      `PhoenixKitAgent.Turns.Tools.arguments/1` of the call in its assistant
      message — under the rights of the session that clicks, now. Core checks
      everything again (the session, the tool and its module, the "Agent may
      act" box, the scope and the permission, the rate limit, the input, a
      fresh dry run against the preview's fingerprint) and spends the row
      atomically before the handler runs.
    * `reject/5` turns the row down (`PhoenixKit.API.Confirm.reject_for_user/2`).
    * `repeat/5`, for a card whose row ran out (or that core has deleted),
      asks for the same call again (`execute_as/5`): a new card.

  What became of the card is a new `notice` with its `confirmation_uuid`, the
  tool's name and `tool_outcome`:

    * `confirmed` — the handler ran; and also for a row core had spent
      already with no notice of it here (core's `used` to `redeem_as/6` or
      `reject_for_user/2`, read back as `used` with `get_for_user/2`, or,
      when that read is withheld because the user may no longer use the
      tool, with `lookup_for_user/2`): the click that spent it was lost after
      core spent it, and core spends the row right before the handler runs.
      Should the row not read so, the card keeps waiting with the reason;
    * `rejected`;
    * `expired` — the row ran out, or is gone: core's `invalid` (it deletes
      its rows) reads as `expired` too;
    * `changed` — the values changed under the preview: core holds the call
      in a new row, which is a new card with the same assistant message,
      stored right after the notice in the same transaction (as is the new
      card of "Ask again" with the `expired` notice of a card not yet
      closed): both are there, or neither;
    * `failed` — only when the handler failed after core spent the row (an
      error of `redeem_as/6` with the row `used`).

  A notice the chat refuses (it was deleted meanwhile) makes the click
  `{:error, :not_stored}`, whatever core did.

  A card can also stop waiting with no click to say so: its row ran out, core
  deleted it, or the click that settled it was lost with its node.
  `settle_lapsed/3` (the chat panel, when it opens a chat) and
  `settle_lapsed_in_turn/2` (a turn, before it reads the history) give such a
  card its notice by what core's row says — `used` is `confirmed`, `rejected`
  is `rejected`, a row that ran out or is gone is `expired` — so neither the
  panel nor the model takes it for waiting. A card the user may no longer run
  (the right to its tool is gone) still waits, for "Cancel the change".

  A refusal before the row is spent — the session, the rights, the module's
  box, the handler's own dry run, the rate limit — writes nothing: the card
  keeps waiting and the click answers `{:error, {:refused, code}}` with
  core's code. Such a notice is the only thing of a click the model learns,
  in the history of the next turn (`PhoenixKitAgent.Turns.History`), where a
  card with no notice yet reads as waiting.

  Neither the arguments, nor the preview, nor what the handler returned are
  stored or logged here.
  """

  import Ecto.Query, only: [from: 2, where: 3]

  require Logger

  alias PhoenixKit.API.Confirm
  alias PhoenixKit.API.Executor
  alias PhoenixKit.RepoHelper
  alias PhoenixKitAgent.{Conversations, Turns}
  alias PhoenixKitAgent.Schemas.{Conversation, Message}
  alias PhoenixKitAgent.Turns.{Locks, Tools}

  # How long a click's lock blocks a turn after it was last kept, and how
  # often it is kept while the click runs.
  @hold_s 30
  @keep_ms 10_000
  @keep_min_ms 100

  # The most of the model's arguments a card shows.
  @arguments_chars 2_000

  @outcomes ~w(confirmed rejected expired changed failed)

  @typedoc "What a card shows (see `cards/4`)."
  @type card :: %{
          state: String.t(),
          tool: String.t(),
          preview: map() | nil,
          arguments: String.t() | nil,
          expires_at: DateTime.t() | nil,
          repeatable?: boolean(),
          rejectable?: boolean()
        }

  @typedoc "Why a click did nothing."
  @type refusal ::
          Conversations.refusal()
          | :not_waiting
          | :not_expired
          | :already_waiting
          | :turn_running
          | :click_running
          | :no_arguments
          | :not_stored
          | {:refused, atom()}

  @doc "The outcomes a card's notice takes."
  @spec outcomes() :: [String.t()]
  def outcomes, do: @outcomes

  @doc """
  The user runs the write the card `message_uuid` waits for (see the
  moduledoc). `{:ok, outcome}` — `:confirmed`, `:changed`, `:expired`,
  `:rejected` or `:failed`, written as the card's notice — or `{:error,
  reason}`, after which the card still waits.

  Options: `:request_context` — as for `PhoenixKitAgent.Turns.start/6`;
  `:request_id` is the click's own.
  """
  @spec confirm(Conversations.session_ref(), boolean(), term(), term(), keyword()) ::
          {:ok, :confirmed | :changed | :expired | :rejected | :failed} | {:error, refusal()}
  def confirm(session_ref, impersonated?, conversation_uuid, message_uuid, opts \\ []),
    do: click(session_ref, impersonated?, conversation_uuid, message_uuid, opts, &do_confirm/1)

  @doc """
  The user turns down the write the card `message_uuid` waits for:
  `{:ok, :rejected}` (or `:expired` when the row ran out or is gone, and
  `:confirmed` when core had spent it already: see the moduledoc), written as
  the card's notice.
  """
  @spec reject(Conversations.session_ref(), boolean(), term(), term(), keyword()) ::
          {:ok, :rejected | :expired | :confirmed} | {:error, refusal()}
  def reject(session_ref, impersonated?, conversation_uuid, message_uuid, opts \\ []),
    do: click(session_ref, impersonated?, conversation_uuid, message_uuid, opts, &do_reject/1)

  @doc """
  The user asks again for the write of the card `message_uuid`, whose row ran
  out or is gone: core holds the same call in a new row, a new card with the
  same assistant message (`{:ok, :repeated}`). The old card is closed as
  `expired` if it was not yet. `{:error, :not_expired}` for any other card,
  and for one asked for again already; `{:error, :already_waiting}` when
  another card of this chat still waits for the same tool and arguments.
  """
  @spec repeat(Conversations.session_ref(), boolean(), term(), term(), keyword()) ::
          {:ok, :repeated} | {:error, refusal()}
  def repeat(session_ref, impersonated?, conversation_uuid, message_uuid, opts \\ []),
    do: click(session_ref, impersonated?, conversation_uuid, message_uuid, opts, &do_repeat/1)

  @doc """
  What the chat panel shows of the cards among `messages` (messages of the
  user's chat `conversation_uuid`, as `PhoenixKitAgent.Conversations` hands
  them out): a map from the uuid of each card to `t:card/0`. Only the uuids
  of `messages` are used; the rows are read again in this chat, and a message
  that is not a card of it is left out.

    * `state` — `"waiting"`, an outcome of its notice, `"expired"` for a row
      that ran out or is gone, or `"unavailable"` (the session cannot read it,
      or the row was settled without a notice here);
    * `preview`, `expires_at`, `arguments` — for a waiting card only: core's
      preview (`PhoenixKit.API.Confirm.get_for_user/2`, read with this
      session), when it runs out, and the arguments the model sent, as plain
      JSON text (to be shown as text, never as markup), cut to
      #{@arguments_chars} characters;
    * `repeatable?` — the card ran out, its call is still available, it was
      not asked for again and no other card waits for the same write;
    * `rejectable?` — it can be turned down: it waits, or it is
      `"unavailable"` because the user may no longer use its tool (core lets
      such a row be turned down, not run).
  """
  @spec cards(Conversations.session_ref(), boolean(), term(), [
          %{:uuid => term(), optional(atom()) => term()}
        ]) ::
          {:ok, %{String.t() => card()}} | {:error, Conversations.refusal()}
  def cards(session_ref, impersonated?, conversation_uuid, messages) when is_list(messages) do
    with {:ok, conversation} <-
           Conversations.owned_conversation(session_ref, conversation_uuid,
             impersonated: impersonated?
           ) do
      rows = card_rows(conversation, Enum.map(messages, & &1.uuid))
      settled = outcomes(conversation, Enum.map(rows, & &1.confirmation_uuid))

      {:ok,
       Map.new(rows, fn row ->
         {row.uuid, card(session_ref, conversation, row, settled[row.confirmation_uuid])}
       end)}
    end
  end

  @doc """
  The cards of the user's chat `conversation_uuid` that wait — no notice of
  their `confirmation_uuid` in the chat — wherever they are in it, oldest
  first, as `PhoenixKitAgent.Conversations` hands messages out: what the chat
  panel shows of the cards that are not on the page of the chat it loaded.
  """
  @spec waiting_cards(Conversations.session_ref(), boolean(), term()) ::
          {:ok, [Message.t()]} | {:error, Conversations.refusal()}
  def waiting_cards(session_ref, impersonated?, conversation_uuid) do
    with {:ok, conversation} <-
           Conversations.owned_conversation(session_ref, conversation_uuid,
             impersonated: impersonated?
           ) do
      {:ok,
       conversation |> waiting_query() |> repo().all() |> Enum.map(&Conversations.client_view/1)}
    end
  end

  @doc """
  Gives each card of the user's chat `conversation_uuid` that core no longer
  holds, though no notice says so, the notice of what became of it (see the
  moduledoc). Nothing is written, and no lock is asked for, when there is no
  such card; else under the user's lock, as a click: `{:error,
  :turn_running}` or `{:error, :click_running}`, with nothing written, while a
  turn or a click holds it.
  """
  @spec settle_lapsed(Conversations.session_ref(), boolean(), term()) ::
          :ok | {:error, Conversations.refusal() | :turn_running | :click_running}
  def settle_lapsed(session_ref, impersonated?, conversation_uuid) do
    with {:ok, conversation} <-
           Conversations.owned_conversation(session_ref, conversation_uuid,
             impersonated: impersonated?
           ) do
      if lapsed(session_ref, conversation) == [],
        do: :ok,
        else:
          locked(conversation.user_uuid, fn _click_ref ->
            settle_lapsed_in_turn(session_ref, conversation)
          end)
    end
  end

  @doc false
  # `settle_lapsed/3` for a turn that holds the user's lock already
  # (`PhoenixKitAgent.Turns`, before it reads the history), with the chat it
  # owns. A notice the chat refuses is logged by its codes, as a click's.
  @spec settle_lapsed_in_turn(Conversations.session_ref(), Conversation.t()) :: :ok
  def settle_lapsed_in_turn(session_ref, %Conversation{} = conversation) do
    for {card, outcome} <- lapsed(session_ref, conversation),
        do: settle(%{conversation: conversation, card: card}, outcome)

    :ok
  end

  @doc false
  # Whether a card of the turn's chat waits for the same write: the tool
  # `tool_name` with the arguments `input` (`Tools.arguments/1` of its call),
  # and core still holds its row (read with the turn's session).
  # `PhoenixKitAgent.Turns.Runner` denies such a call instead of holding it a
  # second time.
  @spec waiting_same?(
          %{
            :session_ref => Conversations.session_ref(),
            :user_uuid => String.t(),
            :conversation_uuid => String.t(),
            optional(atom()) => term()
          },
          String.t(),
          map()
        ) :: boolean()
  def waiting_same?(turn, tool_name, input) do
    conversation = %Conversation{uuid: turn.conversation_uuid, user_uuid: turn.user_uuid}

    conversation
    |> waiting_query()
    |> where([m], m.tool_name == ^tool_name)
    |> repo().all()
    |> Enum.any?(
      &(call_input(conversation, &1) == {:ok, input} and
          lapse(&1, turn.session_ref, conversation) == nil)
    )
  end

  # ── a click ─────────────────────────────────────────────────────

  defp click(session_ref, impersonated?, conversation_uuid, message_uuid, opts, action) do
    with {:ok, conversation} <-
           Conversations.owned_conversation(session_ref, conversation_uuid,
             impersonated: impersonated?
           ),
         {:ok, _card} <- card_row(conversation, message_uuid) do
      locked(conversation.user_uuid, fn click_ref ->
        # Read again under the lock: another tab may have settled it.
        with {:ok, card} <- card_row(conversation, message_uuid) do
          action.(%{
            session_ref: session_ref,
            conversation: conversation,
            card: card,
            outcome: outcomes(conversation, [card.confirmation_uuid])[card.confirmation_uuid],
            request_context:
              opts
              |> Keyword.get(:request_context, [])
              |> Keyword.put(:request_id, click_ref)
          })
        end
      end)
    end
  end

  defp locked(user_uuid, fun) do
    click_ref = Locks.click_ref()
    ttl_s = Turns.lock_ttl_s()

    case Locks.acquire_user(user_uuid, click_ref, ttl_s, @hold_s) do
      :ok ->
        # The release covers the keeper failing to start too.
        try do
          keeper = keep_locked(user_uuid, click_ref, ttl_s)

          try do
            fun.(click_ref)
          after
            stop_keeping(keeper)
          end
        after
          Locks.release_user(user_uuid, click_ref)
        end

      {:error, :turn_in_flight} ->
        {:error, :turn_running}

      {:error, :click_in_flight} ->
        {:error, :click_running}
    end
  end

  # The task that keeps the click's lock fresh while the click runs; it ends
  # with the click, however the click ends.
  defp keep_locked(user_uuid, click_ref, ttl_s) do
    owner = self()
    every_ms = keep_every(Application.get_env(:phoenix_kit_agent, :click_keep_ms, @keep_ms))

    {:ok, keeper} =
      Task.Supervisor.start_child(PhoenixKitAgent.Confirmations.TaskSupervisor, fn ->
        keep(user_uuid, click_ref, ttl_s, Process.monitor(owner), every_ms)
      end)

    keeper
  end

  # Often enough to keep the hold, never a busy loop.
  defp keep_every(ms) when is_integer(ms),
    do: ms |> max(@keep_min_ms) |> min(div(@hold_s * 1_000, 2))

  defp keep_every(_not_a_number), do: @keep_ms

  defp keep(user_uuid, click_ref, ttl_s, owner, every_ms) do
    receive do
      :stop -> :ok
      {:DOWN, ^owner, :process, _pid, _reason} -> :ok
    after
      every_ms ->
        keep_once(user_uuid, click_ref, ttl_s)
        keep(user_uuid, click_ref, ttl_s, owner, every_ms)
    end
  end

  # A failed keep is tried again at the next one; its terms are not logged.
  defp keep_once(user_uuid, click_ref, ttl_s) do
    Locks.keep_user(user_uuid, click_ref, ttl_s, @hold_s)
  rescue
    _db_error -> false
  catch
    _kind, _reason -> false
  end

  # Waits for the keeper to end, so no keep runs after the release.
  defp stop_keeping(keeper) do
    ref = Process.monitor(keeper)
    send(keeper, :stop)

    receive do
      {:DOWN, ^ref, :process, ^keeper, _reason} -> :ok
    after
      5_000 ->
        Process.exit(keeper, :kill)
        :ok
    end
  end

  defp do_confirm(%{outcome: nil} = click) do
    with {:ok, input} <- call_input(click.conversation, click.card) do
      click.session_ref
      |> Executor.redeem_as(
        :admin,
        click.card.confirmation_uuid,
        click.card.tool_name,
        input,
        request_context: click.request_context,
        via: "agent"
      )
      |> redeemed(click)
    end
  end

  defp do_confirm(_settled), do: {:error, :not_waiting}

  # The handler ran, or core holds the call in a new row (the values changed).
  defp redeemed({:ok, %{result: result}, _headers}, click) do
    case Tools.held(result) do
      {:ok, new_uuid} ->
        with :ok <- click |> settle_with_card("changed", new_uuid) |> stored("notice and card"),
             do: {:ok, :changed}

      :error ->
        settled(click, "confirmed")
    end
  end

  # The row can no longer be redeemed: spent already, turned down, ran out,
  # or gone (`invalid`: core deleted it).
  defp redeemed({:error, :confirm_token_invalid, _detail, %{reason: "used"}, _headers}, click),
    do: spent(click)

  defp redeemed(
         {:error, :confirm_token_invalid, _detail, %{reason: "rejected"}, _headers},
         click
       ),
       do: settled(click, "rejected")

  defp redeemed({:error, :confirm_token_invalid, _detail, %{reason: reason}, _headers}, click)
       when reason in ["expired", "invalid"],
       do: settled(click, "expired")

  # Spent, then the handler failed: `failed`. Not spent: the card waits.
  defp redeemed({:error, code, _detail, _context, _headers}, click) do
    case row_status(click.card, click.session_ref, click.conversation) do
      {:ok, "used"} -> settled(click, "failed")
      _waiting_or_unreadable -> {:error, {:refused, code}}
    end
  end

  defp do_reject(%{outcome: nil} = click) do
    case Confirm.reject_for_user(click.card.confirmation_uuid, click.session_ref) do
      result when result in [:ok, {:error, :rejected}] -> settled(click, "rejected")
      {:error, reason} when reason in [:expired, :unknown] -> settled(click, "expired")
      {:error, :used} -> spent(click)
      {:error, :unauthorized} -> {:error, :session_gone}
      {:error, reason} -> {:error, {:refused, reason}}
    end
  end

  defp do_reject(_settled), do: {:error, :not_waiting}

  defp settled(click, outcome) do
    with :ok <- settle(click, outcome), do: {:ok, String.to_existing_atom(outcome)}
  end

  # Core spent the row, and no notice here says what became of it: the click
  # that spent it was lost after core spent it, right before the handler ran
  # (see the moduledoc). `confirmed` when core's row reads as used; else the
  # card keeps waiting, with the reason.
  defp spent(click) do
    case row_status(click.card, click.session_ref, click.conversation) do
      {:ok, "used"} -> settled(click, "confirmed")
      {:error, :unauthorized} -> {:error, :session_gone}
      {:error, :forbidden} -> {:error, {:refused, :forbidden}}
      _gone_or_other -> {:error, {:refused, :used}}
    end
  end

  defp do_repeat(click) do
    with :ok <- repeatable(click),
         {:ok, input} <- call_input(click.conversation, click.card),
         :ok <- no_waiting_duplicate(click, input) do
      click.session_ref
      |> Executor.execute_as(:admin, click.card.tool_name, input,
        allow: :all,
        via: "agent",
        request_context: click.request_context
      )
      |> asked_again(click)
    end
  end

  defp asked_again({:ok, %{result: result}, _headers}, click) do
    case Tools.held(result) do
      {:ok, new_uuid} ->
        stored =
          if click.outcome == nil,
            do: click |> settle_with_card("expired", new_uuid) |> stored("notice and card"),
            else: click |> add_card(new_uuid) |> stored("tool")

        with :ok <- stored, do: {:ok, :repeated}

      :error ->
        {:error, {:refused, :not_held}}
    end
  end

  defp asked_again({:error, code, _detail, _context, _headers}, _click),
    do: {:error, {:refused, code}}

  defp repeatable(%{outcome: "expired"} = click), do: not_superseded(click)

  defp repeatable(%{outcome: nil} = click) do
    case Confirm.get_for_user(click.card.confirmation_uuid, click.session_ref) do
      {:ok, %{status: "expired"}} -> not_superseded(click)
      {:error, :unknown} -> not_superseded(click)
      {:error, :forbidden} -> {:error, {:refused, :forbidden}}
      _waiting_or_settled -> {:error, :not_expired}
    end
  end

  defp repeatable(_settled), do: {:error, :not_expired}

  defp not_superseded(click) do
    if superseded?(click.conversation, click.card), do: {:error, :not_expired}, else: :ok
  end

  # A later turn may have asked for the same write with a different assistant
  # message. Check under the click's lock, before asking core for another row.
  defp no_waiting_duplicate(click, input) do
    turn = %{
      session_ref: click.session_ref,
      user_uuid: click.conversation.user_uuid,
      conversation_uuid: click.conversation.uuid
    }

    if waiting_same?(turn, click.card.tool_name, input),
      do: {:error, :already_waiting},
      else: :ok
  end

  defp repeatable_card?(session_ref, conversation, card) do
    click = %{session_ref: session_ref, conversation: conversation, card: card}

    with :ok <- not_superseded(click),
         {:ok, input} <- call_input(conversation, card),
         :ok <- no_waiting_duplicate(click, input) do
      true
    else
      _unavailable -> false
    end
  end

  # ── what a click writes ─────────────────────────────────────────

  defp settle(click, outcome) do
    {attrs, fields} = notice(click, outcome)

    click.conversation.user_uuid
    |> Conversations.add_turn_message(click.conversation.uuid, attrs, fields)
    |> stored("notice")
  end

  defp add_card(click, confirmation_uuid) do
    {attrs, fields} = card_message(click, confirmation_uuid)

    Conversations.add_turn_message(
      click.conversation.user_uuid,
      click.conversation.uuid,
      attrs,
      fields
    )
  end

  # The notice and the new card that follows it, in one transaction.
  defp settle_with_card(click, outcome, confirmation_uuid) do
    Conversations.add_turn_messages(click.conversation.user_uuid, click.conversation.uuid, [
      notice(click, outcome),
      card_message(click, confirmation_uuid)
    ])
  end

  # The card's notice: its outcome and the tool's name; the text is the
  # stored form, the panel shows it by its outcome.
  defp notice(click, outcome) do
    {%{
       role: "notice",
       content: notice_text(outcome),
       tool_name: click.card.tool_name,
       tool_outcome: outcome
     }, [confirmation_uuid: click.card.confirmation_uuid]}
  end

  # A new card for the same call: the same assistant message and call id.
  defp card_message(click, confirmation_uuid) do
    {%{
       role: "tool",
       tool_call_id: click.card.tool_call_id,
       tool_name: click.card.tool_name,
       tool_outcome: "needs_confirmation",
       tool_result: Tools.held_result(confirmation_uuid)
     },
     [
       assistant_message_uuid: click.card.assistant_message_uuid,
       confirmation_uuid: confirmation_uuid
     ]}
  end

  # A refused message is logged by its field names and validation codes only.
  defp stored({:ok, _message_or_messages}, _role), do: :ok

  defp stored({:error, %Ecto.Changeset{} = changeset}, role) do
    codes =
      Enum.map(changeset.errors, fn {field, {_text, opts}} -> {field, opts[:validation]} end)

    Logger.warning(
      "[PhoenixKitAgent] a #{role} message of a confirmation was not stored: #{inspect(codes)}"
    )

    {:error, :not_stored}
  end

  defp stored({:error, reason}, role) when is_atom(reason) do
    Logger.warning(
      "[PhoenixKitAgent] a #{role} message of a confirmation was not stored: #{reason}"
    )

    {:error, :not_stored}
  end

  defp notice_text("confirmed"), do: "The change was made."
  defp notice_text("rejected"), do: "The change was cancelled."
  defp notice_text("expired"), do: "The confirmation ran out; nothing was changed."
  defp notice_text("changed"), do: "The data changed since the preview; check the new one."
  defp notice_text("failed"), do: "The change failed."

  # ── reading ─────────────────────────────────────────────────────

  defp card(session_ref, conversation, row, nil) do
    base = %{
      state: "waiting",
      tool: row.tool_name,
      preview: nil,
      arguments: nil,
      expires_at: nil,
      repeatable?: false,
      rejectable?: false
    }

    case Confirm.get_for_user(row.confirmation_uuid, session_ref) do
      {:ok, %{status: "unused"} = held} ->
        %{
          base
          | preview: held.preview,
            expires_at: held.expires_at,
            arguments: arguments_text(conversation, row),
            rejectable?: true
        }

      {:ok, %{status: "expired"}} ->
        %{base | state: "expired", repeatable?: repeatable_card?(session_ref, conversation, row)}

      {:error, :unknown} ->
        %{base | state: "expired", repeatable?: repeatable_card?(session_ref, conversation, row)}

      # The user may no longer use its tool: it cannot run, but core lets it
      # be turned down.
      {:error, :forbidden} ->
        %{base | state: "unavailable", rejectable?: true}

      _settled_elsewhere_or_unreadable ->
        %{base | state: "unavailable"}
    end
  end

  defp card(session_ref, conversation, row, outcome) do
    %{
      state: outcome,
      tool: row.tool_name,
      preview: nil,
      arguments: nil,
      expires_at: nil,
      repeatable?: outcome == "expired" and repeatable_card?(session_ref, conversation, row),
      rejectable?: false
    }
  end

  defp arguments_text(conversation, row) do
    case call_input(conversation, row) do
      {:ok, input} ->
        text = Jason.encode!(input, pretty: true)

        if String.length(text) > @arguments_chars,
          do: String.slice(text, 0, @arguments_chars) <> "…",
          else: text

      {:error, :no_arguments} ->
        nil
    end
  end

  # The arguments the call went to core with: those of the call with the
  # card's id in its assistant message, without control fields.
  defp call_input(conversation, card) do
    with uuid when is_binary(uuid) <- card.assistant_message_uuid,
         %Message{tool_calls: calls} when is_list(calls) <-
           repo().one(
             from(m in Message,
               where:
                 m.uuid == ^uuid and m.conversation_uuid == ^conversation.uuid and
                   m.role == "assistant"
             )
           ),
         [call] <- Enum.filter(calls, &(&1["id"] == card.tool_call_id)),
         {:ok, input} <- Tools.arguments(call["arguments"]) do
      {:ok, input}
    else
      _missing -> {:error, :no_arguments}
    end
  end

  defp card_row(%Conversation{} = conversation, message_uuid) do
    case card_rows(conversation, [message_uuid]) do
      [card] -> {:ok, card}
      [] -> {:error, :not_waiting}
    end
  end

  defp card_rows(conversation, message_uuids) do
    uuids =
      for uuid <- message_uuids, {:ok, cast} <- [Ecto.UUID.cast(uuid)], uniq: true, do: cast

    repo().all(
      from(m in Message,
        where:
          m.conversation_uuid == ^conversation.uuid and m.uuid in ^uuids and m.role == "tool" and
            m.tool_outcome == "needs_confirmation" and not is_nil(m.confirmation_uuid),
        order_by: [asc: m.inserted_at, asc: m.uuid]
      )
    )
  end

  # The cards of the chat with no notice that core no longer holds, each with
  # the outcome its notice is to say.
  defp lapsed(session_ref, conversation) do
    for card <- conversation |> waiting_query() |> repo().all(),
        outcome = lapse(card, session_ref, conversation),
        outcome != nil,
        do: {card, outcome}
  end

  defp lapse(card, session_ref, conversation) do
    case row_status(card, session_ref, conversation) do
      {:ok, "used"} -> "confirmed"
      {:ok, "rejected"} -> "rejected"
      {:ok, "expired"} -> "expired"
      {:error, :unknown} -> "expired"
      _waiting_or_unreadable -> nil
    end
  end

  # The status of the card's row, read with the session (`get_for_user/2`).
  # Core withholds that read once the user may no longer use the tool
  # (`:forbidden`); the user's own row (`lookup_for_user/2`) still says
  # whether it was spent, turned down or ran out.
  defp row_status(card, session_ref, conversation) do
    case Confirm.get_for_user(card.confirmation_uuid, session_ref) do
      {:ok, %{status: status}} -> {:ok, status}
      {:error, :forbidden} -> own_row_status(card, conversation)
      {:error, _unauthorized_or_unknown} = error -> error
    end
  end

  defp own_row_status(card, conversation) do
    case Confirm.lookup_for_user(card.confirmation_uuid, conversation.user_uuid) do
      {:ok, %{status: "unused", expires_at: expires_at}} ->
        if DateTime.compare(expires_at, DateTime.utc_now()) == :gt,
          do: {:error, :forbidden},
          else: {:ok, "expired"}

      {:ok, %{status: status}} ->
        {:ok, status}

      {:error, :unknown} ->
        {:error, :unknown}
    end
  end

  # The cards of the chat with no notice of their confirmation.
  defp waiting_query(conversation) do
    from(m in Message,
      as: :card,
      where:
        m.conversation_uuid == ^conversation.uuid and m.role == "tool" and
          m.tool_outcome == "needs_confirmation" and not is_nil(m.confirmation_uuid) and
          not exists(
            from(n in Message,
              where:
                n.conversation_uuid == ^conversation.uuid and n.role == "notice" and
                  n.confirmation_uuid == parent_as(:card).confirmation_uuid and
                  n.tool_outcome in ^@outcomes
            )
          ),
      order_by: [asc: m.inserted_at, asc: m.uuid]
    )
  end

  # The outcome of each confirmation that has its notice in the chat.
  defp outcomes(_conversation, []), do: %{}

  defp outcomes(conversation, confirmation_uuids) do
    repo().all(
      from(m in Message,
        where:
          m.conversation_uuid == ^conversation.uuid and m.role == "notice" and
            m.confirmation_uuid in ^confirmation_uuids and m.tool_outcome in ^@outcomes,
        order_by: [asc: m.inserted_at, asc: m.uuid],
        select: {m.confirmation_uuid, m.tool_outcome}
      )
    )
    |> Map.new()
  end

  # A later card of the same call (asked for again, or the values changed).
  defp superseded?(_conversation, %{assistant_message_uuid: nil}), do: false

  defp superseded?(conversation, card) do
    repo().exists?(
      from(m in Message,
        where:
          m.conversation_uuid == ^conversation.uuid and m.role == "tool" and
            m.tool_outcome == "needs_confirmation" and
            m.assistant_message_uuid == ^card.assistant_message_uuid and
            m.tool_call_id == ^card.tool_call_id and m.uuid != ^card.uuid and
            (m.inserted_at > ^card.inserted_at or
               (m.inserted_at == ^card.inserted_at and m.uuid > ^card.uuid))
      )
    )
  end

  defp repo, do: RepoHelper.repo()
end
