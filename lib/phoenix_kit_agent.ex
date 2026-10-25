defmodule PhoenixKitAgent do
  @moduledoc """
  AI agent module for PhoenixKit.

  A personal assistant inside a PhoenixKit application: per-user chats kept
  in the database, files attached to messages, a managed system prompt, and a
  model-and-tools loop over the PhoenixKit API registry. Model calls, endpoints,
  credentials, budget and the request journal come from `phoenix_kit_ai`.

  ## System Management

  - `enabled?/0` - Check if the agent module is enabled (default: off)
  - `enable_system/0` - Enable the agent module
  - `disable_system/0` - Disable the agent module

  ## Permissions

  - `agent` — use the assistant.
  - `agent.manage` — the module defaults, other users' settings and spending.
    Core gives every module sub-key to the Admin role automatically, so Admin
    holds `agent.manage` from the first boot; that is accepted (spec §8).

  There is deliberately no `agent.view_all`: auto-granted to Admin, it would
  open every user's chats — with the customer data their tool results hold —
  to every Admin.

  ## Data

  Tables come from the module's own migration chain
  (`PhoenixKitAgent.Migrations`); attachment bytes live in a hidden Storage
  library (`PhoenixKitAgent.Library`); module settings are read through
  `PhoenixKitAgent.Config`. Deleting a user runs
  `PhoenixKitAgent.UserDeletion` first.
  """

  use PhoenixKit.Module
  use Gettext, backend: PhoenixKitAgent.Gettext

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitAgent.Attachments.Work
  alias PhoenixKitAgent.Turns.Runner

  @enabled_key "agent_enabled"

  # Single-sourced from mix.exs so a release bump touches one place only.
  @version Mix.Project.config()[:version]

  @doc """
  Returns whether the agent module is enabled. Defaults to `false`, including
  when the setting cannot be read.
  """
  @impl PhoenixKit.Module
  @spec enabled?() :: boolean()
  def enabled? do
    Settings.get_boolean_setting(@enabled_key, false)
  rescue
    _ -> false
  catch
    # `Settings.get_boolean_setting/2` can hit a shutting-down pool and exit on
    # `DBConnection.Holder.checkout/3`; the callback contract is "false as
    # fallback", which includes process exits.
    :exit, _ -> false
  end

  @doc """
  Enables the agent module.
  """
  @impl PhoenixKit.Module
  @spec enable_system() :: {:ok, term()} | {:error, term()}
  def enable_system do
    Settings.update_boolean_setting_with_module(@enabled_key, true, module_key())
  end

  @doc """
  Disables the agent module.
  """
  @impl PhoenixKit.Module
  @spec disable_system() :: {:ok, term()} | {:error, term()}
  def disable_system do
    Settings.update_boolean_setting_with_module(@enabled_key, false, module_key())
  end

  @impl PhoenixKit.Module
  def module_key, do: "agent"

  @impl PhoenixKit.Module
  def module_name, do: "AI Agent"

  @impl PhoenixKit.Module
  def required_modules, do: ["ai"]

  @impl PhoenixKit.Module
  def version, do: @version

  @impl PhoenixKit.Module
  def migration_module, do: PhoenixKitAgent.Migrations

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: module_key(),
      label: gettext_noop("AI Agent"),
      icon: "hero-sparkles",
      description: gettext_noop("Use the AI assistant, with the rights of one's own session"),
      gettext_backend: PhoenixKitAgent.Gettext,
      sub_permissions: [
        %{
          key: "manage",
          label: gettext_noop("Manage the AI assistant"),
          description:
            gettext_noop(
              "Edit the module defaults and other users' assistant settings, and see everyone's spending"
            )
        }
      ]
    }
  end

  @impl PhoenixKit.Module
  def admin_tabs do
    [
      Tab.new!(
        id: :admin_agent,
        label: gettext_noop("AI Agent"),
        gettext_backend: PhoenixKitAgent.Gettext,
        icon: "hero-sparkles",
        path: "agent",
        # After AI (640) and core's Sync (642), before Notifications (645):
        # 650 is phoenix_kit_dashboards' (core's `AdminTabs.module_tab_order/0`).
        priority: 643,
        level: :admin,
        permission: "agent.manage",
        match: :prefix,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false,
        redirect_to_first_subtab: true
      ),
      Tab.new!(
        id: :admin_agent_users,
        label: gettext_noop("Users"),
        gettext_backend: PhoenixKitAgent.Gettext,
        icon: "hero-users",
        path: "agent/users",
        priority: 644,
        level: :admin,
        permission: "agent.manage",
        parent: :admin_agent,
        match: :exact,
        live_view: {PhoenixKitAgent.Web.UsersLive, :index}
      ),
      Tab.new!(
        id: :admin_agent_spending,
        label: gettext_noop("Spending"),
        gettext_backend: PhoenixKitAgent.Gettext,
        icon: "hero-banknotes",
        path: "agent/spending",
        priority: 645,
        level: :admin,
        permission: "agent.manage",
        parent: :admin_agent,
        match: :exact,
        live_view: {PhoenixKitAgent.Web.SpendingLive, :index}
      )
    ]
  end

  @doc """
  The notification type of the module: `"agent_limit"`, what the watchers get
  when someone reaches a limit of the assistant (`PhoenixKitAgent.Limits`). A
  refusal of the AI budget is told by `phoenix_kit_ai`, under its own type. A
  watcher can switch it off for themselves.
  """
  @impl PhoenixKit.Module
  def notification_types do
    [
      %{
        key: "agent_limit",
        label: gettext("AI assistant limits"),
        description: gettext("Someone reached a spending or turn limit of the AI assistant"),
        actions: [],
        default: true
      }
    ]
  end

  @impl PhoenixKit.Module
  def settings_tabs do
    [
      Tab.new!(
        id: :admin_settings_agent,
        label: gettext_noop("AI Agent"),
        gettext_backend: PhoenixKitAgent.Gettext,
        icon: "hero-sparkles",
        path: "agent",
        priority: 935,
        level: :admin,
        parent: :admin_settings,
        permission: "agent.manage",
        match: :exact,
        live_view: {PhoenixKitAgent.Web.SettingsLive, :index}
      )
    ]
  end

  @impl PhoenixKit.Module
  def children do
    [
      PhoenixKitAgent.Turns.Supervisor,
      PhoenixKitAgent.Attachments.Slots,
      {Task.Supervisor, name: PhoenixKitAgent.Attachments.TaskSupervisor},
      {Task.Supervisor, name: PhoenixKitAgent.Attachments.WorkerSupervisor},
      {Task.Supervisor, name: PhoenixKitAgent.Confirmations.TaskSupervisor},
      Work.sweep_task()
    ]
  end

  @impl PhoenixKit.Module
  def css_sources, do: [:phoenix_kit_agent]

  @doc """
  The assistant in the admin header (spec §10): the chat panel
  `PhoenixKitAgent.Web.Dock`, before the notifications bell, in the dock
  column. Its session comes from `header_widget_session/1`.
  """
  @impl PhoenixKit.Module
  def header_widgets do
    [
      {PhoenixKitAgent.Web.Dock, "pk-agent-dock-widget", &__MODULE__.header_widget_session/1,
       [dock: true]}
    ]
  end

  @doc """
  The session of the chat panel, from the admin layout's assigns: the user's
  uuid and locale and nothing else, or `nil` — no panel — when the module is
  off, the session's scope does not hold `agent`, or the layout says the
  account is borrowed (`:impersonating?`, a hint only: the panel checks the
  session itself in its connected mount). Runs on every render of the layout,
  so it reads only the scope and the cached module switch.
  """
  @spec header_widget_session(map()) :: %{String.t() => String.t() | nil} | nil
  def header_widget_session(assigns) when is_map(assigns) do
    with false <- assigns[:impersonating?] == true,
         %Scope{} = scope <- assigns[:phoenix_kit_current_scope],
         uuid when is_binary(uuid) <- Scope.user_uuid(scope),
         true <- enabled?(),
         true <- Scope.can?(scope, module_key()) do
      %{"user_uuid" => uuid, "locale" => locale_of(assigns[:current_locale_base])}
    else
      _no_panel -> nil
    end
  end

  defp locale_of(locale) when is_binary(locale), do: locale
  defp locale_of(_none), do: nil

  @doc """
  The AI tasks of the module, for the guard of `phoenix_kit_ai`
  (`PhoenixKitAI.Tasks`):

    * `agent.chat` — the model calls of a turn. They need tools. A turn is
      admitted once (`PhoenixKitAI.Guard.admit/4` in `PhoenixKitAgent.Turns`),
      and the model may flag a request as off-purpose (`self_flag`).
    * `agent.attachment` — a picture described by the vision model. It needs
      images in.

  Both are private: only holders of `ai.manage` see the reasons of their
  flags and blocks. Both share the `free_text` block group with the AI
  Playground. The module keeps its own per-user limits
  (`PhoenixKitAgent.Limits`), so the guard has no user limits for them
  (`user_limits: false`), only the limits of the task.
  `typical_tokens` of the chat is the median of the assistant's calls
  on a running site.
  """
  @spec ai_tasks() :: [PhoenixKitAI.TaskSpec.t()]
  def ai_tasks do
    [
      %PhoenixKitAI.TaskSpec{
        key: "agent.chat",
        label: gettext_noop("AI assistant chat"),
        gettext_backend: PhoenixKitAgent.Gettext,
        purpose:
          gettext_noop(
            "A work assistant for the people of this site: it answers questions about the site's data and proposes changes through the site's tools."
          ),
        needs: [:tools],
        self_flag: true,
        private: true,
        block_group: "free_text",
        user_limits: false,
        endpoints: {PhoenixKitAgent.UserConfig, :endpoint_uuids, []},
        watchers: {PhoenixKitAgent.Limits, :guard_watchers, []},
        typical_tokens: {5_500, 250}
      },
      %PhoenixKitAI.TaskSpec{
        key: "agent.attachment",
        label: gettext_noop("AI assistant pictures"),
        gettext_backend: PhoenixKitAgent.Gettext,
        purpose:
          gettext_noop(
            "Describe a picture or a scanned page that a user attached to a message to the AI assistant."
          ),
        needs: [:vision],
        private: true,
        block_group: "free_text",
        user_limits: false,
        endpoints: {PhoenixKitAgent.Config, :vision_endpoint_uuid, []},
        watchers: {PhoenixKitAgent.Limits, :guard_watchers, []}
      }
    ]
  end

  @doc """
  The `phoenix_kit_ai` usage sink: a request row whose `attribution` names an
  assistant message (`"agent_message_uuid"`) is linked to it
  (`messages.ai_request_uuid`). See `PhoenixKitAgent.Turns.Runner`.
  """
  @spec handle_ai_usage(struct()) :: :ok
  def handle_ai_usage(request), do: Runner.record_usage(request)

  @doc """
  Before a user row is deleted: removes their attachment files from the
  module's hidden library (only files nothing else uses), their folder there,
  and their uuid from other users' notice lists and from the limit watchers.
  Their rows in the module's tables go with the user (`ON DELETE CASCADE`).
  See `PhoenixKitAgent.UserDeletion`.
  """
  @impl PhoenixKit.Module
  def before_user_delete(user_uuid), do: PhoenixKitAgent.UserDeletion.run(user_uuid)
end
