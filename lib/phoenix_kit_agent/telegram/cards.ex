defmodule PhoenixKitAgent.Telegram.Cards do
  @moduledoc """
  The cards of held changes in the Telegram chat: sending one
  (`deliver/4`, for the turn that held the change, and for the new card of a
  change whose data moved) and keeping it true to what became of it
  (`notice_added/1`).

  A card is sent as a message with the buttons of `PhoenixKitAgent.Telegram.Card`,
  and where it went (bot, chat, message) is kept in the metadata of its
  conversation (`Conversations.put_telegram_card/6`). When the outcome of a
  card is written as a `notice` — by a press of the button, by the site, by
  the next turn settling a card that ran out — the hook of
  `Conversations` (after the notice is committed) calls `notice_added/1`: in a
  task of its own, if the module's switches are on and the conversation
  came from Telegram, it edits the card to the outcome and takes the buttons
  off, and for `changed` (the values moved under the preview) it sends the
  new card too. This is the only thing that edits a card to its outcome. A
  card whose place was not kept, or was kept for another bot, is left as it
  is. What Telegram refuses is logged by its kind and nothing else.
  """

  alias PhoenixKitAgent.{Config, Confirmations, Conversations}
  alias PhoenixKitAgent.Schemas.{Conversation, Message}
  alias PhoenixKitAgent.Telegram.{Bridge, Card, Client}

  require Logger

  @replies PhoenixKitAgent.Telegram.ReplySupervisor

  @doc """
  Sends the card message `card` of the conversation to the chat `ref`, and
  keeps where it went. `:ok`, or `:error` when Telegram would not take it
  (the change then waits on the site). Run it in the user's language.
  """
  @spec deliver(String.t(), Bridge.ref(), String.t(), map()) :: :ok | :error
  def deliver(
        connection_uuid,
        {:telegram_link, _user, _connection, chat_id} = ref,
        conversation_uuid,
        card
      ) do
    mode =
      case Confirmations.outcome(conversation_uuid, card.confirmation_uuid) do
        nil -> :open
        outcome -> {:outcome, outcome}
      end

    %{text: text, markup: markup} = Card.build(ref, card.confirmation_uuid, mode)

    case Bridge.send_card(connection_uuid, chat_id, text, markup) do
      {:ok, message_id} ->
        if is_integer(message_id) do
          Conversations.put_telegram_card(
            conversation_uuid,
            card.confirmation_uuid,
            connection_uuid,
            chat_id,
            message_id
          )
        end

        :ok

      :error ->
        :error
    end
  end

  @doc false
  # Called by `Conversations` once a notice is committed.
  @spec notice_added(Message.t()) :: :ok
  def notice_added(%Message{tool_outcome: outcome} = message) do
    if outcome in Confirmations.outcomes() and Config.writes?() and Config.telegram_enabled?(),
      do: start(message)

    :ok
  end

  # No supervisor (the host does not run the bridge) is no failure of the
  # notice that was committed.
  defp start(message) do
    _ =
      Task.Supervisor.start_child(@replies, fn -> Bridge.safely(fn -> settled(message) end) end)

    :ok
  catch
    :exit, _reason -> :ok
  end

  defp settled(message) do
    with %Conversation{} = conversation <- conversation(message.conversation_uuid),
         "telegram" <- conversation.metadata["source"],
         connection when is_binary(connection) <- Client.impl().connection_uuid(),
         {^connection, chat_id, message_id} <-
           Conversations.telegram_card(conversation, message.confirmation_uuid) do
      ref = {:telegram_link, conversation.user_uuid, connection, chat_id}

      Bridge.in_locale(conversation.user_uuid, fn _locale ->
        edit(connection, ref, message, message_id)
        if message.tool_outcome == "changed", do: replacement(connection, ref, message)
      end)
    end

    :ok
  end

  defp edit(connection, {:telegram_link, _, _, chat_id} = ref, message, message_id) do
    %{text: text} = Card.build(ref, message.confirmation_uuid, {:outcome, message.tool_outcome})
    edit_card(connection, chat_id, message_id, text, nil)
  end

  defp replacement(connection, ref, message) do
    case Confirmations.replacement_card(message.conversation_uuid, message.confirmation_uuid) do
      %Message{} = card -> deliver(connection, ref, message.conversation_uuid, card)
      nil -> :ok
    end
  end

  @doc false
  # Edits the message to `text` (`markup` `nil`: no buttons). A message that
  # is already so (Telegram's "not modified") is no failure.
  @spec edit_card(String.t(), integer(), integer(), String.t(), map() | nil) :: :ok | :error
  def edit_card(connection, chat_id, message_id, text, markup) do
    case Client.impl().edit_message(connection, chat_id, message_id, text, markup) do
      {:ok, _} ->
        :ok

      {:error, reason} when is_binary(reason) ->
        if reason =~ "not modified", do: :ok, else: failed(:refused)

      {:error, reason} ->
        failed(if(reason == :unreachable, do: :unreachable, else: :refused))
    end
  end

  defp failed(kind) do
    Logger.warning("[PhoenixKitAgent] telegram card edit failed: #{kind}")
    :error
  end

  defp conversation(uuid), do: PhoenixKit.RepoHelper.repo().get(Conversation, uuid)
end
