defmodule PhoenixKitAgent.Conversations do
  @moduledoc """
  The chats and messages of the assistant (spec §5.1-5.2, §8, §10).

  Every function acts for a **live browser session**, never for a bare user
  uuid: the first argument is the `{session_token_uuid, user_uuid}` reference
  that `PhoenixKit.Users.Auth.SessionRef.from_session/1` reads from a
  LiveView's signed session (in its connected mount), and the last is a
  keyword list that must carry `impersonated: boolean` — the answer of
  `PhoenixKitWeb.Users.MultiSession.impersonated?/1` for the same session.
  The flag has no default on purpose: a caller that forgets it raises
  `ArgumentError` instead of being let in.

  Each call is checked in this order, and the first failure is the answer:

    1. `impersonated: true` — `{:error, :impersonated}`. An operator who
       entered a user's session through impersonation would otherwise read the
       whole chat history (customer data from tool results) and write as the
       user, spending their limits (spec §8, В13). Nothing is read or written.
    2. The session's scope (`SessionRef.scope_for_session/2`): a revoked or
       expired session, a blocked user, a session of another user —
       `{:error, :session_gone | :mismatch | :inactive | :unconfirmed |
       :referral_required}`. The scope is rebuilt on every call, so a logout
       takes effect on the next one.
    3. The module is enabled, the scope holds `agent`, and the assistant is
       not switched off for the user (`user_settings.enabled`) —
       `{:error, :forbidden}`.
    4. For one chat: it belongs to the session's user. Anything else — someone
       else's chat, a deleted one, one that never existed, a malformed uuid —
       is the same `{:error, :not_found}`, so the answer does not reveal that
       a chat exists.

  The owner is the only one who reads or writes a chat. A soft-deleted chat
  (`status: "deleted"`) is gone for every function here; an archived one is
  left out of `list_conversations/2` only, and can still be opened and
  written to (a turn in flight when the user archives the chat must still be
  able to save its answer). Renaming, archiving and deleting are one
  conditional `UPDATE` each (the owner's chat, not deleted), so a concurrent
  archive cannot bring a deleted chat back.

  ## Writing

  A session writes only its user's text: `add_message/4` stores a `user`
  message with `content` and ignores every other attribute. Model answers,
  tool calls and results, notices and their tokens and cost are written by
  the turn loop (`PhoenixKitAgent.Turns`) alone.

  ## Reading: what a client gets of a message

  `get_conversation/3`, `get_message/4` and `list_messages/3` never hand out
  what a tool returned, nor the arguments the model gave a tool (customer data
  read under the rights the session had then): a `tool` message comes with
  `tool_result: nil` and `tool_summary: %{name:, outcome:, count:,
  truncated:}` (`count` — how many items it found, when the result has one
  list or a `count`/`total`; `nil` otherwise), and the `tool_calls` of an
  `assistant` message keep only `"id"` and `"name"`. The turn loop reads the
  full rows on its own (spec §6.6).

  ## Events

  Every stored message is broadcast as `{:agent_message_added,
  conversation_uuid, message_uuid}` on `topic/1` (`"agent:conv:<uuid>"`)
  after it is committed. The event carries uuids, not the message: a listener
  reads it through `get_message/4` (or `list_messages/3` with `after:`), with
  a fresh scope. `subscribe/3` subscribes only after the checks above;
  `unsubscribe/1` undoes it (subscribing twice delivers every event twice).
  The topic also hears `{:agent_attachment_processed, conversation_uuid,
  attachment_uuid}` when a file added to the chat is ready or has failed
  (`PhoenixKitAgent.Attachments`). PubSub is in-process and anyone in the VM
  can subscribe to a topic
  directly; the check guards the code that serves a user's browser, not
  hostile code in the node.
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.PubSub.Manager, as: PubSub
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.SessionRef
  alias PhoenixKitAgent.Config
  alias PhoenixKitAgent.Schemas.{Attachment, Conversation, Message}
  alias PhoenixKitAgent.UserConfig

  @page_size 20
  @max_page_size 50
  @messages_page_size 50
  @max_messages_page_size 200
  @title_from_message 60

  @typedoc "`{session_token_uuid, user_uuid}` from `SessionRef.from_session/1`."
  @type session_ref :: SessionRef.t()

  @typedoc "Where the next page of the list starts; opaque, taken from `list_conversations/2`."
  @type cursor :: {DateTime.t(), String.t()}

  @typedoc "What a client learns of a tool call's result (see the moduledoc)."
  @type tool_summary :: %{
          name: String.t() | nil,
          outcome: String.t() | nil,
          count: non_neg_integer() | nil,
          truncated: boolean()
        }

  @typedoc "Why a call was refused."
  @type refusal ::
          :impersonated
          | SessionRef.refusal()
          | :forbidden
          | :not_found

  @doc "The PubSub topic of a chat's events."
  @spec topic(String.t()) :: String.t()
  def topic(conversation_uuid), do: "agent:conv:" <> conversation_uuid

  @doc """
  Creates an empty active chat for the session's user. `attrs` may carry a
  `:title`; the owner and status are never taken from it.
  """
  @spec create_conversation(session_ref(), map(), keyword()) ::
          {:ok, Conversation.t()} | {:error, refusal() | Ecto.Changeset.t()}
  def create_conversation(session_ref, attrs, opts) when is_map(attrs) do
    title = Map.get(attrs, :title, Map.get(attrs, "title"))

    with_user(session_ref, opts, fn user_uuid ->
      %Conversation{user_uuid: user_uuid, last_message_at: DateTime.utc_now()}
      |> Conversation.changeset(%{title: trim(title)})
      |> repo().insert(log: false)
    end)
  end

  @doc """
  The user's active chats, newest `last_message_at` first, one page at a time.

  Options (besides `impersonated:`): `:limit` (default 20, at most 50) and
  `:cursor`, the `next_cursor` of the previous page. Returns the chats and the
  cursor of the next page (`nil` on the last one). Archived and deleted chats
  are not listed. Messages are not loaded.
  """
  @spec list_conversations(session_ref(), keyword()) ::
          {:ok, %{conversations: [Conversation.t()], next_cursor: cursor() | nil}}
          | {:error, refusal() | :invalid_cursor}
  def list_conversations(session_ref, opts) do
    with_user(session_ref, opts, fn user_uuid ->
      with {:ok, cursor} <- cursor(Keyword.get(opts, :cursor)) do
        {:ok, page(user_uuid, cursor, page_size(Keyword.get(opts, :limit)))}
      end
    end)
  end

  @doc """
  The user's chat with all its messages, oldest first, as a client sees them
  (see "Reading" in the moduledoc).
  """
  @spec get_conversation(session_ref(), term(), keyword()) ::
          {:ok, Conversation.t()} | {:error, refusal()}
  def get_conversation(session_ref, conversation_uuid, opts) do
    with_owned(session_ref, conversation_uuid, opts, fn conversation ->
      messages = from(m in Message, order_by: [asc: m.inserted_at, asc: m.uuid])
      conversation = repo().preload(conversation, messages: messages)
      {:ok, %{conversation | messages: Enum.map(conversation.messages, &for_client/1)}}
    end)
  end

  @doc """
  One message of the user's chat, as a client sees it (see "Reading" in the
  moduledoc) — what a listener of `{:agent_message_added, conversation_uuid,
  message_uuid}` reads. A message of another chat, or none, is
  `{:error, :not_found}`.
  """
  @spec get_message(session_ref(), term(), term(), keyword()) ::
          {:ok, Message.t()} | {:error, refusal()}
  def get_message(session_ref, conversation_uuid, message_uuid, opts) do
    with_owned(session_ref, conversation_uuid, opts, fn conversation ->
      with {:ok, uuid} <- Ecto.UUID.cast(message_uuid),
           %Message{} = message <-
             repo().one(
               from(m in Message,
                 where: m.uuid == ^uuid and m.conversation_uuid == ^conversation.uuid
               )
             ) do
        {:ok, for_client(message)}
      else
        _unknown -> {:error, :not_found}
      end
    end)
  end

  @doc """
  The messages of the user's chat, oldest first, as a client sees them (see
  "Reading" in the moduledoc).

  Options (besides `impersonated:`): `:after` — the uuid of a message of this
  chat; only the messages after it come; `:limit` — default 50, at most 200.
  The next page starts after the last message of this one. From the other
  end: `latest: true` — the last `limit` messages of the chat; `:before` — the
  uuid of a message of this chat, the `limit` messages just before it (the
  page before starts before the first message of this one). Every page is
  oldest first. A cursor that is not a message of this chat, or `:after` with
  `:before` / `:latest`, is `{:error, :invalid_cursor}`.
  """
  @spec list_messages(session_ref(), term(), keyword()) ::
          {:ok, [Message.t()]} | {:error, refusal() | :invalid_cursor}
  def list_messages(session_ref, conversation_uuid, opts) do
    with_owned(session_ref, conversation_uuid, opts, fn conversation ->
      with {:ok, query, direction} <- messages_query(conversation, opts) do
        size = messages_page_size(Keyword.get(opts, :limit))

        messages =
          from(m in query,
            order_by: [{^direction, m.inserted_at}, {^direction, m.uuid}],
            limit: ^size
          )
          |> repo().all()

        messages = if direction == :desc, do: Enum.reverse(messages), else: messages
        {:ok, Enum.map(messages, &for_client/1)}
      end
    end)
  end

  @doc false
  # `get_conversation/3` without the messages, for `PhoenixKitAgent.Turns`
  # and the chat panel (`PhoenixKitAgent.Web.Dock`): the same checks, and the
  # chat row only.
  @spec owned_conversation(session_ref(), term(), keyword()) ::
          {:ok, Conversation.t()} | {:error, refusal()}
  def owned_conversation(session_ref, conversation_uuid, opts),
    do: with_owned(session_ref, conversation_uuid, opts, &{:ok, &1})

  @doc "Renames a chat. A blank title or one over 200 characters is an `{:error, changeset}`."
  @spec rename_conversation(session_ref(), term(), term(), keyword()) ::
          {:ok, Conversation.t()} | {:error, refusal() | Ecto.Changeset.t()}
  def rename_conversation(session_ref, conversation_uuid, title, opts) do
    with_owned(session_ref, conversation_uuid, opts, fn conversation ->
      changeset =
        conversation
        |> Conversation.changeset(%{title: trim(title)})
        |> Ecto.Changeset.validate_required([:title])

      if changeset.valid?,
        do: update_owned(conversation, title: Ecto.Changeset.get_field(changeset, :title)),
        else: {:error, %{changeset | action: :update}}
    end)
  end

  @doc "Archives a chat: it leaves the list, nothing is deleted."
  @spec archive_conversation(session_ref(), term(), keyword()) ::
          {:ok, Conversation.t()} | {:error, refusal() | Ecto.Changeset.t()}
  def archive_conversation(session_ref, conversation_uuid, opts),
    do: set_status(session_ref, conversation_uuid, "archived", opts)

  @doc """
  Soft-deletes a chat: its row and messages stay, but no function here sees it
  any more.
  """
  @spec delete_conversation(session_ref(), term(), keyword()) ::
          {:ok, Conversation.t()} | {:error, refusal() | Ecto.Changeset.t()}
  def delete_conversation(session_ref, conversation_uuid, opts),
    do: set_status(session_ref, conversation_uuid, "deleted", opts)

  @doc """
  Adds the user's text to their chat, as a `user` message: only `content`
  (`:content` or `"content"`, not blank, and no longer than
  `agent_history_chars`, as a turn takes it) is taken from `attrs`, never a role,
  tool fields, tokens or cost (see "Writing" in the moduledoc). The chat is
  updated in the same transaction: the message count, `last_message_at` and —
  when the chat has no title yet — the title, the first 60 characters of the
  text. After the commit the chat's topic hears `{:agent_message_added,
  conversation_uuid, message_uuid}`.
  """
  @spec add_message(session_ref(), term(), map(), keyword()) ::
          {:ok, Message.t()} | {:error, refusal() | Ecto.Changeset.t()}
  def add_message(session_ref, conversation_uuid, attrs, opts) when is_map(attrs) do
    content = Map.get(attrs, :content, Map.get(attrs, "content"))

    with_user(session_ref, opts, fn user_uuid ->
      store(
        user_uuid,
        conversation_uuid,
        &(&1
          |> Message.user_changeset(%{content: content})
          |> Ecto.Changeset.validate_length(:content, max: Config.history_chars())),
        [],
        []
      )
    end)
  end

  @doc false
  # The turn loop's write (`PhoenixKitAgent.Turns`): any role, every field of
  # `Message.changeset/2`, and the totals follow the message's tokens and
  # cost. No session checks: the turn checked the session when it started and
  # checks it again every round, and must still be able to write the notice
  # that says the session is gone. The chat must belong to `user_uuid` (not
  # deleted). `fields` are set on the struct, never cast: `:uuid` (given to
  # the model call before the message exists), `:ai_request_uuid`, and the
  # links of a confirmation, `:assistant_message_uuid` and
  # `:confirmation_uuid` (`PhoenixKitAgent.Confirmations`). Never
  # call it from a client's event, nor inside an outer transaction (the event
  # would go out before that transaction commits).
  @spec add_turn_message(String.t(), term(), map(), keyword()) ::
          {:ok, Message.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def add_turn_message(user_uuid, conversation_uuid, attrs, fields \\ []) when is_map(attrs) do
    store(user_uuid, conversation_uuid, &Message.changeset(&1, attrs), fields, [])
  end

  @doc false
  # `add_turn_message/4` for the user's message of a turn, which takes the
  # attachments `attachment_uuids` (the user's own, not yet part of a message)
  # in the same transaction: a turn stopped between the two cannot leave the
  # message without its files.
  @spec add_user_turn_message(String.t(), term(), map(), [String.t()]) ::
          {:ok, Message.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def add_user_turn_message(user_uuid, conversation_uuid, attrs, attachment_uuids)
      when is_map(attrs) and is_list(attachment_uuids) do
    store(user_uuid, conversation_uuid, &Message.changeset(&1, attrs), [], attachment_uuids)
  end

  @doc false
  # `add_turn_message/4` for several messages, each `{attrs, fields}`, in one
  # transaction and in this order: all of them are stored, or none
  # (`PhoenixKitAgent.Confirmations`: a card's notice and the new card that
  # follows it). The events go out once the transaction has committed.
  @spec add_turn_messages(String.t(), term(), [{map(), keyword()}]) ::
          {:ok, [Message.t()]} | {:error, :not_found | Ecto.Changeset.t()}
  def add_turn_messages(user_uuid, conversation_uuid, entries) when is_list(entries) do
    result =
      repo().transaction(fn ->
        case fetch_owned(user_uuid, conversation_uuid, lock: true) do
          {:ok, conversation} -> Enum.map(entries, &insert_or_roll_back(conversation, &1))
          {:error, reason} -> repo().rollback(reason)
        end
      end)

    with {:ok, messages} <- result, do: Enum.each(messages, &announce/1)
    result
  end

  defp insert_or_roll_back(conversation, {attrs, fields}) when is_map(attrs) do
    case insert_message(conversation, &Message.changeset(&1, attrs), fields) do
      {:ok, message} -> message
      {:error, reason} -> repo().rollback(reason)
    end
  end

  defp store(user_uuid, conversation_uuid, changeset_fun, fields, attachment_uuids) do
    result =
      repo().transaction(fn ->
        with {:ok, conversation} <- fetch_owned(user_uuid, conversation_uuid, lock: true),
             {:ok, message} <- insert_message(conversation, changeset_fun, fields) do
          link_attachments(attachment_uuids, conversation, message)
          message
        else
          {:error, reason} -> repo().rollback(reason)
        end
      end)

    with {:ok, %Message{} = message} <- result, do: announce(message)
    result
  end

  defp announce(%Message{} = message) do
    PubSub.broadcast(
      topic(message.conversation_uuid),
      {:agent_message_added, message.conversation_uuid, message.uuid}
    )
  end

  defp link_attachments([], _conversation, _message), do: :ok

  # Only the chat owner's own unsent files of this chat, whatever the caller
  # passes.
  defp link_attachments(uuids, conversation, %Message{} = message) do
    repo().update_all(
      from(a in Attachment,
        where:
          a.uuid in ^uuids and is_nil(a.message_uuid) and
            a.user_uuid == ^conversation.user_uuid and
            a.conversation_uuid == ^conversation.uuid
      ),
      set: [message_uuid: message.uuid]
    )

    :ok
  end

  @doc false
  # The files linked to the user message `message_uuid` back to "not sent"
  # (`PhoenixKitAgent.Turns.Runner`: a model that refused the pictures).
  @spec unlink_attachments(String.t(), String.t(), String.t()) :: :ok
  def unlink_attachments(user_uuid, conversation_uuid, message_uuid) do
    repo().update_all(
      from(a in Attachment,
        where:
          a.message_uuid == ^message_uuid and a.user_uuid == ^user_uuid and
            a.conversation_uuid == ^conversation_uuid
      ),
      set: [message_uuid: nil]
    )

    :ok
  end

  @doc """
  Checks 1-3 of the moduledoc for a session, without a chat: `{:ok,
  user_uuid}` when the session may use the assistant now.
  """
  @spec authorize_session(session_ref(), keyword()) ::
          {:ok, String.t()} | {:error, refusal()}
  def authorize_session(session_ref, opts),
    do: with_user(session_ref, opts, fn user_uuid -> {:ok, user_uuid} end)

  @doc false
  # `authorize_session/2`, handing back the session's scope as well: for
  # `PhoenixKitAgent.Turns`, which tells the model who the user is.
  @spec authorized_scope(session_ref(), keyword()) :: {:ok, Scope.t()} | {:error, refusal()}
  def authorized_scope(session_ref, opts),
    do: with_scope(session_ref, opts, &{:ok, &1})

  @doc """
  Subscribes the calling process to the chat's topic, but only after the
  checks of the moduledoc — a chat of someone else is `{:error, :not_found}`
  and nothing is subscribed.
  """
  @spec subscribe(session_ref(), term(), keyword()) :: :ok | {:error, refusal()}
  def subscribe(session_ref, conversation_uuid, opts) do
    with_owned(session_ref, conversation_uuid, opts, fn conversation ->
      PubSub.subscribe(topic(conversation.uuid))
    end)
  end

  @doc "Unsubscribes the calling process from the chat's topic; no checks are needed."
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(conversation_uuid) when is_binary(conversation_uuid),
    do: PubSub.unsubscribe(topic(conversation_uuid))

  # ── the gate ────────────────────────────────────────────────────

  # Runs `fun.(user_uuid)` for a session that passes the checks 1-3 of the
  # moduledoc. A `fun` result of `:ok`, `{:ok, _}` or `{:error, _}` is the
  # answer as is.
  defp with_user(session_ref, opts, fun),
    do: with_scope(session_ref, opts, &fun.(Scope.user_uuid(&1)))

  defp with_scope(session_ref, opts, fun) do
    with :ok <- not_impersonated(impersonated!(opts)),
         {:ok, scope} <- scope_for(session_ref),
         :ok <- authorize(scope, Scope.user_uuid(scope)) do
      fun.(scope)
    end
  end

  # `fun.(conversation)` for a chat of the session's user (check 4).
  defp with_owned(session_ref, conversation_uuid, opts, fun) do
    with_user(session_ref, opts, fn user_uuid ->
      with {:ok, conversation} <- fetch_owned(user_uuid, conversation_uuid) do
        fun.(conversation)
      end
    end)
  end

  defp impersonated!(opts) do
    case Keyword.fetch(opts, :impersonated) do
      {:ok, flag} when is_boolean(flag) ->
        flag

      _missing_or_malformed ->
        raise ArgumentError,
              "PhoenixKitAgent.Conversations needs `impersonated: true | false` in its options " <>
                "(MultiSession.impersonated?/1 of the session); got: #{inspect(opts)}"
    end
  end

  defp not_impersonated(false), do: :ok
  defp not_impersonated(true), do: {:error, :impersonated}

  defp scope_for({session_token_uuid, user_uuid}),
    do: SessionRef.scope_for_session(session_token_uuid, user_uuid)

  defp scope_for(_not_a_reference), do: {:error, :session_gone}

  defp authorize(scope, user_uuid) do
    if PhoenixKitAgent.enabled?() and Scope.can?(scope, "agent") and
         UserConfig.enabled?(user_uuid),
       do: :ok,
       else: {:error, :forbidden}
  end

  defp fetch_owned(user_uuid, conversation_uuid, opts \\ []) do
    with {:ok, uuid} <- Ecto.UUID.cast(conversation_uuid),
         %Conversation{} = conversation <-
           uuid |> owned_query(user_uuid) |> lock(opts[:lock]) |> repo().one() do
      {:ok, conversation}
    else
      _unknown_or_not_theirs -> {:error, :not_found}
    end
  end

  defp owned_query(uuid, user_uuid) do
    from(c in Conversation,
      where: c.uuid == ^uuid and c.user_uuid == ^user_uuid and c.status != "deleted"
    )
  end

  defp lock(query, true), do: from(c in query, lock: "FOR UPDATE")
  defp lock(query, _no_lock), do: query

  # ── helpers ─────────────────────────────────────────────────────

  defp set_status(session_ref, conversation_uuid, status, opts) do
    with_owned(session_ref, conversation_uuid, opts, fn conversation ->
      update_owned(conversation, status: status)
    end)
  end

  # One statement that changes the chat only while it is the owner's and not
  # deleted: a chat deleted after `with_owned/4` read it stays deleted.
  defp update_owned(conversation, changes) do
    query =
      from(c in owned_query(conversation.uuid, conversation.user_uuid), select: c)

    case repo().update_all(query, [set: changes ++ [updated_at: DateTime.utc_now()]], log: false) do
      {1, [updated]} -> {:ok, updated}
      {0, _} -> {:error, :not_found}
    end
  end

  defp trim(title) when is_binary(title), do: title |> Message.strip_nul() |> String.trim()
  defp trim(title), do: title

  defp insert_message(conversation, changeset_fun, fields) do
    message =
      struct(
        Message,
        [conversation_uuid: conversation.uuid] ++
          Keyword.take(fields, [
            :uuid,
            :ai_request_uuid,
            :assistant_message_uuid,
            :confirmation_uuid
          ])
      )

    # `log: false`: the bound values are the user's text, the model's answer
    # and tool results, which must not reach the query log.
    with {:ok, message} <- message |> changeset_fun.() |> repo().insert(log: false) do
      touch(conversation, message)
      {:ok, message}
    end
  end

  @doc false
  # What a client gets of a message of the chat (see "Reading" in the
  # moduledoc), for `PhoenixKitAgent.Confirmations`, which reads its cards
  # itself.
  @spec client_view(Message.t()) :: Message.t()
  def client_view(%Message{} = message), do: for_client(message)

  # What a client gets of a message (see "Reading" in the moduledoc).
  defp for_client(%Message{role: "tool"} = message) do
    %{
      message
      | tool_result: nil,
        tool_summary: %{
          name: message.tool_name,
          outcome: message.tool_outcome,
          count: found_count(message.tool_result),
          truncated: truncated?(message.tool_result)
        }
    }
  end

  defp for_client(%Message{tool_calls: calls} = message) when is_list(calls) do
    %{message | tool_calls: Enum.map(calls, &Map.take(&1, ["id", "name"]))}
  end

  defp for_client(message), do: message

  defp truncated?(%{"truncated" => true}), do: true
  defp truncated?(_result), do: false

  # How many items a result found: its only list, else its `count` / `total`.
  defp found_count(%{"truncated" => true}), do: nil

  defp found_count(result) when is_map(result) do
    case Enum.filter(Map.values(result), &is_list/1) do
      [list] ->
        length(list)

      _none_or_several ->
        Enum.find_value(["count", "total"], fn key ->
          case result[key] do
            n when is_integer(n) and n >= 0 -> n
            _ -> nil
          end
        end)
    end
  end

  defp found_count(_result), do: nil

  # The messages a page is taken from, and the order it is taken in (`:desc`
  # for a page that ends at the latest message or at `:before`).
  defp messages_query(conversation, opts) do
    case {Keyword.get(opts, :after), Keyword.get(opts, :before), Keyword.get(opts, :latest)} do
      {nil, nil, latest} when latest in [nil, false] ->
        {:ok, all_messages(conversation), :asc}

      {nil, nil, true} ->
        {:ok, all_messages(conversation), :desc}

      {after_uuid, nil, latest} when after_uuid != nil and latest in [nil, false] ->
        with {:ok, uuid, at} <- message_cursor(conversation, after_uuid) do
          query =
            from(m in all_messages(conversation),
              where: m.inserted_at > ^at or (m.inserted_at == ^at and m.uuid > ^uuid)
            )

          {:ok, query, :asc}
        end

      {nil, before_uuid, _latest} when before_uuid != nil ->
        with {:ok, uuid, at} <- message_cursor(conversation, before_uuid) do
          query =
            from(m in all_messages(conversation),
              where: m.inserted_at < ^at or (m.inserted_at == ^at and m.uuid < ^uuid)
            )

          {:ok, query, :desc}
        end

      _both_ends ->
        {:error, :invalid_cursor}
    end
  end

  defp all_messages(conversation),
    do: from(m in Message, where: m.conversation_uuid == ^conversation.uuid)

  defp message_cursor(conversation, message_uuid) do
    with {:ok, uuid} <- Ecto.UUID.cast(message_uuid),
         %DateTime{} = at <-
           repo().one(
             from(m in Message,
               where: m.uuid == ^uuid and m.conversation_uuid == ^conversation.uuid,
               select: m.inserted_at
             )
           ) do
      {:ok, uuid, at}
    else
      _not_a_message_here -> {:error, :invalid_cursor}
    end
  end

  defp messages_page_size(limit) when is_integer(limit),
    do: limit |> max(1) |> min(@max_messages_page_size)

  defp messages_page_size(_default), do: @messages_page_size

  # The chat's totals follow the message. `COALESCE` keeps a title that is
  # already there (set by hand or by the first user message).
  defp touch(conversation, message) do
    now = DateTime.utc_now()

    from(c in Conversation,
      where: c.uuid == ^conversation.uuid,
      update: [
        inc: [
          message_count: 1,
          input_tokens: ^(message.input_tokens || 0),
          output_tokens: ^(message.output_tokens || 0),
          cost_micro_usd: ^(message.cost_micro_usd || 0)
        ],
        set: [
          last_message_at: ^now,
          updated_at: ^now,
          title: fragment("COALESCE(?, ?)", c.title, type(^title_from(message), :string))
        ]
      ]
    )
    |> repo().update_all([], log: false)
  end

  defp title_from(%Message{role: "user", content: content}) when is_binary(content) do
    case String.trim(content) do
      "" -> nil
      text -> String.slice(text, 0, @title_from_message)
    end
  end

  defp title_from(_message), do: nil

  defp page_size(limit) when is_integer(limit), do: limit |> max(1) |> min(@max_page_size)
  defp page_size(_default), do: @page_size

  defp cursor(nil), do: {:ok, nil}

  defp cursor({%DateTime{} = sort_key, uuid}) do
    case Ecto.UUID.cast(uuid) do
      {:ok, uuid} -> {:ok, {sort_key, uuid}}
      :error -> {:error, :invalid_cursor}
    end
  end

  defp cursor(_malformed), do: {:error, :invalid_cursor}

  # The sort key is `last_message_at`, or `inserted_at` for a chat that has no
  # message time yet; the uuid (time-ordered) breaks ties, so the cursor is
  # exact and a chat that moves up between two pages cannot make a page repeat.
  defp page(user_uuid, cursor, size) do
    rows =
      from(c in Conversation,
        where: c.user_uuid == ^user_uuid and c.status == "active",
        order_by: [
          desc: fragment("coalesce(?, ?)", c.last_message_at, c.inserted_at),
          desc: c.uuid
        ],
        limit: ^(size + 1)
      )
      |> after_cursor(cursor)
      |> repo().all()

    {conversations, rest} = Enum.split(rows, size)
    %{conversations: conversations, next_cursor: next_cursor(conversations, rest)}
  end

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, {sort_key, uuid}) do
    from(c in query,
      where:
        fragment("coalesce(?, ?)", c.last_message_at, c.inserted_at) < ^sort_key or
          (fragment("coalesce(?, ?)", c.last_message_at, c.inserted_at) == ^sort_key and
             c.uuid < ^uuid)
    )
  end

  defp next_cursor(_conversations, []), do: nil

  defp next_cursor(conversations, _rest) do
    last = List.last(conversations)
    {last.last_message_at || last.inserted_at, last.uuid}
  end

  defp repo, do: RepoHelper.repo()
end
