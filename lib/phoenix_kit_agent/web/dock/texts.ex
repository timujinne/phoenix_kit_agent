defmodule PhoenixKitAgent.Web.Dock.Texts do
  @moduledoc """
  What the chat panel (`PhoenixKitAgent.Web.Dock`) tells a person instead of a
  code: the refusals of `PhoenixKitAgent.Conversations`,
  `PhoenixKitAgent.Turns` and `PhoenixKitAgent.Attachments`, the codes of a
  failed attachment (`PhoenixKitAgent.Attachments.Processor`), the notices of
  a turn (stored in English, shown by their code), the states and refusals of
  a confirmation card (`PhoenixKitAgent.Confirmations`) and the upload errors
  of LiveView. A code this module does not know gets a general text, never
  the code itself.
  """

  use Gettext, backend: PhoenixKitAgent.Gettext

  @doc "The text for a refusal of a call the panel made."
  @spec refusal(term()) :: String.t()
  def refusal(:impersonated), do: gettext("The assistant is not available in a borrowed session.")

  def refusal(reason) when reason in [:session_gone, :mismatch, :inactive],
    do: gettext("Your session has ended. Sign in again to use the assistant.")

  def refusal(:unconfirmed),
    do: gettext("Confirm your email address to use the assistant.")

  def refusal(:referral_required),
    do: gettext("Your account still needs a referral code to use the assistant.")

  def refusal(:forbidden), do: gettext("You may not use the assistant now.")
  def refusal(:not_found), do: gettext("This chat is not there any more.")
  def refusal(:invalid_cursor), do: gettext("The list could not be read. Open it again.")
  def refusal(:empty_message), do: gettext("Write a message first.")

  def refusal(:message_too_long),
    do: gettext("The message is too long. Shorten it or send it as a file.")

  def refusal(:ai_disabled), do: gettext("The AI module is switched off.")

  def refusal(:no_endpoint),
    do:
      gettext(
        "No model is chosen for the assistant yet. An administrator chooses one in Settings → AI Agent, or one for you in AI Agent → Users."
      )

  def refusal(:invalid_attachments),
    do: gettext("A file is not ready or not in this chat. Remove it and try again.")

  def refusal(:too_many_attachments),
    do: gettext("Too many files for one message. Remove some of them.")

  def refusal(:conversation_busy),
    do: gettext("The assistant is still answering in this chat. Wait for it or press Stop.")

  def refusal(:turn_in_flight),
    do: gettext("The assistant is answering in another chat. Wait for it to finish.")

  def refusal(:click_in_flight),
    do: gettext("A change is being confirmed right now. Send your message again in a moment.")

  def refusal({:limit_reached, :daily_cost}),
    do: gettext("You have reached your daily spending limit for the assistant.")

  def refusal({:limit_reached, :monthly_cost}),
    do: gettext("You have reached your monthly spending limit for the assistant.")

  def refusal({:limit_reached, :daily_turns}),
    do: gettext("You have used all your assistant turns for today.")

  def refusal(reason) when reason in [:task_blocked, :task_limit_exceeded],
    do: notice(Atom.to_string(reason))

  def refusal({:task_blocked, _group}), do: refusal(:task_blocked)

  def refusal({:task_limit_exceeded, _scope, _unit, _period}), do: refusal(:task_limit_exceeded)

  def refusal(:not_running), do: gettext("Nothing is running in this chat.")

  def refusal(:turn_lost),
    do:
      gettext(
        "This answer is no longer running here. The chat will be free again in a few minutes."
      )

  def refusal(:stop_unanswered),
    do:
      gettext(
        "The answer has not stopped yet. Press Stop again, or wait: if it is no longer running, the chat will be free again in a few minutes."
      )

  def refusal(:files_pending), do: gettext("Wait until the files are read.")

  def refusal(:rate_limited), do: gettext("Too many requests at once; try again in a minute.")

  def refusal(reason) when reason in [:file_unreadable, :empty_file],
    do: gettext("The file could not be read, or it is empty.")

  def refusal(:too_large), do: gettext("The file is too large.")

  def refusal(:unsupported_type),
    do:
      gettext(
        "This kind of file is not supported. Send a picture, a PDF, an xlsx or csv sheet, or a txt or md text."
      )

  def refusal(:unsupported_encoding),
    do: gettext("The text is not in UTF-8. Save the file as UTF-8 and add it again.")

  def refusal(:no_vision_model),
    do: gettext("Pictures cannot be read: no model that sees images is set up.")

  def refusal(:too_many),
    do: gettext("Too many files are waiting. Send or remove some of them first.")

  def refusal(:storage_unavailable),
    do: gettext("The file could not be kept. Try again later.")

  def refusal(:already_sent), do: gettext("The file was sent already.")

  def refusal(_other),
    do: gettext("Something went wrong. Try again in a moment.")

  @doc "The text for the `error` code of a failed attachment."
  @spec attachment_error(String.t() | nil) :: String.t()
  def attachment_error("unreadable"), do: gettext("The file could not be read.")
  def attachment_error("too_large"), do: gettext("The file is too large to read.")

  def attachment_error(code) when code in ["pdf_tools_missing", "image_tools_missing"],
    do: gettext("This kind of file cannot be read on this server.")

  def attachment_error("no_vision_model"),
    do: gettext("No model that sees images is set up to read it.")

  def attachment_error("ai_disabled"),
    do: gettext("The AI module is switched off, so it was not read.")

  def attachment_error("session_gone"),
    do: gettext("Your session ended before it was read. Sign in and add it again.")

  def attachment_error("forbidden"),
    do: gettext("You may not use the assistant now, so it was not read.")

  def attachment_error("limit_reached"),
    do: gettext("Your assistant limit is reached, so it was not read.")

  def attachment_error("budget_exceeded"),
    do: gettext("The AI budget is used up, so it was not read.")

  def attachment_error("task_blocked"),
    do: gettext("The AI assistant is blocked for you, so it was not read.")

  def attachment_error("task_limit_exceeded"),
    do: gettext("The AI assistant has reached its limit for now, so it was not read.")

  def attachment_error(code)
      when code in ["model_unfit", "model_unverified", "no_provider_for_params"],
      do: gettext("The model that reads pictures cannot be used for it now, so it was not read.")

  def attachment_error("model_error"), do: gettext("The model could not read it.")
  def attachment_error("timeout"), do: gettext("Reading it took too long.")

  def attachment_error("unavailable"),
    do: gettext("The server was too busy to read it. Add it again.")

  def attachment_error(_crashed_or_unknown), do: gettext("It could not be read.")

  @doc """
  The text of a notice in the feed by its `error` code, in the panel's
  language, or `nil` for a code whose stored text says more than the code (a
  model error, which also tells whether the files were taken off the
  message): that one is shown as it was written.
  """
  @spec notice(String.t() | nil) :: String.t() | nil
  def notice(code) when code in ["interrupted", "lock_lost"],
    do: gettext("The answer was interrupted. Try again.")

  def notice("deadline"),
    do:
      gettext(
        "The answer took longer than allowed and was stopped. Try again, or ask for less at once."
      )

  def notice("empty_answer"), do: gettext("The model gave no answer. Try again.")

  def notice("max_tool_rounds"),
    do: gettext("The assistant used all its tool rounds for this turn.")

  def notice("daily_cost_limit"),
    do:
      gettext(
        "You have reached your daily spending limit for the assistant. It resets at midnight."
      )

  def notice("monthly_cost_limit"),
    do:
      gettext(
        "You have reached your monthly spending limit for the assistant. It resets on the first day of next month."
      )

  def notice("daily_turn_limit"),
    do: gettext("You have used all your assistant turns for today. They reset at midnight.")

  def notice(code)
      when code in ["session_gone", "mismatch", "inactive", "unconfirmed", "referral_required"],
      do: gettext("Your session has ended, so the assistant stopped.")

  def notice("forbidden"), do: gettext("The assistant is no longer available to you.")
  def notice("ai_disabled"), do: gettext("The AI module is switched off.")
  def notice("rate_limited"), do: gettext("Too many requests at once; try again in a minute.")

  def notice("insufficient_credits"),
    do:
      gettext(
        "The AI account behind the assistant has run out of credit. An administrator has to top it up or choose another model."
      )

  def notice("not_found"), do: gettext("This chat is gone.")
  def notice("budget_exceeded"), do: gettext("The AI budget is used up.")

  def notice("task_blocked"),
    do: gettext("The AI assistant is blocked for you. An administrator can lift the block.")

  def notice("task_limit_exceeded"),
    do: gettext("The AI assistant has reached its limit for now. Try again later.")

  def notice("model_unfit"),
    do:
      gettext(
        "The model chosen for the assistant cannot do what it needs. An administrator chooses another one."
      )

  def notice("model_unverified"),
    do:
      gettext(
        "It is not known whether the model chosen for the assistant can do what it needs. An administrator marks what the model can do on its AI endpoint, or chooses another one."
      )

  def notice("no_provider_for_params"),
    do:
      gettext(
        "No provider of the model takes the request as its AI endpoint is set up. An administrator checks the endpoint's settings."
      )

  def notice("pictures_not_seen"),
    do:
      gettext(
        "The model does not take pictures now, so they were not sent. Remove them and attach them again to have them described, or choose a model that sees."
      )

  def notice(_code_with_its_own_text), do: nil

  @doc "The heading of a confirmation card in its state."
  @spec card_title(String.t()) :: String.t()
  def card_title("waiting"), do: gettext("The assistant proposes a change")
  def card_title("confirmed"), do: gettext("The change was made")
  def card_title("rejected"), do: gettext("The change was cancelled")
  def card_title("expired"), do: gettext("The confirmation ran out; nothing was changed")
  def card_title("changed"), do: gettext("The data changed — check it again below")
  def card_title("failed"), do: gettext("The change failed")
  def card_title(_unavailable), do: gettext("This change can no longer be confirmed here")

  @doc "The line of the notice that settles a confirmation card, by its outcome."
  @spec card_outcome(String.t()) :: String.t()
  def card_outcome("confirmed"), do: gettext("Done:")
  def card_outcome("rejected"), do: gettext("Cancelled:")
  def card_outcome("expired"), do: gettext("Ran out:")
  def card_outcome("changed"), do: gettext("The data changed:")
  def card_outcome(_failed), do: gettext("Failed:")

  @doc """
  The text for a click on a confirmation card that did nothing (the card keeps
  waiting): the refusals of `PhoenixKitAgent.Confirmations`, `{:refused,
  code}` with the executor's code among them.
  """
  @spec card_refusal(term()) :: String.t()
  def card_refusal(:turn_running),
    do: gettext("The assistant is answering. Try again when it has finished.")

  def card_refusal(:click_running),
    do: gettext("A change is being confirmed right now. Try again in a moment.")

  def card_refusal(:not_stored),
    do:
      gettext(
        "What became of this change could not be saved in the chat. Open the chat again to see it."
      )

  def card_refusal(:not_waiting), do: gettext("This change no longer waits for you.")

  def card_refusal(:not_expired),
    do: gettext("This change can be asked for again only once its confirmation ran out.")

  def card_refusal(:no_arguments),
    do:
      gettext(
        "This change cannot be confirmed: the assistant's call is not in the chat any more."
      )

  def card_refusal({:refused, :module_write_disabled}),
    do: gettext("The assistant may not make changes in this part of the site now.")

  def card_refusal({:refused, :forbidden}), do: gettext("You may not make this change now.")

  def card_refusal({:refused, :unauthorized}), do: refusal(:session_gone)
  def card_refusal({:refused, :rate_limited}), do: refusal(:rate_limited)

  def card_refusal({:refused, :validation_failed}),
    do: gettext("The change does not fit what the tool takes any more.")

  def card_refusal({:refused, _code}),
    do: gettext("The change cannot be made now. Try again later, or cancel it.")

  def card_refusal(reason), do: refusal(reason)

  @doc "The text for an error of a LiveView upload entry."
  @spec upload_error(atom()) :: String.t()
  def upload_error(:too_large), do: gettext("The file is too large.")
  def upload_error(:too_many_files), do: gettext("Too many files at once.")
  def upload_error(:not_accepted), do: refusal(:unsupported_type)
  def upload_error(_other), do: gettext("The file could not be uploaded.")
end
