defmodule PhoenixKitAgent.UserConfigTest do
  @moduledoc """
  The settings of one user (spec §5.4, §7): what is in effect (the user's own
  value, else the module default), the user's own personal instructions, and
  what an admin with `agent.manage` changes — with who did it in the Activity
  log.
  """

  use PhoenixKitAgent.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKitAgent.Schemas.UserSettings
  alias PhoenixKitAgent.Test.LogProbe
  alias PhoenixKitAgent.UserConfig

  @me [impersonated: false]

  setup do
    {:ok, _} = PhoenixKitAgent.enable_system()
    user = user_with(["agent"], "member")
    {ref, _token} = session_fixture(user)
    %{user: user, ref: ref}
  end

  defp manager_scope do
    scope_of(user_with(["agent", "agent.manage"], "manager"))
  end

  describe "effective/1: the user's value, else the module default" do
    test "a user without a row gets every module default", %{user: user} do
      {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", Ecto.UUID.generate())

      effective = UserConfig.effective(user.uuid)

      assert effective.enabled?
      assert effective.endpoint_uuid == PhoenixKitAgent.Config.default_endpoint_uuid()
      assert effective.system_prompt == nil
      assert effective.personal_instructions == nil
      assert effective.daily_cost_limit_micro_usd == 1_000_000
      assert effective.monthly_cost_limit_micro_usd == 10_000_000
      assert effective.daily_turn_limit == 200
      assert effective.max_attachment_mb == 20
      assert effective.max_attachments_per_message == 5
      refute effective.notify_on_limit
    end

    test "a field the row sets wins; a nil field falls back", %{user: user} do
      endpoint = endpoint_fixture()
      {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", Ecto.UUID.generate())

      Repo.insert!(%UserSettings{
        user_uuid: user.uuid,
        endpoint_uuid: endpoint.uuid,
        system_prompt: "Be brief.",
        daily_cost_limit_micro_usd: 250_000,
        daily_turn_limit: 0,
        notify_on_limit: true
      })

      effective = UserConfig.effective(user.uuid)

      assert effective.endpoint_uuid == endpoint.uuid
      assert effective.system_prompt == "Be brief."
      assert effective.daily_cost_limit_micro_usd == 250_000
      # A limit of 0 is a real limit, not "unset".
      assert effective.daily_turn_limit == 0
      assert effective.monthly_cost_limit_micro_usd == 10_000_000
      assert effective.max_attachment_mb == 20
      assert effective.notify_on_limit
    end

    test "the module default moves the users without their own value", %{user: user} do
      {:ok, _} = Settings.update_setting("agent_daily_turn_limit", "17")

      assert UserConfig.effective(user.uuid).daily_turn_limit == 17
    end

    test "enabled: false switches the user off, nil leaves it to the permission", %{user: user} do
      Repo.insert!(%UserSettings{user_uuid: user.uuid, enabled: false})
      refute UserConfig.effective(user.uuid).enabled?
      refute UserConfig.enabled?(user.uuid)

      Repo.update_all(from(s in UserSettings, where: s.user_uuid == ^user.uuid),
        set: [enabled: nil]
      )

      assert UserConfig.enabled?(user.uuid)
    end

    test "a blank prompt is no prompt", %{user: user} do
      Repo.insert!(%UserSettings{
        user_uuid: user.uuid,
        system_prompt: "  \n ",
        personal_instructions: ""
      })

      effective = UserConfig.effective(user.uuid)
      assert effective.system_prompt == nil
      assert effective.personal_instructions == nil
    end
  end

  describe "effective_many/1 and the users of the assistant" do
    test "gives each user what effective/1 gives", %{user: user} do
      other = user_with(["agent"], "other")
      Repo.insert!(%UserSettings{user_uuid: other.uuid, daily_turn_limit: 3, system_prompt: "P"})

      many = UserConfig.effective_many([user.uuid, other.uuid])

      assert many[user.uuid] == UserConfig.effective(user.uuid)
      assert many[other.uuid] == UserConfig.effective(other.uuid)
      assert many[other.uuid].own == [:system_prompt, :daily_turn_limit]
      assert many[user.uuid].own == []
      assert UserConfig.effective_many([]) == %{}
    end

    test "the users are those holding agent, and the Owners, active ones only", %{user: user} do
      stranger = user_with(["dashboard"], "stranger")
      blocked = user_with(["agent"], "blocked")

      Repo.update_all(from(u in PhoenixKit.Users.Auth.User, where: u.uuid == ^blocked.uuid),
        set: [is_active: false]
      )

      uuids = Enum.map(UserConfig.agent_users(), & &1.uuid)

      assert user.uuid in uuids
      assert owner_fixture().uuid in uuids
      refute stranger.uuid in uuids
      refute blocked.uuid in uuids

      assert UserConfig.agent_user?(user.uuid)
      refute UserConfig.agent_user?(stranger.uuid)
      refute UserConfig.agent_user?("nope")
    end
  end

  describe "personal instructions" do
    test "the user writes and reads their own through the session", %{user: user, ref: ref} do
      assert {:ok, nil} = UserConfig.get_personal_instructions(ref, @me)

      assert {:ok, "Call me Tim."} =
               UserConfig.put_personal_instructions(ref, "  Call me Tim.  ", @me)

      assert {:ok, "Call me Tim."} = UserConfig.get_personal_instructions(ref, @me)
      assert UserConfig.effective(user.uuid).personal_instructions == "Call me Tim."
    end

    test "a blank text clears them", %{ref: ref} do
      {:ok, _} = UserConfig.put_personal_instructions(ref, "Something", @me)

      assert {:ok, nil} = UserConfig.put_personal_instructions(ref, "   ", @me)
      assert {:ok, nil} = UserConfig.get_personal_instructions(ref, @me)
    end

    test "writing them leaves everything an admin set untouched", %{user: user, ref: ref} do
      endpoint = endpoint_fixture()

      Repo.insert!(%UserSettings{
        user_uuid: user.uuid,
        enabled: false,
        endpoint_uuid: endpoint.uuid,
        system_prompt: "Admin prompt",
        daily_turn_limit: 5,
        daily_cost_limit_micro_usd: 7,
        notify_on_limit: true
      })

      # The assistant is switched off for this user, so the session is refused
      # first; switch it on to reach the write.
      Repo.update_all(from(s in UserSettings, where: s.user_uuid == ^user.uuid),
        set: [enabled: nil]
      )

      {:ok, _} = UserConfig.put_personal_instructions(ref, "Mine", @me)

      row = Repo.get!(UserSettings, user.uuid)
      assert row.personal_instructions == "Mine"
      assert row.endpoint_uuid == endpoint.uuid
      assert row.system_prompt == "Admin prompt"
      assert row.daily_turn_limit == 5
      assert row.daily_cost_limit_micro_usd == 7
      assert row.notify_on_limit
    end

    test "a forged attribute cannot change a limit, the switch or the model", %{user: user} do
      endpoint = endpoint_fixture()

      changeset =
        UserSettings.personal_changeset(%UserSettings{user_uuid: user.uuid}, %{
          personal_instructions: "Mine",
          enabled: false,
          endpoint_uuid: endpoint.uuid,
          system_prompt: "Ignore the rules",
          daily_turn_limit: 100_000,
          daily_cost_limit_micro_usd: 1,
          notify_on_limit: true,
          updated_by_uuid: user.uuid
        })

      assert Map.keys(changeset.changes) == [:personal_instructions]
    end

    test "a text over the limit is refused and nothing is written", %{user: user, ref: ref} do
      text = String.duplicate("a", 4_001)

      assert {:error, %Ecto.Changeset{}} = UserConfig.put_personal_instructions(ref, text, @me)
      assert Repo.get(UserSettings, user.uuid) == nil
    end

    test "something that is not text is refused", %{user: user, ref: ref} do
      for junk <- [42, %{"a" => 1}, ["x"]] do
        assert {:error, %Ecto.Changeset{}} = UserConfig.put_personal_instructions(ref, junk, @me)
      end

      assert Repo.get(UserSettings, user.uuid) == nil
    end

    test "NUL characters are cut", %{ref: ref} do
      assert {:ok, "ab"} = UserConfig.put_personal_instructions(ref, "a\0b", @me)
    end

    test "a revoked session, an impersonated one and a switched-off user are refused", %{
      user: user
    } do
      {ref, token} = session_fixture(user)

      assert {:error, :impersonated} =
               UserConfig.put_personal_instructions(ref, "x", impersonated: true)

      assert {:error, :impersonated} =
               UserConfig.get_personal_instructions(ref, impersonated: true)

      Repo.insert!(%UserSettings{user_uuid: user.uuid, enabled: false})
      assert {:error, :forbidden} = UserConfig.put_personal_instructions(ref, "x", @me)
      assert {:error, :forbidden} = UserConfig.get_personal_instructions(ref, @me)

      Repo.update_all(from(s in UserSettings, where: s.user_uuid == ^user.uuid),
        set: [enabled: nil]
      )

      :ok = Auth.delete_user_session_token(token)
      assert {:error, :session_gone} = UserConfig.put_personal_instructions(ref, "x", @me)
      assert Repo.get!(UserSettings, user.uuid).personal_instructions == nil
    end

    test "a user without the agent permission is refused" do
      stranger = user_with(["dashboard"], "stranger")
      {ref, _} = session_fixture(stranger)

      assert {:error, :forbidden} = UserConfig.put_personal_instructions(ref, "x", @me)
      assert Repo.get(UserSettings, stranger.uuid) == nil
    end

    test "the text never reaches the log, not even Ecto's debug lines", %{ref: ref} do
      secret = "SecretPI-#{System.unique_integer([:positive])}"

      {result, logs} =
        LogProbe.capture(fn -> UserConfig.put_personal_instructions(ref, secret, @me) end)

      assert {:ok, ^secret} = result
      for line <- logs, do: refute(line =~ secret, "leaked to the log: " <> line)
    end

    test "the missing impersonation flag raises", %{ref: ref} do
      assert_raise ArgumentError, fn -> UserConfig.put_personal_instructions(ref, "x", []) end
    end
  end

  describe "admin_update/3" do
    test "writes the fields, records who, and logs the change in Activity", %{user: user} do
      endpoint = declared(%{name: "Tools", model: "a/tools"}, "yes")
      scope = manager_scope()
      manager_uuid = scope.user.uuid

      assert {:ok, %UserSettings{} = row, fields} =
               UserConfig.admin_update(scope, user.uuid, %{
                 "endpoint_uuid" => endpoint.uuid,
                 "system_prompt" => "SECRET-PROMPT-TEXT",
                 "daily_turn_limit" => "12",
                 "enabled" => "false"
               })

      assert Enum.sort(fields) == [:daily_turn_limit, :enabled, :endpoint_uuid, :system_prompt]
      assert row.updated_by_uuid == manager_uuid
      assert row.system_prompt == "SECRET-PROMPT-TEXT"
      assert row.daily_turn_limit == 12
      refute row.enabled

      assert [entry] = activity("agent.user_settings_updated")
      assert entry.actor_uuid == manager_uuid
      assert entry.resource_uuid == user.uuid
      assert entry.module == "agent"

      assert Enum.sort(entry.metadata["fields"]) ==
               ["daily_turn_limit", "enabled", "endpoint_uuid", "system_prompt"]

      # The fact of the change, never the prompt text.
      refute inspect(entry) =~ "SECRET-PROMPT-TEXT"
    end

    test "an unchanged save writes no Activity entry", %{user: user} do
      scope = manager_scope()

      {:ok, _, [:daily_turn_limit]} =
        UserConfig.admin_update(scope, user.uuid, %{daily_turn_limit: 3})

      assert {:ok, _row, []} = UserConfig.admin_update(scope, user.uuid, %{daily_turn_limit: 3})
      assert length(activity("agent.user_settings_updated")) == 1
    end

    test "does not touch the user's personal instructions or a running turn's lock", %{
      user: user,
      ref: ref
    } do
      {:ok, _} = UserConfig.put_personal_instructions(ref, "Mine", @me)

      Repo.update_all(from(s in UserSettings, where: s.user_uuid == ^user.uuid),
        set: [busy_since: DateTime.utc_now(), busy_turn_ref: "t1"]
      )

      {:ok, row, _} =
        UserConfig.admin_update(manager_scope(), user.uuid, %{
          "personal_instructions" => "Forged by admin",
          "busy_turn_ref" => "forged",
          "daily_turn_limit" => "9"
        })

      assert row.personal_instructions == "Mine"
      assert row.busy_turn_ref == "t1"
      assert row.daily_turn_limit == 9
    end

    test "the admin's prompt never reaches the log, not even Ecto's debug lines", %{user: user} do
      scope = manager_scope()
      secret = "SecretAP-#{System.unique_integer([:positive])}"

      {result, logs} =
        LogProbe.capture(fn ->
          UserConfig.admin_update(scope, user.uuid, %{"system_prompt" => secret})
        end)

      assert {:ok, %UserSettings{system_prompt: ^secret}, [:system_prompt]} = result
      for line <- logs, do: refute(line =~ secret, "leaked to the log: " <> line)
    end

    test "an invalid value is an error and writes nothing", %{user: user} do
      scope = manager_scope()

      assert {:error, %Ecto.Changeset{}} =
               UserConfig.admin_update(scope, user.uuid, %{"daily_turn_limit" => "-1"})

      assert Repo.get(UserSettings, user.uuid) == nil
      assert activity("agent.user_settings_updated") == []
    end

    test "a scope without agent.manage is refused and nothing is written", %{user: user} do
      plain = scope_of(user_with(["agent"], "plain"))

      assert {:error, :forbidden} =
               UserConfig.admin_update(plain, user.uuid, %{"daily_turn_limit" => "1"})

      assert {:error, :forbidden} = UserConfig.admin_update(nil, user.uuid, %{})
      assert Repo.get(UserSettings, user.uuid) == nil
      assert activity("agent.user_settings_updated") == []
    end

    test "an unknown user is not found" do
      assert {:error, :not_found} =
               UserConfig.admin_update(manager_scope(), Ecto.UUID.generate(), %{})

      assert {:error, :not_found} = UserConfig.admin_update(manager_scope(), "nope", %{})
    end

    test "the edited user gets no notification of it", %{user: user} do
      {:ok, _} = Settings.update_setting("notifications_enabled", "true")

      {:ok, _, [:system_prompt]} =
        UserConfig.admin_update(manager_scope(), user.uuid, %{"system_prompt" => "SECRET"})

      assert Repo.all(
               from(n in PhoenixKit.Notifications.Notification,
                 where: n.recipient_uuid == ^user.uuid
               )
             ) == []
    end

    test "a money limit above $1,000,000 is an error, not a database exception", %{user: user} do
      scope = manager_scope()

      for value <- [1_000_000_000_001, 9_223_372_036_854_775_808] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 UserConfig.admin_update(scope, user.uuid, %{
                   "daily_cost_limit_micro_usd" => value,
                   "monthly_cost_limit_micro_usd" => value
                 })

        assert %{daily_cost_limit_micro_usd: [_], monthly_cost_limit_micro_usd: [_]} =
                 errors_on(changeset)
      end

      assert {:ok, _, _} =
               UserConfig.admin_update(scope, user.uuid, %{
                 "monthly_cost_limit_micro_usd" => 1_000_000_000_000
               })
    end

    test "an Owner's settings are changed by an Owner only" do
      owner = owner_fixture()
      manager = manager_scope()

      assert {:error, :forbidden} =
               UserConfig.admin_update(manager, owner.uuid, %{"daily_turn_limit" => "1"})

      assert Repo.get(UserSettings, owner.uuid) == nil
      assert activity("agent.user_settings_updated") == []

      assert {:ok, _, [:daily_turn_limit]} =
               UserConfig.admin_update(scope_of(owner), owner.uuid, %{"daily_turn_limit" => "1"})
    end

    test "with expected values: a save over someone else's change is refused", %{user: user} do
      scope = manager_scope()
      {:ok, _, _} = UserConfig.admin_update(scope, user.uuid, %{"daily_turn_limit" => "5"})

      # What the first admin's form showed when it opened: no limit of their own.
      opened = %{daily_turn_limit: nil, system_prompt: nil}

      assert {:error, :stale} =
               UserConfig.admin_update(
                 scope,
                 user.uuid,
                 %{"daily_turn_limit" => "", "system_prompt" => "Mine"},
                 expected: opened
               )

      row = Repo.get!(UserSettings, user.uuid)
      assert row.daily_turn_limit == 5
      assert row.system_prompt == nil
      assert length(activity("agent.user_settings_updated")) == 1

      assert {:ok, _, [:system_prompt]} =
               UserConfig.admin_update(scope, user.uuid, %{"system_prompt" => "Mine"},
                 expected: %{daily_turn_limit: 5, system_prompt: nil}
               )
    end

    test "with expected values: a field outside them does not make the save stale", %{
      user: user,
      ref: ref
    } do
      {:ok, _} = UserConfig.put_personal_instructions(ref, "Mine", @me)

      assert {:ok, _, [:daily_turn_limit]} =
               UserConfig.admin_update(manager_scope(), user.uuid, %{"daily_turn_limit" => "3"},
                 expected: %{daily_turn_limit: nil}
               )
    end

    test "blank limit fields go back to the module default", %{user: user} do
      scope = manager_scope()
      {:ok, _, _} = UserConfig.admin_update(scope, user.uuid, %{"daily_turn_limit" => "3"})
      assert UserConfig.effective(user.uuid).daily_turn_limit == 3

      {:ok, _, [:daily_turn_limit]} =
        UserConfig.admin_update(scope, user.uuid, %{"daily_turn_limit" => ""})

      assert UserConfig.effective(user.uuid).daily_turn_limit == 200
    end
  end

  describe "admin_update/4: the model must fit the agent.chat AI task" do
    setup do
      PhoenixKitAI.Guard.reset_caches()
      on_exit(&PhoenixKitAI.Guard.reset_caches/0)
      :ok
    end

    test "a model known to take no tools is refused and nothing is written", %{user: user} do
      unfit = declared(%{name: "Plain", model: "a/no-tools"}, "no")

      assert {:error, {:model_unfit, [:tools]}} =
               UserConfig.admin_update(manager_scope(), user.uuid, %{
                 "endpoint_uuid" => unfit.uuid,
                 "daily_turn_limit" => "4"
               })

      assert Repo.get(UserSettings, user.uuid) == nil
      assert activity("agent.user_settings_updated") == []
    end

    test "a model nobody knows takes tools is refused and nothing is written", %{user: user} do
      unknown = endpoint_fixture(%{model: "a/never-heard-of"})

      assert {:error, {:model_unverified, [:tools]}} =
               UserConfig.admin_update(manager_scope(), user.uuid, %{
                 "endpoint_uuid" => unknown.uuid
               })

      assert Repo.get(UserSettings, user.uuid) == nil
      assert activity("agent.user_settings_updated") == []
    end

    test "a model that takes tools is saved, and none (the module default) too", %{user: user} do
      fit = declared(%{name: "Tools", model: "a/tools"}, "yes")
      scope = manager_scope()

      assert {:ok, %UserSettings{endpoint_uuid: endpoint_uuid}, [:endpoint_uuid]} =
               UserConfig.admin_update(scope, user.uuid, %{"endpoint_uuid" => fit.uuid})

      assert endpoint_uuid == fit.uuid

      assert {:ok, %UserSettings{endpoint_uuid: nil}, [:endpoint_uuid]} =
               UserConfig.admin_update(scope, user.uuid, %{"endpoint_uuid" => nil})
    end

    test "a model kept as it is is not checked again", %{user: user} do
      unfit = declared(%{name: "Plain", model: "a/no-tools"}, "no")
      Repo.insert!(%UserSettings{user_uuid: user.uuid, endpoint_uuid: unfit.uuid})

      assert {:ok, _row, [:daily_turn_limit]} =
               UserConfig.admin_update(manager_scope(), user.uuid, %{
                 "endpoint_uuid" => unfit.uuid,
                 "daily_turn_limit" => "4"
               })
    end
  end

  # An endpoint whose model's tools an admin declared.
  defp declared(attrs, tools) do
    model = Map.fetch!(attrs, :model)

    endpoint_fixture(
      Map.put(attrs, :provider_settings, %{
        "capabilities" => %{"model" => model, "tools" => tools}
      })
    )
  end

  defp activity(action) do
    Repo.all(from(a in PhoenixKit.Activity.Entry, where: a.action == ^action))
  end
end
