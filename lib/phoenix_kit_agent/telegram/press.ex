defmodule PhoenixKitAgent.Telegram.Press do
  @moduledoc """
  A press of ✅ or ❌ under a card, carried out. `PhoenixKitAgent.Telegram.Bridge`
  has decided who pressed (the private chat of a linked user, from the update
  alone), which button and which confirmation; this module does the rest, in
  the user's language and in a task of its own (never in the queue of the
  chat: a press must not wait behind a turn).

  The order:

    1. checks that write nothing (`Confirmations.precheck/2`): the card, its
       chat, the status of its row. A press that cannot go on is answered
       with a toast (`answerCallbackQuery`); a card that is gone, ran out or
       was settled elsewhere is also edited to say so, without buttons;
    2. an empty `answerCallbackQuery`, which takes the "clock" off the button;
    3. the message of the card is remembered for the confirmation, if no
       message is kept for it yet (so the edit after the outcome finds it);
    4. the click (`Confirmations.confirm_press/3` / `reject_press/3`).

  What came of the click is shown by the edit of `PhoenixKitAgent.Telegram.Cards`
  that follows the notice the click wrote, not here. Only a press that did not
  go through and left the buttons is shown here, as a line under the card
  ("the agent is answering, press again", "not allowed: …"), after the card's
  outcome is read again: a card that has its outcome by now is left to the
  edit that shows it. Nothing of the card, its arguments or the user is
  logged.
  """

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitAgent.{Confirmations, Conversations}
  alias PhoenixKitAgent.Telegram.{Bridge, Card, Cards, Client, Texts}

  @type press :: %{
          callback_id: String.t(),
          message_id: integer(),
          action: :confirm | :reject,
          confirmation_uuid: String.t()
        }

  @doc "Carries out `press` for the chat `ref` of the bot `connection_uuid`."
  @spec run(String.t(), Bridge.ref(), press()) :: :ok
  def run(connection_uuid, {:telegram_link, user_uuid, _connection, _chat} = ref, press) do
    Bridge.safely(fn ->
      Bridge.in_locale(user_uuid, fn locale ->
        ref
        |> Confirmations.precheck(press.confirmation_uuid)
        |> go(connection_uuid, ref, press, locale)
      end)
    end)
  end

  # ── before the click ──────────────────────────────────────────────

  defp go({state, press_card}, connection, ref, press, locale)
       when state in [:open, :forbidden] do
    answer(connection, press.callback_id, nil)
    remember(connection, ref, press, press_card)
    click(connection, ref, press, locale)
  end

  defp go({:settled, _press_card, outcome}, connection, ref, press, _locale),
    do: refuse(connection, ref, press, :processed, {:outcome, outcome})

  defp go({:processed, _press_card}, connection, ref, press, _locale),
    do: refuse(connection, ref, press, :processed, :processed)

  defp go({:expired, _press_card}, connection, ref, press, _locale),
    do: refuse(connection, ref, press, :expired, :expired)

  defp go({:foreign, _press_card}, connection, _ref, press, _locale),
    do: answer(connection, press.callback_id, Texts.toast(:foreign))

  defp go({:error, :unavailable}, connection, ref, press, _locale),
    do: refuse(connection, ref, press, :unavailable, :unavailable)

  defp go({:error, :session_gone}, connection, _ref, press, _locale),
    do: answer(connection, press.callback_id, Texts.toast(:unlinked))

  defp go({:error, reason}, connection, _ref, press, _locale),
    do: answer(connection, press.callback_id, Texts.refusal(reason))

  # A toast, and the card's message edited to say why, without buttons.
  defp refuse(connection, {:telegram_link, _, _, chat_id} = ref, press, toast, mode) do
    answer(connection, press.callback_id, Texts.toast(toast))
    %{text: text} = Card.build(ref, press.confirmation_uuid, mode)
    Cards.edit_card(connection, chat_id, press.message_id, text, nil)
    :ok
  end

  defp remember(connection, {:telegram_link, _, _, chat_id}, press, %{conversation: conversation}) do
    Conversations.put_telegram_card(
      conversation.uuid,
      press.confirmation_uuid,
      connection,
      chat_id,
      press.message_id,
      keep: true
    )
  end

  # ── the click ─────────────────────────────────────────────────────

  defp click(connection, ref, press, locale) do
    options = [request_context: [language: locale, base_url: Routes.base_url()]]

    result =
      case press.action do
        :confirm -> Confirmations.confirm_press(ref, press.confirmation_uuid, options)
        :reject -> Confirmations.reject_press(ref, press.confirmation_uuid, options)
      end

    shown(connection, ref, press, result)
  end

  # The outcome is for the edit that follows its notice. A press that did
  # not go through and left the buttons is a line under the card.
  defp shown(_connection, _ref, _press, {:ok, _outcome}), do: :ok
  defp shown(_connection, _ref, _press, {:error, :not_waiting}), do: :ok

  defp shown(connection, ref, press, {:error, :unavailable}),
    do: edit_note(connection, ref, press, :unavailable)

  # The card says by itself that the right is gone, and keeps ❌ only.
  defp shown(connection, ref, press, {:error, {:refused, code}})
       when code in [:forbidden, "forbidden"],
       do: edit_note(connection, ref, press, :open)

  defp shown(connection, ref, press, {:error, reason}),
    do: edit_note(connection, ref, press, {:note, Texts.press_note(reason)})

  defp edit_note(connection, {:telegram_link, _, _, chat_id} = ref, press, :unavailable) do
    %{text: text} = Card.build(ref, press.confirmation_uuid, :unavailable)
    Cards.edit_card(connection, chat_id, press.message_id, text, nil)
    :ok
  end

  defp edit_note(connection, {:telegram_link, _, _, chat_id} = ref, press, mode) do
    # Read again right before the edit: a card that has its outcome by now is
    # the edit of that outcome's.
    # Only a card that still waits gets the line; one that was handled,
    # settled or ran out in the meantime is left to the edit of its outcome.
    case Confirmations.precheck(ref, press.confirmation_uuid) do
      {state, _press_card} when state in [:open, :forbidden] ->
        %{text: text, markup: markup} = Card.build(ref, press.confirmation_uuid, mode)
        Cards.edit_card(connection, chat_id, press.message_id, text, markup)
        :ok

      _handled_or_gone ->
        :ok
    end
  end

  defp answer(connection, callback_id, text) do
    _ = Client.impl().answer_callback(connection, callback_id, text)
    :ok
  end
end
