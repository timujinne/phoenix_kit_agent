defmodule PhoenixKitAgent.ConfigTest do
  @moduledoc """
  The module settings (`agent_*`, spec §5.6): their defaults (spec §14 В11), how
  a stored value is read, and the form that saves the defaults.
  """

  use PhoenixKitAgent.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Settings
  alias PhoenixKitAgent.Config
  alias PhoenixKitAgent.Test.LogProbe

  describe "defaults" do
    test "the limits are $1 a day, $10 a month, 200 turns, 20 MB files, 5 per message" do
      assert Config.limit_defaults() == %{
               daily_cost_limit_micro_usd: 1_000_000,
               monthly_cost_limit_micro_usd: 10_000_000,
               daily_turn_limit: 200,
               max_attachment_mb: 20,
               max_attachments_per_message: 5
             }
    end

    test "the turn: 8 tool rounds, 300 s, 12 000 characters of a tool result" do
      assert Config.max_tool_rounds() == 8
      assert Config.turn_deadline_s() == 300
      assert Config.tool_result_chars() == 12_000
      assert Config.history_chars() > 0
    end

    test "nothing chosen: no endpoints, no prompt, no watchers, no captured bodies" do
      assert Config.default_endpoint_uuid() == nil
      assert Config.vision_endpoint_uuid() == nil
      assert Config.system_prompt() == nil
      assert Config.limit_watchers() == []
      assert Config.capture_ai_content?() == false
    end
  end

  describe "reading stored values" do
    test "a stored limit is read, a broken or negative one is the default" do
      Settings.update_setting("agent_daily_turn_limit", "50")
      assert Config.limit_defaults().daily_turn_limit == 50

      Settings.update_setting("agent_daily_turn_limit", "lots")
      assert Config.limit_defaults().daily_turn_limit == 200

      Settings.update_setting("agent_daily_turn_limit", "-3")
      assert Config.limit_defaults().daily_turn_limit == 200
    end

    test "a limit of 0 is kept: it blocks" do
      Settings.update_setting("agent_daily_cost_limit_micro_usd", "0")
      assert Config.limit_defaults().daily_cost_limit_micro_usd == 0
    end

    test "a technical value of 0 is the default: the turn would be impossible" do
      Settings.update_setting("agent_max_tool_rounds", "0")
      assert Config.max_tool_rounds() == 8
    end

    test "capture is on only for exactly true" do
      Settings.update_setting("agent_capture_ai_content", "yes")
      refute Config.capture_ai_content?()

      Settings.update_setting("agent_capture_ai_content", "true")
      assert Config.capture_ai_content?()
    end

    test "watchers are a JSON list of uuids; a broken entry or a repeat is dropped" do
      a = Ecto.UUID.generate()
      b = Ecto.UUID.generate()

      Settings.update_json_setting("agent_limit_watchers", %{
        "uuids" => [a, "not-a-uuid", b, a, 42]
      })

      assert Config.limit_watchers() == [a, b]
    end

    test "remove_limit_watcher/1 takes one uuid out and leaves the rest" do
      a = Ecto.UUID.generate()
      b = Ecto.UUID.generate()
      {:ok, _} = Config.put_limit_watchers([a, b], [])

      assert {:ok, _} = Config.remove_limit_watcher(a)
      assert Config.limit_watchers() == [b]

      assert {:ok, :unchanged} = Config.remove_limit_watcher(Ecto.UUID.generate())
      assert Config.limit_watchers() == [b]
    end
  end

  describe "the long settings: the module prompt and the watchers" do
    # Core keeps a string setting to 1000 characters; these are stored as
    # JSON, which has no such cap.
    test "a module prompt longer than 1000 characters is saved and read back" do
      user = user_fixture()
      prompt = String.duplicate("Answer in Estonian. ", 200)

      assert {:ok, _} = Config.put_system_prompt(prompt, actor_uuid: user.uuid)
      assert Config.system_prompt() == prompt

      assert {:ok, _} = Config.put_system_prompt("   ", [])
      assert Config.system_prompt() == nil
    end

    test "the module prompt loses its NUL characters and has a length cap" do
      assert {:ok, _} =
               Config.put_system_prompt("Be <<0>>brief." |> String.replace("<<0>>", <<0>>), [])

      assert Config.system_prompt() == "Be brief."

      too_long = String.duplicate("x", 16_001)
      assert {:error, %Ecto.Changeset{} = changeset} = Config.put_system_prompt(too_long, [])
      assert %{text: [_]} = errors_on(changeset)
      assert Config.system_prompt() == "Be brief."

      assert {:ok, _} = Config.put_system_prompt(String.duplicate("x", 16_000), [])
    end

    test "more watchers than a string setting holds are saved and read back" do
      uuids = for _ <- 1..60, do: Ecto.UUID.generate()

      assert {:ok, _} = Config.put_limit_watchers(uuids ++ [hd(uuids)], [])
      assert Config.limit_watchers() == uuids
    end

    test "a watcher that is not a uuid is refused, nothing is saved" do
      assert {:error, :invalid_uuid} = Config.put_limit_watchers([Ecto.UUID.generate(), "x"], [])
      assert Config.limit_watchers() == []
    end
  end

  describe "the default and the vision model" do
    test "are set to an AI endpoint that chats, and back to none" do
      endpoint = declared(%{model: "a/both"}, %{"tools" => "yes", "vision" => "yes"})

      assert {:ok, _} = Config.put_default_endpoint(endpoint.uuid, [])
      assert {:ok, _} = Config.put_vision_endpoint(endpoint.uuid, [])
      assert Config.default_endpoint_uuid() == endpoint.uuid
      assert Config.vision_endpoint_uuid() == endpoint.uuid

      assert {:ok, _} = Config.put_default_endpoint(nil, [])
      assert {:ok, _} = Config.put_vision_endpoint(nil, [])
      assert Config.default_endpoint_uuid() == nil
      assert Config.vision_endpoint_uuid() == nil
    end

    test "an endpoint that does not exist, does not chat, or is not a uuid is refused" do
      embedder = endpoint_fixture(%{model: "openai/text-embedding-3-small"})
      assert PhoenixKitAI.Endpoint.kind(embedder) != :chat

      for uuid <- [Ecto.UUID.generate(), embedder.uuid, "not-a-uuid", ""] do
        assert {:error, :invalid_endpoint} = Config.put_default_endpoint(uuid, [])
        assert {:error, :invalid_endpoint} = Config.put_vision_endpoint(uuid, [])
      end

      assert Settings.get_setting("agent_default_endpoint_uuid", nil) in [nil, ""]
      assert Settings.get_setting("agent_vision_endpoint_uuid", nil) in [nil, ""]
    end
  end

  describe "the default and the vision model must fit their AI tasks" do
    setup do
      PhoenixKitAI.Guard.reset_caches()
      on_exit(&PhoenixKitAI.Guard.reset_caches/0)
      :ok
    end

    test "a default model known to take no tools is refused (agent.chat)" do
      unfit = declared(%{model: "a/no-tools"}, %{"tools" => "no", "vision" => "yes"})

      assert {:error, {:model_unfit, [:tools]}} = Config.put_default_endpoint(unfit.uuid, [])
      assert Settings.get_setting("agent_default_endpoint_uuid", nil) in [nil, ""]
    end

    test "a vision model known not to take pictures is refused (agent.attachment)" do
      unfit = declared(%{model: "a/no-vision"}, %{"tools" => "yes", "vision" => "no"})

      assert {:error, {:model_unfit, [:vision]}} = Config.put_vision_endpoint(unfit.uuid, [])
      assert Settings.get_setting("agent_vision_endpoint_uuid", nil) in [nil, ""]
    end

    test "a model nobody knows the abilities of is refused for both" do
      unknown = endpoint_fixture(%{model: "a/never-heard-of"})

      assert {:error, {:model_unverified, [:tools]}} =
               Config.put_default_endpoint(unknown.uuid, [])

      assert {:error, {:model_unverified, [:vision]}} =
               Config.put_vision_endpoint(unknown.uuid, [])

      assert Settings.get_setting("agent_default_endpoint_uuid", nil) in [nil, ""]
      assert Settings.get_setting("agent_vision_endpoint_uuid", nil) in [nil, ""]
    end

    test "a fit model is saved, and none too" do
      tools = declared(%{model: "a/tools"}, %{"tools" => "yes", "vision" => "no"})
      vision = declared(%{model: "a/vision"}, %{"tools" => "no", "vision" => "yes"})

      assert {:ok, _} = Config.put_default_endpoint(tools.uuid, [])
      assert {:ok, _} = Config.put_vision_endpoint(vision.uuid, [])
      assert Config.default_endpoint_uuid() == tools.uuid
      assert Config.vision_endpoint_uuid() == vision.uuid

      assert {:ok, _} = Config.put_default_endpoint(nil, [])
      assert {:ok, _} = Config.put_vision_endpoint(nil, [])
      assert Config.default_endpoint_uuid() == nil
      assert Config.vision_endpoint_uuid() == nil
    end
  end

  # An endpoint whose model's abilities an admin declared.
  defp declared(attrs, flags) do
    model = Map.fetch!(attrs, :model)

    endpoint_fixture(
      Map.put(attrs, :provider_settings, %{"capabilities" => Map.put(flags, "model", model)})
    )
  end

  describe "the module prompt in the Activity log" do
    defp prompt_entries do
      Repo.all(
        from(a in PhoenixKit.Activity.Entry,
          where:
            a.action == "agent.settings_updated" or
              fragment("?->>'key' = ?", a.metadata, "agent_system_prompt")
        )
      )
    end

    test "a change is recorded with who made it, never with the text — nor logged" do
      user = user_fixture()
      secret = "SecretPrompt-#{System.unique_integer([:positive])}"

      {result, logs} =
        LogProbe.capture(fn -> Config.put_system_prompt(secret, actor_uuid: user.uuid) end)

      assert {:ok, _} = result
      assert Config.system_prompt() == secret
      for line <- logs, do: refute(line =~ secret, "leaked to the log: " <> line)

      assert [entry] = prompt_entries()
      assert entry.action == "agent.settings_updated"
      assert entry.actor_uuid == user.uuid
      assert entry.metadata["fields"] == ["system_prompt"]
      refute inspect(entry) =~ secret

      # The same text again is no change.
      assert {:ok, _} = Config.put_system_prompt(secret, actor_uuid: user.uuid)
      assert length(prompt_entries()) == 1
    end
  end

  describe "the defaults form" do
    test "shows money in dollars" do
      form = Config.defaults_form_values()

      assert form["daily_cost_limit_usd"] == "1"
      assert form["monthly_cost_limit_usd"] == "10"
      assert form["daily_turn_limit"] == "200"
    end

    test "saves dollars as micro-dollars, with a comma or a dot" do
      user = user_fixture()

      params = %{
        Config.defaults_form_values()
        | "daily_cost_limit_usd" => "2,5",
          "monthly_cost_limit_usd" => "12.25",
          "daily_turn_limit" => "100",
          "max_tool_rounds" => "6"
      }

      assert {:ok, _} = Config.save_defaults(params, actor_uuid: user.uuid)

      assert Config.limit_defaults().daily_cost_limit_micro_usd == 2_500_000
      assert Config.limit_defaults().monthly_cost_limit_micro_usd == 12_250_000
      assert Config.limit_defaults().daily_turn_limit == 100
      assert Config.max_tool_rounds() == 6
    end

    test "refuses what is not a number, a negative limit, or a value out of range, and saves nothing" do
      params = %{
        Config.defaults_form_values()
        | "daily_cost_limit_usd" => "-1",
          "daily_turn_limit" => "many",
          "max_tool_rounds" => "0"
      }

      assert {:error, changeset} = Config.save_defaults(params, [])

      assert %{daily_cost_limit_usd: [_], daily_turn_limit: [_], max_tool_rounds: [_]} =
               errors_on(changeset)

      assert Config.limit_defaults().daily_cost_limit_micro_usd == 1_000_000
      assert Config.limit_defaults().daily_turn_limit == 200
    end

    test "a value left at its built-in default is not stored" do
      params = %{Config.defaults_form_values() | "daily_turn_limit" => "150"}

      assert {:ok, ["agent_daily_turn_limit"]} = Config.save_defaults(params, [])
      assert Settings.get_setting("agent_daily_cost_limit_micro_usd", nil) in [nil, ""]
    end

    test "a write that fails half-way leaves every setting as it was" do
      # The keys are written in key order; the second one is refused by the
      # database after the first was written.
      Repo.query!("""
      CREATE FUNCTION pg_temp.agent_refuse_rounds() RETURNS trigger AS $$
      BEGIN
        IF NEW.key = 'agent_max_tool_rounds' THEN RAISE EXCEPTION 'refused'; END IF;
        RETURN NEW;
      END $$ LANGUAGE plpgsql
      """)

      Repo.query!("""
      CREATE TRIGGER agent_refuse_rounds BEFORE INSERT OR UPDATE ON phoenix_kit_settings
      FOR EACH ROW EXECUTE FUNCTION pg_temp.agent_refuse_rounds()
      """)

      params = %{
        Config.defaults_form_values()
        | "daily_turn_limit" => "150",
          "max_tool_rounds" => "6"
      }

      assert {:error, :not_saved} = Config.save_defaults(params, [])
      assert Settings.get_setting("agent_daily_turn_limit", nil) in [nil, ""]
      assert Config.limit_defaults().daily_turn_limit == 200
      assert Config.max_tool_rounds() == 8
    end

    test "a sub-micro-dollar fraction is refused, not rounded" do
      params = %{Config.defaults_form_values() | "daily_cost_limit_usd" => "0.0000001"}

      assert {:error, changeset} = Config.save_defaults(params, [])
      assert %{daily_cost_limit_usd: [_]} = errors_on(changeset)
    end
  end

  describe "cost_to_micro/1" do
    test "a journal cost in dollars is whole micro-dollars, rounded half up" do
      assert Config.cost_to_micro(Decimal.new("0.005")) == 5_000
      assert Config.cost_to_micro(Decimal.new("0.0000004")) == 0
      assert Config.cost_to_micro(Decimal.new("0.0000005")) == 1
      assert Config.cost_to_micro(Decimal.new("0.0000025")) == 3
      assert Config.cost_to_micro(Decimal.new("0.000000000000000001")) == 0
      assert Config.cost_to_micro(Decimal.new(0)) == 0
    end

    test "no cost known stays nil" do
      assert Config.cost_to_micro(nil) == nil
    end
  end
end
