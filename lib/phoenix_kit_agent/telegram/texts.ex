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
  @spec static(:help | :unlinked | :bot_busy | :wait | :text_only | :forwarded | :new_started) ::
          String.t()
  def static(:help),
    do:
      gettext(
        "Write to me in plain text and I will answer using your data on the site. /new starts a new conversation. I read text only, and I cannot change anything here: for a change I will point you to the site."
      )

  def static(:unlinked),
    do: gettext("This chat is not linked to an account. Link it on the site: Profile → Telegram")

  def static(:bot_busy), do: gettext("The bot is busy right now. Write again in a minute.")
  def static(:wait), do: gettext("Wait a little: I am still answering your previous message.")
  def static(:text_only), do: gettext("I understand text only for now.")

  def static(:forwarded),
    do: gettext("I do not read forwarded messages. Put it in your own words.")

  def static(:new_started), do: gettext("Started a new conversation.")

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
