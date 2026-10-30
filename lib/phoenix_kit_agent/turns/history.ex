defmodule PhoenixKitAgent.Turns.History do
  @moduledoc """
  What a turn shows the model of the chat so far (spec §6.6): the `user`
  messages and the final `assistant` answers of earlier turns, newest kept
  first, up to `agent_history_chars`. Tool calls and tool results of earlier
  turns are left out — after a loss of rights the model must not see old
  data — and so are notices, but for one kind: the outcome of a confirmation
  card (`PhoenixKitAgent.Confirmations`) goes in as a `user` message with the
  module's own fixed phrase in the user's language — "[confirmation] done:
  <the tool's name>", "cancelled", "expired", "the data changed", "failed" —
  never anything the tool returned, and never a text a person wrote. So does a
  card with no such notice yet, where it stands in the chat: "[confirmation]
  waiting: <the tool's name>", so the model knows that its proposal still
  waits. Before it reads the chat, a turn gives the cards core no longer holds
  their notice (`Confirmations.settle_lapsed_in_turn/2`), so a card that ran
  out, or whose click was lost, does not read as waiting.

  The extracted text of a message's attachments (the user's own files) is
  part of that message; the attachments of one message share `limit` between
  them, so that five files cannot by themselves outgrow the window and push
  the earlier conversation out of it. A text that holds less than its file
  ends with a line that says so (`PhoenixKitAgent.Attachments.Extract`), and
  so does one cut to its share here: the model is not left to take part of
  the data for all of it.
  """

  use Gettext, backend: PhoenixKitAgent.Gettext

  alias PhoenixKit.API.MCP.Names
  alias PhoenixKitAgent.{Attachments, Confirmations}
  alias PhoenixKitAgent.Attachments.{Bounds, Extract}
  alias PhoenixKitAgent.Schemas.{Attachment, Message}

  @typedoc "A message as the model reads it."
  @type entry :: %{role: String.t(), content: String.t()}

  @doc """
  The model messages for a turn: the earlier `messages` of the chat (oldest
  first: `user` and `assistant` messages, the notices of confirmation cards
  and the cards, `tool` messages `needs_confirmation`) and then `current`, the
  new user message, which is always kept. The earlier ones are kept from the
  newest back while the characters of all kept messages stay within `limit`;
  the first that does not fit ends the window. `attachments` are the chat's
  ready attachments.
  """
  @spec build([Message.t()], [Attachment.t()], entry(), pos_integer()) :: [entry()]
  def build(messages, attachments, current, limit) do
    texts = Enum.group_by(attachments, & &1.message_uuid)
    settled = settled(messages)

    messages
    |> Enum.reject(&(card?(&1) and MapSet.member?(settled, &1.confirmation_uuid)))
    |> Enum.flat_map(&entry(&1, Map.get(texts, &1.uuid, []), limit))
    |> Enum.reverse()
    |> Enum.reduce_while({[], String.length(current.content)}, fn entry, {kept, used} ->
      used = used + String.length(entry.content)
      if used <= limit, do: {:cont, {[entry | kept], used}}, else: {:halt, {kept, used}}
    end)
    |> elem(0)
    |> Kernel.++([current])
  end

  @doc """
  The content of a user message: its text, then each attachment — the text it
  carries (cut to its share of `limit`), or, for a picture the model is shown
  as pixels, a line that names it (the pixels themselves go with the message of
  their own turn only).
  """
  @spec user_content(String.t(), [Attachment.t()], pos_integer()) :: String.t()
  def user_content(text, attachments, limit) do
    # The lines that name the files are not part of any share.
    named =
      attachments
      |> Enum.map(&(String.length(header(&1)) - String.length("[Attachment: " <> &1.filename)))
      |> Enum.sum()

    share =
      div(max(limit - named, 0), max(Enum.count(attachments, &is_binary(&1.extracted_text)), 1))

    Enum.reduce(attachments, text, fn attachment, acc ->
      acc <> attachment_block(attachment, share)
    end)
  end

  defp attachment_block(%{extracted_text: text} = attachment, share)
       when is_binary(text) do
    shown =
      cond do
        String.length(text) > share ->
          String.slice(text, 0, share) <>
            Extract.continues("the file continues: the rest of it is not shown here")

        # A text that is short of its file and does not say so itself.
        attachment.truncated and not Extract.says_continued?(text) ->
          text <> Extract.continues("the file continues: not all of it is shown")

        true ->
          text
      end

    "\n\n" <> header(attachment) <> "]\n" <> shown
  end

  defp attachment_block(attachment, _share) do
    if Attachments.pixels?(attachment),
      do: "\n\n" <> header(attachment) <> " - " <> pixels_line(attachment) <> "]",
      else: ""
  end

  # The opening of an attachment's line, without the closing bracket. A ready
  # attachment names the Storage file a tool can be given in place of it: the
  # uuid first, then the user's file name in quotes, so a name cannot pass for
  # a second reference.
  defp header(%{status: "ready", file_uuid: uuid, filename: filename}) when is_binary(uuid),
    do: "[Attachment (file_uuid: " <> uuid <> "): " <> inspect(filename)

  defp header(%{filename: filename}), do: "[Attachment: " <> filename

  defp pixels_line(%{kind: "pdf", pages: pages}) when is_integer(pages) do
    "a scanned document of #{Extract.count(pages, "page")}; its first #{min(pages, Bounds.get(:scan_pages))} " <>
      "are shown to you as pictures only along with the message it was sent with"
  end

  defp pixels_line(_picture),
    do: "a picture, shown to you only along with the message it was sent with"

  defp entry(%Message{role: "user", content: content}, attachments, limit)
       when is_binary(content),
       do: [%{role: "user", content: user_content(content, attachments, limit)}]

  defp entry(
         %Message{role: "assistant", content: content, tool_calls: calls},
         _attachments,
         _limit
       )
       when is_binary(content) and calls in [nil, []] do
    if String.trim(content) == "", do: [], else: [%{role: "assistant", content: content}]
  end

  defp entry(
         %Message{
           role: "notice",
           confirmation_uuid: uuid,
           tool_outcome: outcome,
           tool_name: tool,
           tool_result: counts
         },
         _attachments,
         _limit
       )
       when is_binary(uuid) and is_binary(tool) do
    case confirmation_phrase(outcome, Names.to_mcp(tool)) do
      nil -> []
      phrase -> [%{role: "user", content: phrase <> counts_phrase(outcome, counts)}]
    end
  end

  # A card no notice settles (`build/4` leaves out the settled ones).
  defp entry(
         %Message{
           role: "tool",
           tool_outcome: "needs_confirmation",
           confirmation_uuid: uuid,
           tool_name: tool
         },
         _attachments,
         _limit
       )
       when is_binary(uuid) and is_binary(tool),
       do: [%{role: "user", content: confirmation_phrase("waiting", Names.to_mcp(tool))}]

  defp entry(_tool_call_tool_result_or_notice, _attachments, _limit), do: []

  # What a confirmed write counted (`Confirmations` keeps the two integers of
  # the tool's `summary`, nothing else of its result).
  defp counts_phrase("confirmed", %{"ok" => ok, "failed" => failed})
       when is_integer(ok) and is_integer(failed) and ok >= 0 and failed >= 0,
       do:
         " (" <>
           gettext("%{ok} of %{total} succeeded, %{failed} failed",
             ok: ok,
             total: ok + failed,
             failed: failed
           ) <> ")"

  defp counts_phrase(_outcome, _counts), do: ""

  defp card?(%Message{role: "tool", tool_outcome: "needs_confirmation", confirmation_uuid: uuid}),
    do: is_binary(uuid)

  defp card?(_message), do: false

  # The confirmations whose outcome a notice of the chat says.
  defp settled(messages) do
    for %Message{role: "notice", confirmation_uuid: uuid, tool_outcome: outcome} <- messages,
        is_binary(uuid) and outcome in Confirmations.outcomes(),
        into: MapSet.new(),
        do: uuid
  end

  @doc """
  The phrase the model reads for the outcome of a confirmation card of the
  tool `action` (the name the model knows it by), or for a card still
  `"waiting"`, in the current Gettext locale; `nil` for anything else.
  """
  @spec confirmation_phrase(term(), String.t()) :: String.t() | nil
  def confirmation_phrase("waiting", action),
    do: gettext("[confirmation] waiting: %{action}", action: action)

  def confirmation_phrase("confirmed", action),
    do: gettext("[confirmation] done: %{action}", action: action)

  def confirmation_phrase("rejected", action),
    do: gettext("[confirmation] cancelled: %{action}", action: action)

  def confirmation_phrase("expired", action),
    do: gettext("[confirmation] expired, nothing was done: %{action}", action: action)

  def confirmation_phrase("changed", action),
    do:
      gettext("[confirmation] the data changed, a new confirmation waits: %{action}",
        action: action
      )

  def confirmation_phrase("failed", action),
    do: gettext("[confirmation] failed: %{action}", action: action)

  def confirmation_phrase(_other, _action), do: nil
end
