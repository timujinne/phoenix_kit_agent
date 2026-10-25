defmodule PhoenixKitAgent.Web.ToolAvailability do
  @moduledoc """
  The card "What the assistant can use now" of the admin pages: the admin
  tools of every module, the ones that read and the ones that write, as core
  shows them for a scope (`PhoenixKit.API.Executor.tool_availability/1`) —
  available, or closed and why. The assistant sees exactly the available ones
  (`PhoenixKitAgent.Turns.Tools`: core's `visible_for/3` with `allow: :all`,
  no filter of the module's own), and a write still waits for the user's
  confirmation.

  Settings → AI Agent shows it for the scope of the viewer's session, the role
  it acts as (`PhoenixKitAgent.Web.Access.session_scope/1`); Users → Configure
  for the chosen user by every role they hold (`Scope.for_user/2` with
  `narrow: false`), which the role of a session can narrow. Core's list names
  every admin tool whatever the scope, so only the pages gated by
  `agent.manage` show it. It is read when the page or the form opens, not on
  every render.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitAgent.Gettext

  import PhoenixKitWeb.Components.Core.Accordion, only: [accordion: 1]
  import PhoenixKitWeb.Components.Core.Badge, only: [status_badge: 1]
  import PhoenixKitWeb.Components.Core.EmptyState, only: [empty_state: 1]
  import PhoenixKitWeb.Components.Core.FormSection, only: [form_section: 1]

  alias PhoenixKit.API.Executor
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Users.Auth.Scope

  @typedoc "One module and its admin tools, as `Executor.tool_availability/1` shows them."
  @type module_tools :: %{
          key: String.t() | nil,
          name: String.t(),
          tools: [Executor.availability()]
        }

  @doc """
  The admin tools for `scope`, by module, in core's order (module name, then
  tool name). No scope (a session that can no longer act): nothing — never
  the list by the settings alone, which would show more than such a session
  may call.
  """
  # Any term: the clauses match a %Scope{} and treat anything else as no scope. A spec
  # of Scope.t() made Dialyzer refuse a scope built by Scope.for_user/2, whose MapSet
  # of permissions it sees through (call_without_opaque).
  @spec for_scope(term()) :: [module_tools()]
  def for_scope(%Scope{} = scope) do
    tools = Executor.tool_availability(scope)
    by_module = Enum.group_by(tools, & &1.module_key)

    tools
    |> Enum.uniq_by(& &1.module_key)
    |> Enum.map(fn tool ->
      %{
        key: tool.module_key,
        name: module_label(tool.module_key, tool.module_name),
        tools: Map.fetch!(by_module, tool.module_key)
      }
    end)
  end

  def for_scope(_none), do: []

  @doc false
  # A module's name, translated as Settings -> API does it: by the gettext backend the
  # module declares in its permission_metadata/0 (the one the permissions matrix uses),
  # then by core's own catalogue.
  @spec module_label(String.t() | nil, String.t()) :: String.t()
  def module_label(key, name) do
    with {backend, domain} <- Map.get(ModuleRegistry.permission_gettext(), key),
         translated when translated != name <- Gettext.dgettext(backend, domain, name) do
      translated
    else
      _ -> Gettext.gettext(PhoenixKitWeb.Gettext, name)
    end
  end

  @doc """
  The card. `subject` says whose rights the list is by: `:session` (the
  viewer's session, its role) or `:user` (the chosen user's roles).
  """
  attr(:id, :string, required: true)
  attr(:modules, :list, required: true)
  attr(:subject, :atom, required: true, values: [:session, :user])

  def assistant_tools(assigns) do
    ~H"""
    <.form_section id={@id} title={gettext("What the assistant can use now")}>
      <:subtitle>
        <span id={"#{@id}-note"}>{note(@subject)}</span>
      </:subtitle>
      <div :if={@modules == []} id={"#{@id}-none"}>
        <.empty_state
          icon="hero-wrench-screwdriver"
          title={gettext("No module offers the assistant tools.")}
          class="py-6"
        />
      </div>
      <div :if={@modules != []} class="flex flex-col gap-2">
        <.accordion :for={mod <- @modules} id={"#{@id}-module-#{mod.key}"} class="min-w-0">
          <:title>
            <span class="flex min-w-0 flex-wrap items-baseline gap-x-3 gap-y-1">
              <span>{mod.name}</span>
              <span
                :for={{kind, available, total} <- counts(mod.tools)}
                data-kind={kind}
                class="text-xs font-normal text-base-content/70"
              >
                {count_text(kind, available, total)}
              </span>
            </span>
          </:title>
          <:content>
            <ul class="divide-y divide-base-200">
              <li
                :for={tool <- mod.tools}
                id={"#{@id}-tool-#{tool.name}"}
                data-tool={tool.name}
                data-status={if tool.status == :available, do: "available", else: "closed"}
                class="min-w-0 space-y-1 py-2"
              >
                <div class="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1">
                  <code class="min-w-0 break-all font-mono text-xs">{tool.name}</code>
                  <span
                    :if={tool.kind == :write}
                    class="badge badge-sm badge-warning h-auto"
                  >
                    {gettext("Writes")}
                  </span>
                  <span :if={tool.kind == :read} class="badge badge-sm badge-ghost h-auto">
                    {gettext("Read only")}
                  </span>
                  <.status_badge
                    :if={tool.status == :available}
                    status="active"
                    label={gettext("Available")}
                  />
                  <.status_badge
                    :if={tool.status != :available}
                    status="inactive"
                    label={gettext("Closed")}
                  />
                </div>
                <p :if={tool.permission} class="break-all text-xs text-base-content/70">
                  {gettext("Permission: %{permission}", permission: tool.permission)}
                </p>
                <ul :if={closed_reasons(tool) != []} class="text-sm text-base-content/80">
                  <li :for={reason <- closed_reasons(tool)} data-reason={reason}>
                    {reason_text(reason, @subject)}
                  </li>
                </ul>
              </li>
            </ul>
          </:content>
        </.accordion>
      </div>
    </.form_section>
    """
  end

  defp note(:session),
    do:
      gettext(
        "The tools of the site's modules as the assistant finds them for your session's role: available, or closed and why. A write still waits for the user's confirmation."
      )

  defp note(:user),
    do:
      gettext(
        "The tools of the site's modules as this user's assistant finds them, by the user's roles; the role of a session can narrow it. A write still waits for the user's confirmation."
      )

  # Per kind present: how many of the module's tools of that kind are available.
  defp counts(tools) do
    [:read, :write]
    |> Enum.map(fn kind -> {kind, Enum.filter(tools, &(&1.kind == kind))} end)
    |> Enum.reject(fn {_kind, of_kind} -> of_kind == [] end)
    |> Enum.map(fn {kind, of_kind} ->
      {kind, Enum.count(of_kind, &(&1.status == :available)), length(of_kind)}
    end)
  end

  defp count_text(:read, available, total),
    do: gettext("Reading: %{available} of %{total}", available: available, total: total)

  defp count_text(:write, available, total),
    do: gettext("Writing: %{available} of %{total}", available: available, total: total)

  defp closed_reasons(%{status: {:closed, reasons}}), do: reasons
  defp closed_reasons(%{status: :available}), do: []

  defp reason_text(:module_disabled, _subject), do: gettext("The module is switched off.")

  defp reason_text(:api_off, _subject),
    do: gettext("The module's API is off in Settings → API.")

  defp reason_text(:tool_hidden, _subject),
    do: gettext("The tool is hidden in Settings → API.")

  defp reason_text(:agent_writes_off, _subject),
    do: gettext("It writes, and “Agent may act” is off for the module in Settings → API.")

  defp reason_text(:no_permission, :session),
    do: gettext("Your session's role does not grant its permission.")

  defp reason_text(:no_permission, :user),
    do: gettext("The user's roles do not grant its permission.")
end
