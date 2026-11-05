defmodule PhoenixKitAgent.PermissionsTest do
  @moduledoc """
  The module's keys in core's permission system: `agent` and `agent.manage`
  exist while the module is registered, work only while it is enabled, and the
  Admin role is given both automatically (spec §8: accepted and on record). No
  `agent.view_all` exists to be given.
  """

  use PhoenixKitAgent.DataCase, async: false

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles

  test "the registry knows agent, agent.manage and agent.telegram, and no other agent key" do
    assert "agent" in Permissions.feature_module_keys()
    assert "agent.manage" in Permissions.sub_permission_keys()
    assert "agent.telegram" in Permissions.sub_permission_keys()

    agent_keys = Enum.filter(Permissions.all_module_keys(), &String.starts_with?(&1, "agent"))
    assert Enum.sort(agent_keys) == ["agent", "agent.manage", "agent.telegram"]
  end

  test "the Admin role is given agent and agent.manage automatically" do
    %{uuid: admin_uuid} = Roles.get_role_by_name("Admin")

    :ok = Permissions.auto_grant_new_keys_to_admin()

    assert Permissions.role_has_permission?(admin_uuid, "agent")
    assert Permissions.role_has_permission?(admin_uuid, "agent.manage")
  end

  test "the Admin role is not given agent.telegram at boot: it is opt-in; the Owner holds it" do
    %{uuid: admin_uuid} = Roles.get_role_by_name("Admin")

    :ok = Permissions.auto_grant_new_keys_to_admin()

    refute Permissions.role_has_permission?(admin_uuid, "agent.telegram")

    {:ok, _} = PhoenixKitAgent.enable_system()
    assert Scope.can?(scope_of(owner_fixture()), "agent.telegram")
    refute Scope.can?(scope_of(user_with(["agent", "agent.manage"])), "agent.telegram")
  end

  describe "Scope.can?/2" do
    setup do
      {:ok, _} = PhoenixKitAgent.enable_system()
      :ok
    end

    test "agent alone does not give agent.manage" do
      scope = scope_of(user_with(["agent"]))

      assert Scope.can?(scope, "agent")
      refute Scope.can?(scope, "agent.manage")
    end

    test "agent.manage is held with agent" do
      scope = scope_of(user_with(["agent", "agent.manage"]))

      assert Scope.can?(scope, "agent")
      assert Scope.can?(scope, "agent.manage")
    end

    test "neither works while the module is disabled" do
      scope = scope_of(user_with(["agent", "agent.manage"]))
      {:ok, _} = PhoenixKitAgent.disable_system()

      refute Scope.can?(scope, "agent")
      refute Scope.can?(scope, "agent.manage")
    end

    test "a user without the keys has neither" do
      scope = scope_of(user_with(["dashboard"]))

      refute Scope.can?(scope, "agent")
      refute Scope.can?(scope, "agent.manage")
    end
  end
end
