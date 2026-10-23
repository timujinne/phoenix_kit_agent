defmodule PhoenixKitAgent.Web.Dock.Components do
  @moduledoc """
  The pieces of the chat panel (`PhoenixKitAgent.Web.Dock`): one message of
  the feed and a file waiting for a message.

  A message comes as `PhoenixKitAgent.Conversations` hands it to a client: a
  tool call has only its summary (`tool_summary`: the tool's name, the
  outcome, how many it found, whether it was cut), never what the tool
  returned, and the panel shows no more than that. A model answer is
  markdown, shown by `PhoenixKitAgent.Web.Markdown` (no outside pictures, no
  raw HTML, links with their domain).
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitAgent.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.TimeZone
  alias PhoenixKitAgent.Schemas.{Attachment, Message}
  alias PhoenixKitAgent.Web.Dock.Texts
  alias PhoenixKitAgent.Web.Markdown

  @doc "One message of the feed."
  attr(:id, :string, required: true)
  attr(:message, Message, required: true)

  def feed_message(%{message: %Message{role: "user"}} = assigns) do
    ~H"""
    <div id={@id} data-role="user" class="flex justify-end">
      <div class="max-w-[85%] rounded-box bg-primary text-primary-content px-3 py-2 whitespace-pre-wrap break-words text-sm">
        {@message.content}
      </div>
    </div>
    """
  end

  def feed_message(%{message: %Message{role: "assistant"}} = assigns) do
    ~H"""
    <div
      id={@id}
      data-role="assistant"
      class={[
        "text-sm break-words space-y-2 [&_a]:break-all",
        blank?(@message.content) && "hidden"
      ]}
    >
      {Markdown.to_html(@message.content)}
    </div>
    """
  end

  def feed_message(%{message: %Message{role: "tool"}} = assigns) do
    assigns = assign(assigns, :summary, assigns.message.tool_summary || %{})

    ~H"""
    <details id={@id} data-role="tool" class="group rounded-box border border-base-300 text-xs">
      <summary class="flex cursor-pointer items-center gap-2 px-3 py-1.5 opacity-80 hover:opacity-100 transition-opacity">
        <.icon name={outcome_icon(@summary[:outcome])} class="w-3.5 h-3.5 shrink-0" />
        <span class="font-mono truncate">{@summary[:name] || gettext("a tool")}</span>
        <span class="ml-auto shrink-0">{found(@summary)}</span>
      </summary>
      <div class="px-3 pb-2 opacity-70">
        {outcome_text(@summary[:outcome])}
        <span :if={@summary[:truncated]}>{gettext("The result was cut to fit.")}</span>
      </div>
    </details>
    """
  end

  def feed_message(%{message: %Message{role: "notice"}} = assigns) do
    ~H"""
    <div id={@id} data-role="notice" class="alert alert-soft alert-warning py-2 text-xs">
      <.icon name="hero-information-circle" class="w-4 h-4" />
      <span>{Texts.notice(@message.error) || @message.content}</span>
    </div>
    """
  end

  def feed_message(assigns) do
    ~H"""
    <div id={@id} class="hidden"></div>
    """
  end

  @doc """
  When a chat was last written to, for the list of chats: how long ago in the
  user's language, and the moment itself (site time zone) as the tooltip.

  Rendered by the server only. Core's `time_ago` would do the same job, but
  its `TimeAgo` hook rewrites the text in English in the browser, and its
  tooltip is an English date.
  """
  attr(:id, :string, required: true)
  attr(:datetime, DateTime, default: nil)

  def chat_time(%{datetime: nil} = assigns) do
    ~H"""
    <span id={@id} class="text-xs">—</span>
    """
  end

  def chat_time(assigns) do
    ~H"""
    <time id={@id} class="text-xs" datetime={DateTime.to_iso8601(@datetime)} title={site_moment(@datetime)}>
      {ago(DateTime.diff(DateTime.utc_now(), @datetime))}
    </time>
    """
  end

  defp ago(seconds) when seconds < 60, do: gettext("just now")

  defp ago(seconds) when seconds < 3_600,
    do: ngettext("%{count} minute ago", "%{count} minutes ago", div(seconds, 60))

  defp ago(seconds) when seconds < 86_400,
    do: ngettext("%{count} hour ago", "%{count} hours ago", div(seconds, 3_600))

  defp ago(seconds), do: ngettext("%{count} day ago", "%{count} days ago", div(seconds, 86_400))

  # Digits only, so it reads the same in every language.
  defp site_moment(datetime) do
    datetime
    |> TimeZone.shift(Settings.get_setting("time_zone", "0"))
    |> Calendar.strftime("%Y-%m-%d %H:%M")
  end

  @doc "A file of the chat that waits for a message."
  attr(:attachment, Attachment, required: true)

  def attachment_chip(assigns) do
    ~H"""
    <li
      id={"pk-agent-att-#{@attachment.uuid}"}
      data-status={@attachment.status}
      class={[
        "flex items-center gap-2 rounded-box border px-2 py-1 text-xs",
        @attachment.status == "failed" && "border-error/50 bg-error/5",
        @attachment.status != "failed" && "border-base-300"
      ]}
    >
      <.icon name={kind_icon(@attachment.kind)} class="w-4 h-4 shrink-0 opacity-70" />
      <span class="truncate max-w-[12rem]" title={@attachment.filename}>{@attachment.filename}</span>
      <span :if={@attachment.status == "pending"} class="loading loading-spinner loading-xs"></span>
      <span :if={@attachment.status == "failed"} class="text-error">
        {Texts.attachment_error(@attachment.error)}
      </span>
      <button
        type="button"
        id={"pk-agent-discard-#{@attachment.uuid}"}
        phx-click="discard_attachment"
        phx-value-uuid={@attachment.uuid}
        class="btn btn-ghost btn-xs btn-circle ml-auto"
        aria-label={gettext("Remove the file")}
        title={gettext("Remove the file")}
      >
        <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
      </button>
    </li>
    """
  end

  defp found(%{outcome: "ok", count: count}) when is_integer(count),
    do: ngettext("1 found", "%{count} found", count)

  defp found(%{outcome: "ok"}), do: gettext("done")
  defp found(%{outcome: outcome}), do: outcome_text(outcome)
  defp found(_summary), do: ""

  defp outcome_text("ok"), do: gettext("The tool answered.")
  defp outcome_text("denied"), do: gettext("Not allowed: the tool was not run.")
  defp outcome_text("error"), do: gettext("The tool failed.")
  defp outcome_text(_other), do: gettext("No result.")

  defp outcome_icon("ok"), do: "hero-magnifying-glass"
  defp outcome_icon("denied"), do: "hero-no-symbol"
  defp outcome_icon(_other), do: "hero-exclamation-triangle"

  defp kind_icon("image"), do: "hero-photo"
  defp kind_icon("sheet"), do: "hero-table-cells"
  defp kind_icon(_pdf_or_text), do: "hero-document-text"

  defp blank?(text), do: not is_binary(text) or String.trim(text) == ""
end
