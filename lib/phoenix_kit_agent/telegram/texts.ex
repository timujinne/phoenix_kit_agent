defmodule PhoenixKitAgent.Telegram.Texts do
  @moduledoc """
  What the bot says in a chat instead of a code, in the language installed on
  the process (the bridge installs the user's, or the site's for a stranger).
  Plain text only: no "press Stop" and no "sign in again", which mean
  nothing in Telegram. Refusals and notices that read the same everywhere
  borrow the texts of the chat panel (`PhoenixKitAgent.Web.Dock.Texts`).
  """

  use Gettext, backend: PhoenixKitAgent.Gettext

  alias PhoenixKitAgent.Web.Dock.Texts, as: Panel

  @doc "The text of a reply that needs no turn."
  @spec static(
          :help
          | :unlinked
          | :bot_busy
          | :wait
          | :text_only
          | :forwarded
          | :new_started
          | :card_not_shown
        ) :: String.t()
  def static(:help) do
    if PhoenixKitAgent.Config.writes?(),
      do:
        gettext(
          "Write to me in plain text and I will answer using your data on the site. /new starts a new conversation. I read text only. When you ask for a change, I will show a card with its details and two buttons: confirm it or cancel it."
        ),
      else:
        gettext(
          "Write to me in plain text and I will answer using your data on the site. /new starts a new conversation. I read text only, and I cannot change anything here: for a change I will point you to the site."
        )
  end

  def static(:unlinked),
    do: gettext("This chat is not linked to an account. Link it on the site: Profile → Telegram")

  def static(:bot_busy), do: gettext("The bot is busy right now. Write again in a minute.")
  def static(:wait), do: gettext("Wait a little: I am still answering your previous message.")
  def static(:text_only), do: gettext("I understand text only for now.")

  def static(:forwarded),
    do: gettext("I do not read forwarded messages. Put it in your own words.")

  def static(:new_started), do: gettext("Started a new conversation.")

  def static(:card_not_shown),
    do: gettext("I could not show the buttons. Confirm the change on the site.")

  @doc "The toast that answers a press of a button the bot refuses."
  @spec toast(
          :unavailable
          | :processed
          | :expired
          | :foreign
          | :unknown_button
          | :unlinked
          | :busy
        ) :: String.t()
  def toast(:unavailable), do: gettext("This change is no longer available.")
  def toast(:processed), do: gettext("Already handled.")
  def toast(:expired), do: gettext("The time to confirm ran out. Ask again.")
  def toast(:foreign), do: gettext("This change cannot be confirmed here. Open the site.")
  def toast(:unknown_button), do: gettext("This button does not work any more.")
  def toast(:unlinked), do: gettext("This chat is not linked to an account.")
  def toast(:busy), do: gettext("The bot is busy right now. Press again in a minute.")

  @doc """
  The line under a card for a press that could not be carried out and left
  the buttons on it: a turn or another press is running, or a refusal.
  """
  @spec press_note(term()) :: String.t()
  def press_note(reason) when reason in [:turn_running, :click_running],
    do: gettext("⏳ The agent is answering. Press again in a moment.")

  def press_note({:refused, code}) when code in [:forbidden, "forbidden"],
    do: gettext("Not allowed: you have no right to make this change.")

  def press_note({:refused, code}) when code in [:rate_limited, "rate_limited"],
    do: gettext("Not allowed: too many requests. Try again in a minute.")

  # Core's other codes (a module closed to the assistant, a handler's refusal,
  # another origin...) are not for the chat: a neutral line.
  def press_note({:refused, _code}), do: gettext("Not allowed right now.")

  def press_note(reason), do: gettext("Not allowed: %{reason}", reason: refusal(reason))

  @doc "The text for the refusal of `Turns.start/6` (or of `Conversations`)."
  @spec refusal(term()) :: String.t()
  def refusal(reason) when reason in [:session_gone, :mismatch], do: static(:unlinked)

  def refusal(reason) when reason in [:forbidden, :inactive],
    do: gettext("You may not use the assistant in Telegram.")

  def refusal(:conversation_busy), do: static(:wait)

  def refusal(:message_too_long),
    do: gettext("That message is too long for me. Write a shorter one.")

  def refusal(:click_in_flight),
    do: gettext("A change is being confirmed on the site. Write again in a moment.")

  def refusal(reason), do: Panel.refusal(reason)

  @doc "The text for the `error` code of a notice that ended a turn."
  @spec notice(String.t()) :: String.t()
  def notice(code) when code in ["session_gone", "mismatch"], do: static(:unlinked)

  def notice(code) when code in ["inactive", "forbidden", "unconfirmed", "referral_required"],
    do: gettext("You may not use the assistant in Telegram.")

  def notice(code) do
    Panel.notice(code) || Panel.notice(nil, "The model did not answer. Try again.")
  end
end
