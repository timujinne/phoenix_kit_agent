defmodule PhoenixKitAgent.Turns.GuardTest do
  @moduledoc """
  The AI guard of `phoenix_kit_ai` in a turn (spec 2026-10-21 §6.2, §8): the
  `agent.chat` task, the admission of a turn, the guard's refusals as
  notices, the model's off-purpose marker, and the AI budget told once.

  The model is a `Req.Test` stub of the provider behind `phoenix_kit_ai`; no
  request leaves the test.
  """

  use PhoenixKitAgent.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.{Permissions, Roles}
  alias PhoenixKitAgent.{Conversations, Prompt, Turns, UserConfig}
  alias PhoenixKitAgent.Schemas.{Message, UserSettings}
  alias PhoenixKitAgent.Test.{LogProbe, Tools}
  alias PhoenixKitAgent.Turns.Runner
  alias PhoenixKitAI.{Guard, GuardBlocks, GuardEvent, Request, TaskLimits}

  @stub __MODULE__
  @me [impersonated: false]
  @model "deepseek/deepseek-v4.1-flash"

  setup do
    {:ok, _} = PhoenixKitAgent.enable_system()
    {:ok, _} = PhoenixKitAI.enable_system()
    :ok = ModuleRegistry.register(Tools)
    Guard.reset_caches()

    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, @stub}, retry: false)
    Application.put_env(:phoenix_kit_agent, :test_tool_listener, self())

    on_exit(fn ->
      stop_all_turns()
      ModuleRegistry.unregister(Tools)
      Application.delete_env(:phoenix_kit_ai, :req_options)
      Application.delete_env(:phoenix_kit_agent, :test_tool_listener)
      Application.delete_env(:phoenix_kit_agent, :test_tool_hook)
      Guard.reset_caches()
    end)

    endpoint = endpoint_fixture(%{model: @model})
    {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", endpoint.uuid)

    owner = owner_fixture()
    {:ok, role} = Roles.create_role(%{name: "AgentGuard#{System.unique_integer([:positive])}"})
    for key <- ["agent", "dashboard"], do: {:ok, _} = Permissions.grant_permission(role.uuid, key)
    user = user_fixture("guard")
    {:ok, _} = Roles.assign_role(user, role.name)

    {ref, _token} = session_fixture(user)
    chat = conversation_fixture(user)
    :ok = Conversations.subscribe(ref, chat.uuid, @me)

    %{user: user, owner: owner, ref: ref, chat: chat, endpoint: endpoint}
  end

  # ── the model stub ──────────────────────────────────────────────────

  defp text_answer(text) do
    %{
      "model" => @model,
      "choices" => [%{"message" => %{"role" => "assistant", "content" => text}}],
      "usage" => %{"prompt_tokens" => 11, "completion_tokens" => 4, "total_tokens" => 15}
    }
  end

  defp tool_answer(content, calls) do
    %{
      "model" => @model,
      "choices" => [
        %{
          "message" => %{"role" => "assistant", "content" => content, "tool_calls" => calls},
          "finish_reason" => "tool_calls"
        }
      ],
      "usage" => %{"prompt_tokens" => 20, "completion_tokens" => 9, "total_tokens" => 29}
    }
  end

  defp call(id, name, args) do
    %{
      "id" => id,
      "type" => "function",
      "function" => %{"name" => name, "arguments" => Jason.encode!(args)}
    }
  end

  defp answer_next(answer, before \\ fn -> :ok end) do
    test = self()

    Req.Test.expect(@stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:model_request, Jason.decode!(raw)})
      before.()
      Req.Test.json(conn, answer)
    end)
  end

  defp no_model_call do
    Req.Test.stub(@stub, fn _conn -> flunk("the model must not be called") end)
  end

  # ── helpers ─────────────────────────────────────────────────────────

  defp start!(ctx, text) do
    assert {:ok, turn_ref} = Turns.start(ctx.ref, false, ctx.chat.uuid, text)
    turn_ref
  end

  defp await_end(chat, turn_ref) do
    chat_uuid = chat.uuid
    assert_receive {:agent_turn_finished, ^chat_uuid, ^turn_ref}, 5_000
  end

  defp messages(chat) do
    Repo.all(
      from(m in Message,
        where: m.conversation_uuid == ^chat.uuid,
        order_by: [asc: m.inserted_at, asc: m.uuid]
      )
    )
  end

  defp unlocked?(ctx) do
    chat = Repo.get!(PhoenixKitAgent.Schemas.Conversation, ctx.chat.uuid)

    user_lock =
      case Repo.get(UserSettings, ctx.user.uuid) do
        nil -> nil
        settings -> settings.busy_turn_ref
      end

    chat.busy_turn_ref == nil and user_lock == nil
  end

  defp flags(user) do
    Repo.all(
      from(e in GuardEvent,
        where: e.kind == "off_purpose" and e.user_uuid == ^user.uuid,
        order_by: [asc: e.inserted_at]
      )
    )
  end

  defp block!(ctx, user \\ nil) do
    {:ok, block} =
      Guard.block(scope_of(ctx.owner), "agent.chat", (user || ctx.user).uuid, "Off topic", nil)

    block
  end

  defp stop_all_turns do
    for pid <- Task.Supervisor.children(PhoenixKitAgent.Turns.TaskSupervisor) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        1_000 -> :ok
      end
    end

    _ = :sys.get_state(PhoenixKitAgent.Turns.Monitor)
  end

  # ── the tasks ───────────────────────────────────────────────────────

  describe "the AI tasks of the module" do
    test "agent.chat needs tools, is private, flags itself and leaves the user limits to the module" do
      spec = PhoenixKitAI.Tasks.get("agent.chat")

      assert spec.module == PhoenixKitAgent
      assert spec.needs == [:tools]
      assert spec.private
      assert spec.self_flag
      assert spec.block_group == "free_text"
      assert spec.user_limits == false
      assert spec.typical_tokens == {5_500, 250}
      assert spec.watchers == {PhoenixKitAgent.Limits, :guard_watchers, []}
    end

    test "agent.attachment needs pictures, is private, in the same block group" do
      spec = PhoenixKitAI.Tasks.get("agent.attachment")

      assert spec.needs == [:vision]
      assert spec.private
      refute spec.self_flag
      assert spec.block_group == "free_text"
      assert spec.user_limits == false
    end

    test "the endpoints of the tasks: the default and the users' own; the vision model", ctx do
      own = endpoint_fixture(%{name: "Own", model: "a/own"})
      vision = endpoint_fixture(%{name: "Eyes", model: "a/eyes"})
      {:ok, _} = Settings.update_setting("agent_vision_endpoint_uuid", vision.uuid)

      %UserSettings{user_uuid: ctx.user.uuid}
      |> UserSettings.admin_changeset(%{endpoint_uuid: own.uuid})
      |> Repo.insert!()

      chat = PhoenixKitAI.Tasks.get("agent.chat")
      attachment = PhoenixKitAI.Tasks.get("agent.attachment")

      assert Enum.sort(Enum.map(PhoenixKitAI.Tasks.endpoints(chat), & &1.uuid)) ==
               Enum.sort([ctx.endpoint.uuid, own.uuid])

      assert Enum.map(PhoenixKitAI.Tasks.endpoints(attachment), & &1.uuid) == [vision.uuid]
      assert Enum.sort(UserConfig.endpoint_uuids()) == Enum.sort([ctx.endpoint.uuid, own.uuid])
    end
  end

  describe "the guard's watchers" do
    test "the module's watchers, and the user's own only when notify_on_limit is on", ctx do
      watcher = user_with(["agent.manage"], "watcher")
      boss = user_with(["agent"], "boss")
      {:ok, _} = PhoenixKitAgent.Config.put_limit_watchers([watcher.uuid, ctx.user.uuid], [])

      %UserSettings{user_uuid: ctx.user.uuid}
      |> UserSettings.admin_changeset(%{notify_user_uuids: [boss.uuid], notify_on_limit: false})
      |> Repo.insert!()

      # The user is never their own watcher.
      assert PhoenixKitAgent.Limits.guard_watchers(ctx.user.uuid) == [watcher.uuid]

      Repo.update_all(from(s in UserSettings, where: s.user_uuid == ^ctx.user.uuid),
        set: [notify_on_limit: true]
      )

      assert Enum.sort(PhoenixKitAgent.Limits.guard_watchers(ctx.user.uuid)) ==
               Enum.sort([watcher.uuid, boss.uuid])

      assert PhoenixKitAgent.Limits.guard_watchers(nil) == [watcher.uuid, ctx.user.uuid]
    end

    test "no watchers of the module add nobody: the guard has its own", ctx do
      assert PhoenixKitAgent.Limits.guard_watchers(ctx.user.uuid) == []
    end
  end

  # ── the admission ───────────────────────────────────────────────────

  describe "a blocked user" do
    test "gets a notice, and nothing reaches the model nor the chat", ctx do
      block!(ctx)
      no_model_call()

      assert {:error, :task_blocked} = Turns.start(ctx.ref, false, ctx.chat.uuid, "Hello")

      assert [%Message{role: "notice", error: "task_blocked", content: content}] =
               messages(ctx.chat)

      assert content =~ "blocked"
      assert unlocked?(ctx)
      assert Repo.aggregate(Request, :count) == 0

      # Tried again the same day: refused, without a second notice.
      assert {:error, :task_blocked} = Turns.start(ctx.ref, false, ctx.chat.uuid, "Hello?")
      assert length(messages(ctx.chat)) == 1
    end

    test "once the block is lifted, a turn runs again", ctx do
      block = block!(ctx)
      assert {:error, :task_blocked} = Turns.start(ctx.ref, false, ctx.chat.uuid, "Hello")

      {:ok, _} = Guard.unblock(scope_of(ctx.owner), block, nil)
      answer_next(text_answer("Hi."))
      turn_ref = start!(ctx, "Hello again")
      await_end(ctx.chat, turn_ref)

      assert %Message{role: "assistant", content: "Hi."} = List.last(messages(ctx.chat))
    end
  end

  describe "a turn admitted before a block" do
    test "runs to its end: its rounds carry the admission", ctx do
      answer_next(
        tool_answer(nil, [call("c1", "agenttest_list_items", %{})]),
        fn -> block!(ctx) end
      )

      answer_next(text_answer("There are 3 items."))

      turn_ref = start!(ctx, "How many items?")
      await_end(ctx.chat, turn_ref)

      assert GuardBlocks.blocked?("agent.chat", ctx.user.uuid)

      assert %Message{role: "assistant", content: "There are 3 items."} =
               List.last(messages(ctx.chat))

      # The next turn is refused.
      assert {:error, :task_blocked} = Turns.start(ctx.ref, false, ctx.chat.uuid, "More")
    end

    test "is refused mid-way when its admission is gone: the guard's notice", ctx do
      answer_next(
        tool_answer(nil, [call("c1", "agenttest_list_items", %{})]),
        fn ->
          block!(ctx)

          :ets.match_delete(
            PhoenixKitAI.RequestCache.flags_table(),
            {{:guard_admission, :_}, :_}
          )
        end
      )

      turn_ref = start!(ctx, "How many items?")
      await_end(ctx.chat, turn_ref)

      assert %Message{role: "notice", error: "task_blocked", ai_request_uuid: nil} =
               List.last(messages(ctx.chat))
    end
  end

  describe "an answer of the guard's admission this module does not know" do
    test "starts no turn: a model_error refusal, and one log line without the answer" do
      {result, logs} =
        LogProbe.capture(fn ->
          Turns.admission({:error, {:database_down, "user@example.com secret"}})
        end)

      assert result == {:error, {:guard, :model_error, :day}}
      assert [line] = Enum.filter(logs, &(&1 =~ "admission"))
      refute line =~ "secret"
      refute line =~ "user@example.com"
      refute line =~ "database_down"

      assert Turns.admission(:surprise) == {:error, {:guard, :model_error, :day}}
      assert Runner.guard_text(:model_error) =~ "did not answer"
    end

    test "the known answers keep their meaning" do
      assert Turns.admission({:ok, "token"}) == {:ok, "token"}

      assert Turns.admission({:error, {:task_blocked, "free_text"}}) ==
               {:error, {:guard, :task_blocked, :day}}

      assert Turns.admission({:error, {:task_limit_exceeded, :task, :money, :month}}) ==
               {:error, {:guard, :task_limit_exceeded, :month}}
    end
  end

  describe "the task's own limit" do
    test "reached: a notice, no model call, the locks freed", ctx do
      {:ok, _} =
        TaskLimits.update_settings(scope_of(ctx.owner), "agent.chat", %{
          "limits" => %{"task" => %{"requests" => %{"day" => "0"}}}
        })

      no_model_call()

      assert {:error, :task_limit_exceeded} = Turns.start(ctx.ref, false, ctx.chat.uuid, "Hi")

      assert [%Message{role: "notice", error: "task_limit_exceeded"}] = messages(ctx.chat)
      assert unlocked?(ctx)
    end
  end

  # ── the calls ───────────────────────────────────────────────────────

  describe "the calls of a turn" do
    test "name the task and carry the turn's ref; the message takes the answer's row", ctx do
      answer_next(text_answer("Hi."))
      turn_ref = start!(ctx, "Hello")
      await_end(ctx.chat, turn_ref)

      answer = List.last(messages(ctx.chat))
      request = Repo.get!(Request, answer.ai_request_uuid)

      assert request.metadata["task"] == "agent.chat"

      assert request.metadata["attribution"] == %{
               "agent_message_uuid" => answer.uuid,
               "turn_ref" => turn_ref
             }
    end
  end

  describe "a model the guard refuses" do
    test "known to take no tools: the model_unfit notice, no HTTP", ctx do
      PhoenixKitAI.update_endpoint(ctx.endpoint, %{
        provider_settings: %{"capabilities" => %{"model" => @model, "tools" => "no"}}
      })

      no_model_call()
      turn_ref = start!(ctx, "Hello")
      await_end(ctx.chat, turn_ref)

      assert %Message{role: "notice", error: "model_unfit", content: content} =
               List.last(messages(ctx.chat))

      assert content =~ "cannot do what it needs"
    end

    test "not known to take tools, with only verified models allowed: model_unverified", ctx do
      {:ok, _} = Settings.update_setting("ai_guard_verified_models_only", "true")
      no_model_call()

      turn_ref = start!(ctx, "Hello")
      await_end(ctx.chat, turn_ref)

      assert %Message{role: "notice", error: "model_unverified"} = List.last(messages(ctx.chat))
    end

    test "no provider for the parameters: its own notice", ctx do
      Req.Test.expect(@stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          404,
          Jason.encode!(%{
            "error" => %{
              "message" => "No endpoints found that support all the requested parameters"
            }
          })
        )
      end)

      turn_ref = start!(ctx, "Hello")
      await_end(ctx.chat, turn_ref)

      assert %Message{role: "notice", error: "no_provider_for_params"} =
               List.last(messages(ctx.chat))
    end
  end

  # ── off-purpose ─────────────────────────────────────────────────────

  describe "the off-purpose marker" do
    test "a long whitespace run before a nonfinal marker is kept without delaying the turn",
         ctx do
      text = "Answer" <> String.duplicate(" ", 100_000) <> "⟦off_purpose: private⟧ extra"
      answer_next(text_answer(text))
      turn_ref = start!(ctx, "Explain")
      await_end(ctx.chat, turn_ref)

      assert %Message{role: "assistant", content: ^text} = List.last(messages(ctx.chat))
      assert flags(ctx.user) == []
    end

    test "a final marker after Unicode text and whitespace is cut at the right byte offset",
         ctx do
      answer_next(text_answer("Відповідь 🌻\n\t  ⟦off_purpose: особисте ⟧\n  "))
      turn_ref = start!(ctx, "Hi")
      await_end(ctx.chat, turn_ref)

      assert %Message{role: "assistant", content: "Відповідь 🌻"} = List.last(messages(ctx.chat))
      assert [%GuardEvent{reason: "особисте"}] = flags(ctx.user)
    end

    test "is cut off the answer before it is stored, and flags the turn", ctx do
      answer_next(text_answer("I can only help with work on this site.\n⟦off_purpose: a recipe⟧"))
      turn_ref = start!(ctx, "A recipe for soup?")
      await_end(ctx.chat, turn_ref)

      assert %Message{role: "assistant", content: "I can only help with work on this site."} =
               List.last(messages(ctx.chat))

      assert [flag] = flags(ctx.user)
      assert flag.task_key == "agent.chat"
      assert flag.ref == %{"turn_ref" => turn_ref}
      assert flag.reason == "a recipe"
    end

    test "flags a turn once, over all its rounds", ctx do
      answer_next(
        tool_answer("Looking.\n⟦off_purpose: personal⟧", [call("c1", "agenttest_list_items", %{})])
      )

      answer_next(text_answer("No.⟦off_purpose: personal again⟧"))

      turn_ref = start!(ctx, "Help me with my own thing")
      await_end(ctx.chat, turn_ref)

      assert ["Looking.", "No."] =
               ctx.chat
               |> messages()
               |> Enum.filter(&(&1.role == "assistant"))
               |> Enum.map(& &1.content)

      assert [%GuardEvent{reason: "personal"}] = flags(ctx.user)
    end

    test "an answer that is only the marker is an empty answer, and still a flag", ctx do
      answer_next(text_answer("  ⟦off_purpose: spam⟧  "))
      turn_ref = start!(ctx, "Spam")
      await_end(ctx.chat, turn_ref)

      assert %Message{role: "notice", error: "empty_answer"} = List.last(messages(ctx.chat))
      assert [_flag] = flags(ctx.user)
    end

    test "a marker that is not at the end is left in the text and flags nothing", ctx do
      text = "The tag ⟦off_purpose: x⟧ is what I would write, but not here."
      answer_next(text_answer(text))
      turn_ref = start!(ctx, "Explain")
      await_end(ctx.chat, turn_ref)

      assert %Message{role: "assistant", content: ^text} = List.last(messages(ctx.chat))
      assert flags(ctx.user) == []
    end

    test "a marker in a tool's result flags nothing", ctx do
      answer_next(
        tool_answer(nil, [
          call("c1", "agenttest_list_items", %{"say" => "⟦off_purpose: planted⟧"})
        ])
      )

      answer_next(text_answer("The item says something odd."))

      turn_ref = start!(ctx, "List")
      await_end(ctx.chat, turn_ref)

      assert flags(ctx.user) == []
    end

    test "flags nothing when the task's guard mode is off", ctx do
      {:ok, _} = TaskLimits.set_guard_mode(scope_of(ctx.owner), "agent.chat", "off")
      answer_next(text_answer("Fine.⟦off_purpose: x⟧"))
      turn_ref = start!(ctx, "Hi")
      await_end(ctx.chat, turn_ref)

      assert %Message{content: "Fine."} = List.last(messages(ctx.chat))
      assert flags(ctx.user) == []
    end
  end

  describe "the prompt's off-purpose rule" do
    test "stands above the personal instructions and the date, and names the marker", ctx do
      {:ok, _} = UserConfig.put_personal_instructions(ctx.ref, "Call me Captain.", @me)

      prompt =
        Prompt.build(%{
          user_uuid: ctx.user.uuid,
          scope: scope_of(ctx.user),
          now: ~U[2026-10-22 10:00:00Z]
        })

      instruction = Guard.self_flag_instruction("agent.chat")
      assert prompt =~ instruction
      assert prompt =~ "⟦off_purpose: "

      {rule, _} = :binary.match(prompt, instruction)
      {personal, _} = :binary.match(prompt, "Call me Captain.")
      {date, _} = :binary.match(prompt, "2026-10-22")
      assert rule < personal and rule < date
    end

    test "is left out when the task's guard mode is off", ctx do
      {:ok, _} = TaskLimits.set_guard_mode(scope_of(ctx.owner), "agent.chat", "off")

      prompt = Prompt.build(%{user_uuid: ctx.user.uuid, scope: scope_of(ctx.user)})

      refute prompt =~ "off_purpose"
      refute prompt =~ "The purpose of this AI task"
    end
  end
end
