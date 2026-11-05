defmodule PhoenixKitAgentTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Dashboard.AdminTabs
  alias PhoenixKit.Notifications.Types

  # `function_exported?/3` answers false for a module that is merely not
  # loaded, so load it before asserting on callbacks.
  setup_all do
    Code.ensure_loaded!(PhoenixKitAgent)
    :ok
  end

  describe "behaviour implementation" do
    test "implements PhoenixKit.Module" do
      behaviours =
        PhoenixKitAgent.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert PhoenixKit.Module in behaviours
    end

    test "has @phoenix_kit_module attribute for auto-discovery" do
      assert Keyword.get(PhoenixKitAgent.__info__(:attributes), :phoenix_kit_module) == [true]
    end
  end

  describe "identity" do
    test "module_key/0 is \"agent\"" do
      assert PhoenixKitAgent.module_key() == "agent"
    end

    test "module_name/0 is \"AI Agent\"" do
      assert PhoenixKitAgent.module_name() == "AI Agent"
    end

    test "required_modules/0 requires the ai module" do
      assert PhoenixKitAgent.required_modules() == ["ai"]
    end

    test "version/0 is the mix.exs version" do
      assert PhoenixKitAgent.version() == Mix.Project.config()[:version]
    end

    test "enable_system/0 and disable_system/0 are exported" do
      assert function_exported?(PhoenixKitAgent, :enable_system, 0)
      assert function_exported?(PhoenixKitAgent, :disable_system, 0)
    end
  end

  describe "callbacks" do
    test "migration_module/0 is the module's own chain" do
      assert PhoenixKitAgent.migration_module() == PhoenixKitAgent.Migrations
    end

    test "permission_metadata/0 declares agent, agent.manage and agent.telegram — and no view_all" do
      meta = PhoenixKitAgent.permission_metadata()

      assert meta.key == "agent"
      assert is_binary(meta.label) and is_binary(meta.icon) and is_binary(meta.description)
      assert Enum.map(meta.sub_permissions, & &1.key) == ["manage", "telegram"]
      refute Enum.any?(meta.sub_permissions, &(&1.key == "view_all"))
    end

    test "settings_tabs/0 is one tab, Settings → Agent, under agent.manage" do
      assert [tab] = PhoenixKitAgent.settings_tabs()

      assert tab.parent == :admin_settings
      assert tab.path == "agent"
      assert tab.permission == "agent.manage"
      assert tab.live_view == {PhoenixKitAgent.Web.SettingsLive, :index}
    end

    test "admin_tabs/0: Admin → Agent, with Users and Spending under it, all under agent.manage" do
      assert [parent, users, spending] = PhoenixKitAgent.admin_tabs()

      assert parent.id == :admin_agent
      assert parent.path == "agent"
      assert parent.permission == "agent.manage"
      assert parent.redirect_to_first_subtab

      assert users.parent == :admin_agent
      assert users.path == "agent/users"
      assert users.level == :admin
      assert users.permission == "agent.manage"
      assert users.live_view == {PhoenixKitAgent.Web.UsersLive, :index}

      assert spending.parent == :admin_agent
      assert spending.path == "agent/spending"
      assert spending.level == :admin
      assert spending.permission == "agent.manage"
      assert spending.live_view == {PhoenixKitAgent.Web.SpendingLive, :index}
    end

    # Core sorts the top-level admin tabs by priority alone: two tabs with one
    # priority come out in no fixed order (650 was phoenix_kit_dashboards').
    test "the top-level tab has a priority of its own among core's, ai's and core's module order" do
      taken =
        (AdminTabs.core_tabs() ++ AdminTabs.apply_module_tab_order(PhoenixKitAI.admin_tabs()))
        |> Enum.filter(&is_nil(&1.parent))
        |> Enum.map(& &1.priority)
        |> Kernel.++(AdminTabs.module_tab_order() |> Map.values() |> Enum.map(& &1.priority))

      assert [agent] =
               PhoenixKitAgent.admin_tabs()
               |> AdminTabs.apply_module_tab_order()
               |> Enum.filter(&is_nil(&1.parent))

      refute agent.priority in taken, "priority #{agent.priority} is taken"

      subtabs = Enum.reject(PhoenixKitAgent.admin_tabs(), &is_nil(&1.parent))
      priorities = Enum.map(subtabs, & &1.priority)
      assert priorities == Enum.uniq(priorities)
      assert Enum.all?(priorities, &(&1 > agent.priority))
    end

    test "notification_types/0 declares agent_limit, so a watcher can switch it off" do
      assert [%{key: "agent_limit", default: true, actions: []} = type] =
               PhoenixKitAgent.notification_types()

      assert is_binary(type.label) and is_binary(type.description)
      assert %{key: "agent_limit"} = Types.find("agent_limit")
    end

    test "before_user_delete/1 is defined" do
      assert function_exported?(PhoenixKitAgent, :before_user_delete, 1)
    end
  end

  describe "children/0 next to the other modules" do
    # PhoenixKit.Supervisor starts the children of every module it knows in one
    # list (`ModuleRegistry.static_children/0`): an id two modules share stops
    # the host from booting (`duplicate_child_name`).
    test "the children of all modules, this one included, can be started side by side" do
      specs = PhoenixKit.ModuleRegistry.static_children()
      ids = specs |> Enum.map(&Supervisor.child_spec(&1, []).id)

      for spec <- PhoenixKitAgent.children(),
          do: assert(Supervisor.child_spec(spec, []).id in ids)

      assert {:ok, {_flags, children}} = Supervisor.init(specs, strategy: :one_for_one)
      assert :supervisor.check_childspecs(children) == :ok
      assert ids -- Enum.uniq(ids) == []
    end

    test "every child of this module has an id of its own namespace" do
      for spec <- PhoenixKitAgent.children() do
        id = Supervisor.child_spec(spec, []).id
        assert is_atom(id)
        assert String.starts_with?(Atom.to_string(id), "Elixir.PhoenixKitAgent."), inspect(id)
      end
    end
  end
end
