defmodule PhoenixKitAgent.TurnsTest do
  @moduledoc """
  The turn loop (spec §6.1, §6.4, §6.6, §8): a user message, then model ↔ tool
  rounds over the session's read tools, with the chat and the user locked while
  it runs.

  The model is a `Req.Test` stub of the provider behind `phoenix_kit_ai`
  (every request body reaches the test process); the tools are
  `PhoenixKitAgent.Test.Tools`, registered in core's module registry and run
  through the real `PhoenixKit.API.Executor` with real sessions, roles and
  permissions.
  """

  use PhoenixKitAgent.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.PubSub.Manager, as: PubSub
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.{ActiveRole, Auth}
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKitAgent.{Config, Conversations}
  alias PhoenixKitAgent.Schemas.{Attachment, Conversation, Message, UserSettings}
  alias PhoenixKitAgent.Test.{Addenda, LogProbe, PageContexts}
  alias PhoenixKitAgent.Test.Tools
  alias PhoenixKitAgent.{Turns, UserConfig}
  alias PhoenixKitAgent.Turns.Monitor

  @stub __MODULE__
  @me [impersonated: false]
  @model "deepseek/deepseek-v4.1-flash"

  setup do
    {:ok, _} = PhoenixKitAgent.enable_system()
    {:ok, _} = PhoenixKitAI.enable_system()
    :ok = ModuleRegistry.register(Tools)

    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, @stub}, retry: false)
    Application.put_env(:phoenix_kit_agent, :test_tool_listener, self())

    on_exit(fn ->
      stop_all_turns()
      ModuleRegistry.unregister(Tools)
      Application.delete_env(:phoenix_kit_ai, :req_options)
      Application.delete_env(:phoenix_kit_agent, :test_tool_listener)
    end)

    endpoint = endpoint_fixture(%{model: @model})
    {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", endpoint.uuid)

    {:ok, role} = Roles.create_role(%{name: "AgentTurns#{System.unique_integer([:positive])}"})
    _ = owner_fixture()
    for key <- ["agent", "dashboard"], do: {:ok, _} = Permissions.grant_permission(role.uuid, key)
    user = user_fixture("turns")
    {:ok, _} = Roles.assign_role(user, role.name)

    {ref, token} = session_fixture(user)
    chat = conversation_fixture(user)
    :ok = Conversations.subscribe(ref, chat.uuid, @me)

    %{user: user, role: role, ref: ref, token: token, chat: chat, endpoint: endpoint}
  end

  # ── the model stub ──────────────────────────────────────────────────

  defp text_answer(text) do
    %{
      "model" => @model,
      "choices" => [%{"message" => %{"role" => "assistant", "content" => text}}],
      "usage" => %{"prompt_tokens" => 11, "completion_tokens" => 4, "total_tokens" => 15}
    }
  end

  defp tool_answer(calls) do
    %{
      "model" => @model,
      "choices" => [
        %{
          "message" => %{"role" => "assistant", "content" => nil, "tool_calls" => calls},
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

  # The next model request is answered with `answer`; its body goes to the
  # test process as `{:model_request, body}`. `before` runs in the turn's
  # process before the answer (to change the world between two rounds).
  defp answer_next(answer, before \\ fn -> :ok end) do
    test = self()

    Req.Test.expect(@stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:model_request, Jason.decode!(raw)})
      before.()
      Req.Test.json(conn, answer)
    end)
  end

  # The next model request waits until the test kills the turn.
  defp hang_next do
    test = self()

    Req.Test.expect(@stub, fn conn ->
      send(test, {:model_waiting, self()})

      receive do
        :never -> conn
      end
    end)
  end

  defp error_next(status) do
    Req.Test.expect(@stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(%{"error" => %{"message" => "boom"}}))
    end)
  end

  # ── helpers ─────────────────────────────────────────────────────────

  defp start!(ctx, text, opts \\ []) do
    assert {:ok, turn_ref} =
             Turns.start(
               ctx.ref,
               false,
               ctx.chat.uuid,
               text,
               Keyword.get(opts, :attachments, []),
               Keyword.drop(opts, [:attachments])
             )

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

  defp lock_of(chat) do
    c = Repo.get!(Conversation, chat.uuid)
    {c.busy_since, c.busy_turn_ref}
  end

  defp user_lock_of(user) do
    case Repo.get(UserSettings, user.uuid) do
      nil -> {nil, nil}
      s -> {s.busy_since, s.busy_turn_ref}
    end
  end

  defp unlocked?(ctx),
    do: lock_of(ctx.chat) == {nil, nil} and user_lock_of(ctx.user) == {nil, nil}

  # What was said, without the system message (which always carries the
  # context of the session).
  defp chat_messages(body), do: Enum.reject(body["messages"], &(&1["role"] == "system"))

  defp tool_names(body), do: Enum.map(body["tools"] || [], & &1["function"]["name"])

  # Suspends the monitor for the rest of the test; it is resumed at the end
  # even when the test fails half-way.
  defp suspend_monitor do
    monitor = Process.whereis(PhoenixKitAgent.Turns.Monitor)
    :ok = :sys.suspend(monitor)

    on_exit(fn ->
      try do
        :sys.resume(monitor)
      catch
        :exit, _not_suspended_or_gone -> :ok
      end
    end)

    monitor
  end

  # Polls `fun` until it is true (at most `timeout` ms).
  defp wait_until(fun, timeout \\ 2_000) do
    cond do
      fun.() ->
        :ok

      timeout <= 0 ->
        flunk("the condition was never met")

      true ->
        receive do
        after
          10 -> wait_until(fun, timeout - 10)
        end
    end
  end

  # The task supervisor of the turns is unreachable by its name, as while it
  # restarts, until the end of the test.
  defp hide_task_supervisor do
    name = PhoenixKitAgent.Turns.TaskSupervisor
    pid = Process.whereis(name)
    true = Process.unregister(name)

    on_exit(fn ->
      if Process.alive?(pid) and Process.whereis(name) == nil, do: Process.register(pid, name)
    end)

    {name, pid}
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

  # ── a turn ──────────────────────────────────────────────────────────

  describe "a turn with a tool call" do
    test "tool call → result → answer, in two rounds", ctx do
      answer_next(tool_answer([call("call_1", "agenttest_list_items", %{"query" => "chairs"})]))
      answer_next(text_answer("There are 3 items."))

      turn_ref = start!(ctx, "How many items?")
      await_end(ctx.chat, turn_ref)

      user_uuid = ctx.user.uuid
      assert_received {:agent_test_tool, "agenttest.list_items", %{"query" => "chairs"}, tool_ctx}
      assert tool_ctx.scope.user.uuid == user_uuid

      assert_received {:model_request, first}
      assert tool_names(first) == ["agenttest_list_items"]
      assert [%{"role" => "user", "content" => "How many items?"}] = chat_messages(first)

      assert_received {:model_request, second}
      assert [_user, assistant, tool] = chat_messages(second)
      assert assistant["role"] == "assistant"

      assert [%{"id" => "call_1", "function" => %{"name" => "agenttest_list_items"}}] =
               assistant["tool_calls"]

      assert tool["role"] == "tool"
      assert tool["tool_call_id"] == "call_1"
      assert %{"items" => ["chair", "table", "lamp"]} = Jason.decode!(tool["content"])

      assert [user_msg, call_msg, tool_msg, answer_msg] = messages(ctx.chat)
      assert {user_msg.role, user_msg.content} == {"user", "How many items?"}
      assert call_msg.role == "assistant"

      assert [%{"id" => "call_1", "name" => "agenttest_list_items", "arguments" => _}] =
               call_msg.tool_calls

      assert tool_msg.role == "tool"
      assert tool_msg.tool_name == "agenttest.list_items"
      assert tool_msg.tool_call_id == "call_1"
      assert tool_msg.tool_outcome == "ok"
      assert %{"items" => ["chair", "table", "lamp"]} = tool_msg.tool_result
      assert {answer_msg.role, answer_msg.content} == {"assistant", "There are 3 items."}
      assert answer_msg.model == @model
      assert answer_msg.input_tokens == 11
      assert answer_msg.output_tokens == 4

      assert Enum.all?([user_msg, call_msg, tool_msg, answer_msg], &(&1.turn_ref == turn_ref))
      assert unlocked?(ctx)
    end

    test "every message is broadcast on the chat's topic", ctx do
      answer_next(text_answer("Hi."))
      turn_ref = start!(ctx, "Hello")
      await_end(ctx.chat, turn_ref)

      chat_uuid = ctx.chat.uuid

      for message <- messages(ctx.chat) do
        message_uuid = message.uuid
        assert_received {:agent_message_added, ^chat_uuid, ^message_uuid}
      end
    end

    test "each model message is linked to its AI request row", ctx do
      answer_next(tool_answer([call("c1", "agenttest_list_items", %{})]))
      answer_next(text_answer("Done."))

      turn_ref = start!(ctx, "List")
      await_end(ctx.chat, turn_ref)

      assistants = Enum.filter(messages(ctx.chat), &(&1.role == "assistant"))
      assert length(assistants) == 2

      for message <- assistants do
        assert is_binary(message.ai_request_uuid)
        request = Repo.get!(PhoenixKitAI.Request, message.ai_request_uuid)
        assert request.user_uuid == ctx.user.uuid
        assert request.metadata["source"] == "agent"
        # agent_capture_ai_content is off: the call keeps the bodies out.
        assert request.metadata["content_redacted"] == true

        assert request.metadata["attribution"] == %{
                 "agent_message_uuid" => message.uuid,
                 "turn_ref" => turn_ref
               }

        assert request.metadata["task"] == "agent.chat"
      end
    end

    test "the module's prompt and the admin's prompt for the user are the system message",
         ctx do
      {:ok, _} = Config.put_system_prompt("You help with furniture.", [])

      Repo.insert!(%UserSettings{user_uuid: ctx.user.uuid, system_prompt: "Answer in Estonian."})

      answer_next(text_answer("Tere."))
      turn_ref = start!(ctx, "Hi")
      await_end(ctx.chat, turn_ref)

      assert_received {:model_request, body}
      assert [%{"role" => "system", "content" => system}, %{"role" => "user"}] = body["messages"]
      assert system =~ "You help with furniture."
      assert system =~ "Answer in Estonian."

      assert :binary.match(system, "You help with furniture.") <
               :binary.match(system, "Answer in Estonian.")
    end

    test "a model error ends the turn with a notice and frees the locks", ctx do
      error_next(500)

      turn_ref = start!(ctx, "Hi")
      await_end(ctx.chat, turn_ref)

      assert [%Message{role: "user"}, %Message{role: "notice"} = notice] = messages(ctx.chat)
      assert notice.error == "api_error"
      assert is_binary(notice.ai_request_uuid)
      assert unlocked?(ctx)
    end

    test "a model error is stored under a fixed code", ctx do
      error_next(429)

      turn_ref = start!(ctx, "Hi")
      await_end(ctx.chat, turn_ref)

      assert %Message{role: "notice", error: "rate_limited"} = List.last(messages(ctx.chat))
    end

    test "a provider account out of credit is stored under its own code, not as a retry", ctx do
      error_next(402)

      turn_ref = start!(ctx, "Hi")
      await_end(ctx.chat, turn_ref)

      assert %Message{role: "notice", error: "insufficient_credits", content: content} =
               List.last(messages(ctx.chat))

      assert content =~ "run out of credit"
      refute content =~ "Try again"
      assert unlocked?(ctx)
    end

    test "a refused key is stored under its own code, not as a retry", ctx do
      error_next(401)

      turn_ref = start!(ctx, "Hi")
      await_end(ctx.chat, turn_ref)

      assert %Message{role: "notice", error: "invalid_api_key", content: content} =
               List.last(messages(ctx.chat))

      assert content =~ "An administrator has to check"
      refute content =~ "Try again"
      assert unlocked?(ctx)
    end

    test "an answer that cannot be stored ends the turn with a notice", ctx do
      bad = put_in(text_answer("Hi."), ["usage", "prompt_tokens"], -1)
      answer_next(bad)

      turn_ref = start!(ctx, "Hi")
      await_end(ctx.chat, turn_ref)

      assert [%Message{role: "user"}, %Message{role: "notice", error: "interrupted"}] =
               messages(ctx.chat)

      assert unlocked?(ctx)
    end

    test "the rounds stop at agent_max_tool_rounds with a notice", ctx do
      {:ok, _} = Settings.update_setting("agent_max_tool_rounds", "2")

      answer_next(tool_answer([call("c1", "agenttest_list_items", %{})]))
      answer_next(tool_answer([call("c2", "agenttest_list_items", %{})]))

      turn_ref = start!(ctx, "Loop")
      await_end(ctx.chat, turn_ref)

      assert %Message{role: "notice", error: "max_tool_rounds"} = List.last(messages(ctx.chat))
      assert unlocked?(ctx)
    end
  end

  # ── what the model may call (spec §6.2, §8) ────────────────────────

  describe "the tools of a round" do
    test "the model sees the session's read tools only, without control fields", ctx do
      answer_next(text_answer("ok"))
      turn_ref = start!(ctx, "Hi")
      await_end(ctx.chat, turn_ref)

      assert_received {:model_request, body}
      # write_item writes; secret_items needs `users`, which the user lacks.
      assert tool_names(body) == ["agenttest_list_items"]

      for %{"function" => %{"parameters" => schema}} <- body["tools"] do
        for field <- ["dry_run", "confirm_token", "idempotency_key"] do
          refute Map.has_key?(schema["properties"] || %{}, field)
          refute field in (schema["required"] || [])
        end
      end
    end

    test "a write tool named by the model is denied: no handler, nothing written", ctx do
      answer_next(
        tool_answer([
          call("w1", "agenttest_write_item", %{"name" => "x"}),
          call("w2", "agenttest.write_item", %{"name" => "y"})
        ])
      )

      answer_next(text_answer("I cannot write."))

      turn_ref = start!(ctx, "Write something")
      await_end(ctx.chat, turn_ref)

      refute_received {:agent_test_tool, "agenttest.write_item", _, _}
      assert Settings.get_setting("agenttest_written") == nil

      tools = Enum.filter(messages(ctx.chat), &(&1.role == "tool"))
      assert Enum.map(tools, & &1.tool_call_id) == ["w1", "w2"]
      assert Enum.all?(tools, &(&1.tool_outcome == "denied"))

      assert_received {:model_request, _first}
      assert_received {:model_request, second}
      denied = Enum.filter(second["messages"], &(&1["role"] == "tool"))
      assert length(denied) == 2
    end

    test "a tool the session cannot see is denied", ctx do
      answer_next(tool_answer([call("s1", "agenttest_secret_items", %{})]))
      answer_next(text_answer("No."))

      turn_ref = start!(ctx, "Secrets?")
      await_end(ctx.chat, turn_ref)

      refute_received {:agent_test_tool, "agenttest.secret_items", _, _}

      assert %Message{tool_outcome: "denied"} =
               Enum.find(messages(ctx.chat), &(&1.role == "tool"))
    end

    test "a tool shown in an earlier round but not in this one is denied", ctx do
      # Round 1 shows list_items; before the answer the role loses `dashboard`,
      # so round 2 shows nothing and the call the model makes there is denied.
      answer_next(text_answer_with_tool("r1", %{}), fn ->
        :ok = revoke(ctx.role, "dashboard")
      end)

      answer_next(tool_answer([call("r2", "agenttest_list_items", %{})]))
      answer_next(text_answer("Done."))

      turn_ref = start!(ctx, "List")
      await_end(ctx.chat, turn_ref)

      assert_received {:model_request, first}
      assert tool_names(first) == ["agenttest_list_items"]
      assert_received {:model_request, second}
      assert tool_names(second) == []

      outcomes =
        for %Message{role: "tool"} = m <- messages(ctx.chat), do: {m.tool_call_id, m.tool_outcome}

      # r1 ran under round 1's set but the session no longer held the
      # permission: the executor refused it. r2 never reached the executor.
      assert {"r2", "denied"} in outcomes
      refute_received {:agent_test_tool, _, _, _}
    end

    test "control fields are cut from the arguments before the executor", ctx do
      args = %{
        "query" => "lamps",
        "dry_run" => true,
        "confirm_token" => "abc",
        "idempotency_key" => "key-1234567890abcdef"
      }

      answer_next(tool_answer([call("c1", "agenttest_list_items", args)]))
      answer_next(text_answer("Lamps."))

      turn_ref = start!(ctx, "Lamps?")
      await_end(ctx.chat, turn_ref)

      assert_received {:agent_test_tool, "agenttest.list_items", input, _ctx}
      assert input == %{"query" => "lamps"}
      assert %Message{tool_outcome: "ok"} = Enum.find(messages(ctx.chat), &(&1.role == "tool"))
    end

    test "arguments that are not a JSON object are an error, the executor is not called",
         ctx do
      bad = %{
        "id" => "b1",
        "type" => "function",
        "function" => %{"name" => "agenttest_list_items", "arguments" => "not json"}
      }

      answer_next(tool_answer([bad]))
      answer_next(text_answer("Sorry."))

      turn_ref = start!(ctx, "List")
      await_end(ctx.chat, turn_ref)

      refute_received {:agent_test_tool, _, _, _}
      assert %Message{tool_outcome: "error"} = Enum.find(messages(ctx.chat), &(&1.role == "tool"))
    end

    test "tool calls past the tenth of a round are denied, the executor is not called", ctx do
      calls = for i <- 1..12, do: call("c#{i}", "agenttest_list_items", %{"query" => "q#{i}"})
      answer_next(tool_answer(calls))
      answer_next(text_answer("Many."))

      turn_ref = start!(ctx, "Many")
      await_end(ctx.chat, turn_ref)

      outcomes =
        for %Message{role: "tool"} = m <- messages(ctx.chat), do: {m.tool_call_id, m.tool_outcome}

      assert outcomes ==
               Enum.map(1..10, &{"c#{&1}", "ok"}) ++ [{"c11", "denied"}, {"c12", "denied"}]

      for _i <- 1..10, do: assert_received({:agent_test_tool, _, %{"query" => "q" <> _}, _})
      refute_received {:agent_test_tool, _, _, _}
    end

    test "a long result is cut to agent_tool_result_chars, marked truncated", ctx do
      {:ok, _} = Settings.update_setting("agent_tool_result_chars", "500")

      answer_next(tool_answer([call("c1", "agenttest_list_items", %{"size" => 5_000})]))
      answer_next(text_answer("Long."))

      turn_ref = start!(ctx, "Big")
      await_end(ctx.chat, turn_ref)

      tool_msg = Enum.find(messages(ctx.chat), &(&1.role == "tool"))
      assert tool_msg.tool_result["truncated"] == true
      assert is_binary(tool_msg.tool_result["hint"])
      assert String.length(Jason.encode!(tool_msg.tool_result)) <= 500

      assert_received {:model_request, _}
      assert_received {:model_request, second}
      sent = Enum.find(second["messages"], &(&1["role"] == "tool"))
      assert String.length(sent["content"]) <= 500
      assert Jason.decode!(sent["content"])["truncated"] == true
    end
  end

  defp text_answer_with_tool(id, args), do: tool_answer([call(id, "agenttest_list_items", args)])

  defp revoke(role, key), do: Permissions.revoke_permission(role.uuid, key)

  # ── the history (spec §6.6) ─────────────────────────────────────────

  describe "the history" do
    test "earlier turns give their user texts and final answers, not their tool results",
         ctx do
      answer_next(tool_answer([call("c1", "agenttest_list_items", %{"query" => "old"})]))
      answer_next(text_answer("Three old items."))
      first = start!(ctx, "Old question")
      await_end(ctx.chat, first)

      answer_next(text_answer("New answer."))
      second = start!(ctx, "New question")
      await_end(ctx.chat, second)

      assert_received {:model_request, _}
      assert_received {:model_request, _}
      assert_received {:model_request, body}

      assert chat_messages(body) == [
               %{"role" => "user", "content" => "Old question"},
               %{"role" => "assistant", "content" => "Three old items."},
               %{"role" => "user", "content" => "New question"}
             ]
    end

    test "the oldest messages are left out beyond agent_history_chars", ctx do
      {:ok, _} = Settings.update_setting("agent_history_chars", "1000")
      old = String.duplicate("o", 900)

      answer_next(text_answer("a"))
      first = start!(ctx, old)
      await_end(ctx.chat, first)

      answer_next(text_answer("b"))
      second = start!(ctx, String.duplicate("n", 200))
      await_end(ctx.chat, second)

      assert_received {:model_request, _}
      assert_received {:model_request, body}
      contents = Enum.map(body["messages"], & &1["content"])
      refute old in contents
      assert List.last(contents) == String.duplicate("n", 200)
    end
  end

  # ── who may start a turn ────────────────────────────────────────────

  describe "starting a turn" do
    test "an impersonated session is refused: nothing saved, no model call", ctx do
      assert {:error, :impersonated} = Turns.start(ctx.ref, true, ctx.chat.uuid, "Hi")
      assert messages(ctx.chat) == []
      refute_received {:model_request, _}
      assert unlocked?(ctx)
    end

    test "the impersonation flag must be a boolean", ctx do
      assert_raise ArgumentError, fn -> Turns.start(ctx.ref, nil, ctx.chat.uuid, "Hi") end
    end

    test "someone else's chat is not found", ctx do
      other = user_with(["agent", "dashboard"], "other")
      {other_ref, _} = session_fixture(other)

      assert {:error, :not_found} = Turns.start(other_ref, false, ctx.chat.uuid, "Hi")
      assert messages(ctx.chat) == []
    end

    test "a revoked session is refused", ctx do
      Auth.delete_user_session_token(ctx.token)
      assert {:error, :session_gone} = Turns.start(ctx.ref, false, ctx.chat.uuid, "Hi")
    end

    test "a blank message is refused", ctx do
      assert {:error, :empty_message} = Turns.start(ctx.ref, false, ctx.chat.uuid, "   ")
    end

    test "with the AI module off there is no turn", ctx do
      {:ok, _} = PhoenixKitAI.disable_system()
      assert {:error, :ai_disabled} = Turns.start(ctx.ref, false, ctx.chat.uuid, "Hi")
      assert messages(ctx.chat) == []
    end

    test "a message longer than agent_history_chars is refused", ctx do
      {:ok, _} = Settings.update_setting("agent_history_chars", "1000")

      assert {:error, :message_too_long} =
               Turns.start(ctx.ref, false, ctx.chat.uuid, String.duplicate("x", 1001))

      assert messages(ctx.chat) == []
      assert unlocked?(ctx)

      answer_next(text_answer("ok"))
      turn_ref = start!(ctx, String.duplicate("x", 1000))
      await_end(ctx.chat, turn_ref)
    end

    test "without an endpoint there is no turn", ctx do
      {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", "none")
      assert {:error, :no_endpoint} = Turns.start(ctx.ref, false, ctx.chat.uuid, "Hi")
      assert unlocked?(ctx)
    end
  end

  # ── the user's settings (spec §5.4, §7) ────────────────────────────

  describe "the settings of the user" do
    defp last_request(user),
      do:
        Repo.one(
          from(r in PhoenixKitAI.Request,
            where: r.user_uuid == ^user.uuid,
            order_by: [desc: r.inserted_at, desc: r.uuid],
            limit: 1
          )
        )

    test "their own model is the one the request goes to and the journal records", ctx do
      own = endpoint_fixture(%{model: "mistralai/own-model"})
      Repo.insert!(%UserSettings{user_uuid: ctx.user.uuid, endpoint_uuid: own.uuid})

      answer_next(text_answer("ok"))
      turn_ref = start!(ctx, "Hi")
      await_end(ctx.chat, turn_ref)

      assert_received {:model_request, body}
      assert body["model"] == "mistralai/own-model"

      assert last_request(ctx.user).model == "mistralai/own-model"
      assert last_request(ctx.user).endpoint_uuid == own.uuid

      assert %Message{role: "assistant", model: "mistralai/own-model"} =
               List.last(messages(ctx.chat))
    end

    test "a user without their own model gets the module's", ctx do
      answer_next(text_answer("ok"))
      turn_ref = start!(ctx, "Hi")
      await_end(ctx.chat, turn_ref)

      assert last_request(ctx.user).model == @model
    end

    test "a change of the model takes effect with the next turn, in any chat", ctx do
      other_chat = conversation_fixture(ctx.user)
      :ok = Conversations.subscribe(ctx.ref, other_chat.uuid, @me)

      answer_next(text_answer("one"))
      await_end(ctx.chat, start!(ctx, "First"))
      assert last_request(ctx.user).model == @model

      own = endpoint_fixture(%{model: "mistralai/own-model"})

      Repo.insert!(%UserSettings{user_uuid: ctx.user.uuid, endpoint_uuid: own.uuid},
        on_conflict: {:replace, [:endpoint_uuid]},
        conflict_target: :user_uuid
      )

      answer_next(text_answer("two"))

      assert {:ok, turn_ref} = Turns.start(ctx.ref, false, other_chat.uuid, "Second")
      await_end(other_chat, turn_ref)
      assert last_request(ctx.user).model == "mistralai/own-model"
    end

    test "a turn under way keeps the model it started with", ctx do
      own = endpoint_fixture(%{model: "mistralai/own-model"})

      answer_next(
        tool_answer([call("call_1", "agenttest_list_items", %{})]),
        fn ->
          Repo.insert!(%UserSettings{user_uuid: ctx.user.uuid, endpoint_uuid: own.uuid},
            on_conflict: {:replace, [:endpoint_uuid]},
            conflict_target: :user_uuid
          )
        end
      )

      answer_next(text_answer("done"))
      await_end(ctx.chat, start!(ctx, "Hi"))

      assert_received {:model_request, first}
      assert_received {:model_request, second}
      assert first["model"] == @model
      assert second["model"] == @model

      # The change is for the next turn.
      answer_next(text_answer("next"))
      await_end(ctx.chat, start!(ctx, "Again"))
      assert_received {:model_request, third}
      assert third["model"] == "mistralai/own-model"
    end

    test "a deleted endpoint of the user falls back to the module's", ctx do
      own = endpoint_fixture(%{model: "mistralai/own-model"})
      Repo.insert!(%UserSettings{user_uuid: ctx.user.uuid, endpoint_uuid: own.uuid})
      {:ok, _} = PhoenixKitAI.delete_endpoint(own)

      answer_next(text_answer("ok"))
      await_end(ctx.chat, start!(ctx, "Hi"))

      assert last_request(ctx.user).model == @model
    end

    test "with their own model the user needs no module default", ctx do
      {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", "none")
      assert {:error, :no_endpoint} = Turns.start(ctx.ref, false, ctx.chat.uuid, "Hi")

      own = endpoint_fixture(%{model: "mistralai/own-model"})
      Repo.insert!(%UserSettings{user_uuid: ctx.user.uuid, endpoint_uuid: own.uuid})

      answer_next(text_answer("ok"))
      await_end(ctx.chat, start!(ctx, "Hi"))
      assert last_request(ctx.user).model == "mistralai/own-model"
    end

    test "a user the assistant is switched off for has no turn", ctx do
      Repo.insert!(%UserSettings{user_uuid: ctx.user.uuid, enabled: false})

      assert {:error, :forbidden} = Turns.start(ctx.ref, false, ctx.chat.uuid, "Hi")
      assert messages(ctx.chat) == []
      refute_received {:model_request, _}
    end

    test "switching the user off ends a turn at its next round", ctx do
      answer_next(
        tool_answer([call("call_1", "agenttest_list_items", %{})]),
        fn ->
          Repo.update_all(from(s in UserSettings, where: s.user_uuid == ^ctx.user.uuid),
            set: [enabled: false]
          )
        end
      )

      turn_ref = start!(ctx, "Hi")
      await_end(ctx.chat, turn_ref)

      assert %Message{role: "notice", error: "forbidden"} = List.last(messages(ctx.chat))
      assert unlocked?(ctx)
    end

    test "the system prompt: the module, the host, the admin, the user, then the context", ctx do
      {:ok, _} = Config.put_system_prompt("MODULE-PROMPT", [])
      Application.put_env(:phoenix_kit_agent, :prompt_addendum, {Addenda, :plain})
      Application.put_env(:phoenix_kit_agent, :page_context, {PageContexts, :order})

      on_exit(fn ->
        Application.delete_env(:phoenix_kit_agent, :prompt_addendum)
        Application.delete_env(:phoenix_kit_agent, :page_context)
      end)

      {:ok, _, _} =
        UserConfig.admin_update(scope_of(owner_fixture()), ctx.user.uuid, %{
          "system_prompt" => "ADMIN-PROMPT"
        })

      {:ok, _} = UserConfig.put_personal_instructions(ctx.ref, "PERSONAL-NOTE", @me)

      answer_next(text_answer("ok"))

      turn_ref = start!(ctx, "Hi", page: "/admin/orders/5", locale: "et")

      await_end(ctx.chat, turn_ref)

      assert_received {:model_request, body}
      assert [%{"role" => "system", "content" => system}, %{"role" => "user"}] = body["messages"]

      positions =
        for part <- [
              "MODULE-PROMPT",
              "HOST-ADDENDUM-PLAIN",
              "ADMIN-PROMPT",
              "rank below",
              "PERSONAL-NOTE",
              "Locale: et",
              "Page: /admin/orders/5",
              "Page context: Order A-2026-77 (/admin/orders/5)"
            ] do
          {at, _} = :binary.match(system, part)
          at
        end

      assert positions == Enum.sort(positions)
    end

    test "the host's page context gets the session's scope, not the user's default role", ctx do
      {:ok, _} = Settings.update_setting("role_switcher_enabled", "true")

      {:ok, second} =
        Roles.create_role(%{name: "AgentTurnsSecond#{System.unique_integer([:positive])}"})

      for key <- ["agent", "dashboard"],
          do: {:ok, _} = Permissions.grant_permission(second.uuid, key)

      {:ok, _} = Roles.assign_role(ctx.user, second.name)

      # What a scope built from the user alone acts as; the session acts as the other.
      default = Scope.active_role(scope_of(ctx.user))
      assert %{uuid: _} = default
      target = if default.uuid == second.uuid, do: ctx.role, else: second
      session_user = Auth.get_user_by_session_token(ctx.token)
      {:ok, _} = ActiveRole.switch(session_user, ctx.token, target.uuid)

      Application.put_env(:phoenix_kit_agent, :test_page_context_listener, self())
      Application.put_env(:phoenix_kit_agent, :page_context, {PageContexts, :recorded})

      on_exit(fn ->
        Application.delete_env(:phoenix_kit_agent, :page_context)
        Application.delete_env(:phoenix_kit_agent, :test_page_context_listener)
      end)

      answer_next(text_answer("ok"))
      await_end(ctx.chat, start!(ctx, "Hi", page: "/admin/orders/5"))

      assert_received {:page_context, "/admin/orders/5", scope}
      assert scope.user.uuid == ctx.user.uuid
      assert Scope.active_role(scope).uuid == target.uuid
      refute Scope.active_role(scope).uuid == default.uuid

      assert_received {:model_request, body}
      assert [%{"role" => "system", "content" => system}, _] = body["messages"]
      assert system =~ "Page context: HOST-PAGE-CONTEXT"
    end

    test "without options the context still names the user's locale and no page", ctx do
      answer_next(text_answer("ok"))
      await_end(ctx.chat, start!(ctx, "Hi"))

      assert_received {:model_request, body}
      assert [%{"role" => "system", "content" => system}, _] = body["messages"]
      assert system =~ "Locale: "
      refute system =~ "Page:"
    end

    test "the locale of the request context stands in for a missing locale option", ctx do
      answer_next(text_answer("ok"))
      await_end(ctx.chat, start!(ctx, "Hi", request_context: [language: "ru"]))

      assert_received {:model_request, body}
      assert [%{"role" => "system", "content" => system}, _] = body["messages"]
      assert system =~ "Locale: ru"
    end

    test "the prompt is the user's own: another user's instructions never reach it", ctx do
      other = user_with(["agent"], "other")
      Repo.insert!(%UserSettings{user_uuid: other.uuid, personal_instructions: "OTHERS-NOTE"})

      answer_next(text_answer("ok"))
      await_end(ctx.chat, start!(ctx, "Hi"))

      assert_received {:model_request, body}
      refute inspect(body) =~ "OTHERS-NOTE"
    end
  end

  # ── the locks (spec §6.1 step 3) ───────────────────────────────────

  describe "the locks" do
    test "a second turn in the same chat is refused while one runs", ctx do
      hang_next()
      turn_ref = start!(ctx, "First")
      assert_receive {:model_waiting, _pid}, 5_000

      assert {:error, :conversation_busy} = Turns.start(ctx.ref, false, ctx.chat.uuid, "Second")
      assert {_, ^turn_ref} = lock_of(ctx.chat)

      :ok = Turns.stop(ctx.ref, false, ctx.chat.uuid)
      await_end(ctx.chat, turn_ref)
    end

    test "two chats of one user: the second turn is refused while the first runs", ctx do
      other_chat = conversation_fixture(ctx.user)
      :ok = Conversations.subscribe(ctx.ref, other_chat.uuid, @me)

      hang_next()
      turn_ref = start!(ctx, "First")
      assert_receive {:model_waiting, _pid}, 5_000

      assert {:error, :turn_in_flight} = Turns.start(ctx.ref, false, other_chat.uuid, "Second")
      assert messages(other_chat) == []
      assert lock_of(other_chat) == {nil, nil}

      :ok = Turns.stop(ctx.ref, false, ctx.chat.uuid)
      await_end(ctx.chat, turn_ref)

      answer_next(text_answer("Now."))
      assert {:ok, second} = Turns.start(ctx.ref, false, other_chat.uuid, "Second")
      await_end(other_chat, second)
    end

    test "a killed turn frees both locks", ctx do
      hang_next()
      turn_ref = start!(ctx, "Hi")
      assert_receive {:model_waiting, _pid}, 5_000
      refute unlocked?(ctx)

      [{pid, _}] = Registry.lookup(PhoenixKitAgent.Turns.Registry, turn_ref)
      Process.exit(pid, :kill)
      await_end(ctx.chat, turn_ref)

      assert unlocked?(ctx)
      assert %Message{role: "notice", error: "interrupted"} = List.last(messages(ctx.chat))
    end

    test "a lock older than the deadline plus 60 s is taken over", ctx do
      stale = DateTime.add(DateTime.utc_now(), -(300 + 61), :second)

      Repo.update_all(from(c in Conversation, where: c.uuid == ^ctx.chat.uuid),
        set: [busy_since: stale, busy_turn_ref: "dead"]
      )

      Repo.insert!(%UserSettings{
        user_uuid: ctx.user.uuid,
        busy_since: stale,
        busy_turn_ref: "dead"
      })

      answer_next(text_answer("Back."))
      turn_ref = start!(ctx, "Hi")
      await_end(ctx.chat, turn_ref)
      assert unlocked?(ctx)
    end

    test "a lock older than the deadline but within its 60 s grace still blocks", ctx do
      aged = DateTime.add(DateTime.utc_now(), -(300 + 30), :second)

      Repo.update_all(from(c in Conversation, where: c.uuid == ^ctx.chat.uuid),
        set: [busy_since: aged, busy_turn_ref: "slow"]
      )

      assert {:error, :conversation_busy} = Turns.start(ctx.ref, false, ctx.chat.uuid, "Hi")
      assert messages(ctx.chat) == []
    end

    test "a turn whose lock was taken over stops at its next round", ctx do
      answer_next(tool_answer([call("c1", "agenttest_list_items", %{})]), fn ->
        Repo.update_all(from(c in Conversation, where: c.uuid == ^ctx.chat.uuid),
          set: [busy_since: DateTime.utc_now(), busy_turn_ref: "newer"]
        )
      end)

      turn_ref = start!(ctx, "Hi")
      await_end(ctx.chat, turn_ref)

      assert_received {:model_request, _}
      refute_received {:model_request, _}
      assert %Message{role: "notice", error: "lock_lost"} = List.last(messages(ctx.chat))
      assert {_, "newer"} = lock_of(ctx.chat)
    end

    test "a fresh lock of a turn that is gone still blocks until its TTL", ctx do
      Repo.update_all(from(c in Conversation, where: c.uuid == ^ctx.chat.uuid),
        set: [busy_since: DateTime.utc_now(), busy_turn_ref: "other"]
      )

      assert {:error, :conversation_busy} = Turns.start(ctx.ref, false, ctx.chat.uuid, "Hi")
      assert messages(ctx.chat) == []
    end
  end

  # ── ending a turn early ─────────────────────────────────────────────

  describe "stop, deadline, revoked session" do
    test "stop ends the turn: no answer saved, locks freed", ctx do
      hang_next()
      turn_ref = start!(ctx, "Hi")
      assert_receive {:model_waiting, _pid}, 5_000

      assert :ok = Turns.stop(ctx.ref, false, ctx.chat.uuid)
      await_end(ctx.chat, turn_ref)

      assert [%Message{role: "user"}] = messages(ctx.chat)
      assert unlocked?(ctx)
    end

    test "only the owner's session stops a turn", ctx do
      other = user_with(["agent", "dashboard"], "other")
      {other_ref, _} = session_fixture(other)

      hang_next()
      turn_ref = start!(ctx, "Hi")
      assert_receive {:model_waiting, _pid}, 5_000

      assert {:error, :not_found} = Turns.stop(other_ref, false, ctx.chat.uuid)
      assert {:error, :impersonated} = Turns.stop(ctx.ref, true, ctx.chat.uuid)
      assert [{_pid, _}] = Registry.lookup(PhoenixKitAgent.Turns.Registry, turn_ref)

      :ok = Turns.stop(ctx.ref, false, ctx.chat.uuid)
      await_end(ctx.chat, turn_ref)
    end

    test "stop of a chat whose lock names another chat's turn stops nothing", ctx do
      other_chat = conversation_fixture(ctx.user)

      hang_next()
      turn_ref = start!(ctx, "Hi")
      assert_receive {:model_waiting, _pid}, 5_000

      Repo.update_all(from(c in Conversation, where: c.uuid == ^other_chat.uuid),
        set: [busy_since: DateTime.utc_now(), busy_turn_ref: turn_ref]
      )

      assert {:error, :not_running} = Turns.stop(ctx.ref, false, other_chat.uuid)
      assert [{_pid, _}] = Registry.lookup(PhoenixKitAgent.Turns.Registry, turn_ref)

      :ok = Turns.stop(ctx.ref, false, ctx.chat.uuid)
      await_end(ctx.chat, turn_ref)
    end

    test "stop with a turn ref stops that turn only", ctx do
      hang_next()
      turn_ref = start!(ctx, "Hi")
      assert_receive {:model_waiting, _pid}, 5_000

      assert {:error, :not_running} =
               Turns.stop(ctx.ref, false, ctx.chat.uuid, UUIDv7.generate())

      assert [{_pid, _}] = Registry.lookup(PhoenixKitAgent.Turns.Registry, turn_ref)

      assert :ok = Turns.stop(ctx.ref, false, ctx.chat.uuid, turn_ref)
      await_end(ctx.chat, turn_ref)
      assert unlocked?(ctx)
    end

    test "stop with no turn running", ctx do
      assert {:error, :not_running} = Turns.stop(ctx.ref, false, ctx.chat.uuid)
    end

    test "the deadline ends the turn with a notice and frees the locks", ctx do
      hang_next()
      turn_ref = start!(ctx, "Hi", deadline_ms: 200)
      assert_receive {:model_waiting, _pid}, 5_000
      await_end(ctx.chat, turn_ref)

      assert [%Message{role: "user"}, %Message{role: "notice", error: "deadline"}] =
               messages(ctx.chat)

      assert unlocked?(ctx)
    end

    @tag timeout: 60_000
    test "a deadline_ms above agent_turn_deadline_s is cut to the setting", ctx do
      {:ok, _} = Settings.update_setting("agent_turn_deadline_s", "10")

      hang_next()
      turn_ref = start!(ctx, "Hi", deadline_ms: 3_600_000)
      assert_receive {:model_waiting, _pid}, 5_000

      chat_uuid = ctx.chat.uuid
      assert_receive {:agent_turn_finished, ^chat_uuid, ^turn_ref}, 15_000
      assert %Message{role: "notice", error: "deadline"} = List.last(messages(ctx.chat))
    end

    test "a deadline that fires after the answer is complete writes no notice", ctx do
      test = self()

      Req.Test.expect(@stub, fn conn ->
        send(test, {:model_waiting, self()})

        receive do
          :answer -> Req.Test.json(conn, text_answer("Done."))
        end
      end)

      turn_ref = start!(ctx, "Hi", deadline_ms: 100)
      assert_receive {:model_waiting, stub}, 5_000
      [{task, _}] = Registry.lookup(PhoenixKitAgent.Turns.Registry, turn_ref)

      # The monitor has armed the deadline (the task told it so before the
      # model call); the deadline then passes while it cannot act on it.
      monitor = Process.whereis(PhoenixKitAgent.Turns.Monitor)
      _ = :sys.get_state(monitor)
      monitor = suspend_monitor()

      wait_until(fn ->
        {:messages, queued} = Process.info(monitor, :messages)
        Enum.any?(queued, &match?({:deadline, _}, &1))
      end)

      down = Process.monitor(task)
      send(stub, :answer)
      assert_receive {:DOWN, ^down, :process, ^task, :normal}, 5_000

      :ok = :sys.resume(monitor)
      await_end(ctx.chat, turn_ref)

      assert [%Message{role: "user"}, %Message{role: "assistant", content: "Done."}] =
               messages(ctx.chat)
    end

    test "a session revoked during the turn stops it with a notice", ctx do
      answer_next(tool_answer([call("c1", "agenttest_list_items", %{})]), fn ->
        Auth.delete_user_session_token(ctx.token)
      end)

      turn_ref = start!(ctx, "Hi")
      await_end(ctx.chat, turn_ref)

      # One model call only: round 2 found the session gone.
      assert_received {:model_request, _}
      refute_received {:model_request, _}
      refute_received {:agent_test_tool, _, _, _}

      assert %Message{role: "notice", error: "session_gone"} = List.last(messages(ctx.chat))
      assert unlocked?(ctx)
    end

    test "a user who loses `agent` during the turn is stopped", ctx do
      answer_next(tool_answer([call("c1", "agenttest_list_items", %{})]), fn ->
        :ok = revoke(ctx.role, "agent")
      end)

      turn_ref = start!(ctx, "Hi")
      await_end(ctx.chat, turn_ref)

      assert_received {:model_request, _}
      refute_received {:model_request, _}
      assert %Message{role: "notice", error: "forbidden"} = List.last(messages(ctx.chat))
    end
  end

  # ── a start that fails half-way ─────────────────────────────────────

  describe "a start that fails after the locks" do
    test "a start the monitor takes too late never runs and leaves nothing", ctx do
      Application.put_env(:phoenix_kit_agent, :turn_handshake_ms, 100)
      on_exit(fn -> Application.delete_env(:phoenix_kit_agent, :turn_handshake_ms) end)

      monitor = suspend_monitor()

      assert {:error, {:monitor_unavailable, :timeout}} =
               Turns.start(ctx.ref, false, ctx.chat.uuid, "Hi")

      assert unlocked?(ctx)
      assert messages(ctx.chat) == []

      # The monitor now takes the late start; the task it starts gets no
      # go-ahead and ends without a model call or a word in the chat.
      hang_next()
      :ok = :sys.resume(monitor)
      _ = :sys.get_state(monitor)

      for pid <- Task.Supervisor.children(PhoenixKitAgent.Turns.TaskSupervisor) do
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :not_started}}, 2_000
      end

      chat_uuid = ctx.chat.uuid
      assert_receive {:agent_turn_finished, ^chat_uuid, _turn_ref}, 2_000
      refute_received {:model_waiting, _}
      # The task's ready message went to an alias that was given up: the
      # caller's mailbox never sees it.
      refute_received {:turn_ready, _}
      assert messages(ctx.chat) == []
      assert unlocked?(ctx)

      # And the user's next turn, in another chat, runs alone.
      Application.delete_env(:phoenix_kit_agent, :turn_handshake_ms)
      other_chat = conversation_fixture(ctx.user)
      :ok = Conversations.subscribe(ctx.ref, other_chat.uuid, @me)
      assert {:ok, next} = Turns.start(ctx.ref, false, other_chat.uuid, "Again")
      assert_receive {:model_waiting, _}, 5_000

      :ok = Turns.stop(ctx.ref, false, other_chat.uuid)
      await_end(other_chat, next)
    end

    test "an exception after the locks are taken frees them", ctx do
      assert_raise FunctionClauseError, fn ->
        Turns.start(ctx.ref, false, ctx.chat.uuid, "Hi", [], request_context: :not_a_keyword)
      end

      assert unlocked?(ctx)
      assert messages(ctx.chat) == []
    end
  end

  # ── the AI request link of a stored message ────────────────────────

  describe "handle_ai_usage/1 for a message already stored" do
    defp attributed(request, message_uuid) do
      %{
        request
        | metadata:
            Map.put(request.metadata, "attribution", %{"agent_message_uuid" => message_uuid})
      }
    end

    defp answer!(ctx) do
      {:ok, message} =
        Conversations.add_turn_message(ctx.user.uuid, ctx.chat.uuid, %{
          role: "assistant",
          content: "x"
        })

      message
    end

    test "links the user's own message that has no request yet", ctx do
      message = answer!(ctx)
      request = ai_request_fixture(ctx.user, ctx.endpoint)

      assert :ok = PhoenixKitAgent.handle_ai_usage(attributed(request, message.uuid))
      assert Repo.get!(Message, message.uuid).ai_request_uuid == request.uuid
    end

    test "does not link a request of another user, nor relink a linked message", ctx do
      message = answer!(ctx)
      first = ai_request_fixture(ctx.user, ctx.endpoint)
      :ok = PhoenixKitAgent.handle_ai_usage(attributed(first, message.uuid))

      second = ai_request_fixture(ctx.user, ctx.endpoint)
      :ok = PhoenixKitAgent.handle_ai_usage(attributed(second, message.uuid))
      assert Repo.get!(Message, message.uuid).ai_request_uuid == first.uuid

      other = user_fixture("other")
      other_message = answer!(ctx)
      foreign = ai_request_fixture(other, ctx.endpoint)
      :ok = PhoenixKitAgent.handle_ai_usage(attributed(foreign, other_message.uuid))
      assert Repo.get!(Message, other_message.uuid).ai_request_uuid == nil
    end

    test "ignores a request without an agent attribution", ctx do
      message = answer!(ctx)
      request = ai_request_fixture(ctx.user, ctx.endpoint)

      assert :ok = PhoenixKitAgent.handle_ai_usage(request)
      assert :ok = PhoenixKitAgent.handle_ai_usage(attributed(request, "junk"))
      assert Repo.get!(Message, message.uuid).ai_request_uuid == nil
    end
  end

  # ── attachments ─────────────────────────────────────────────────────

  describe "attachments" do
    defp attachment!(user, chat, attrs) do
      %Attachment{user_uuid: user.uuid, conversation_uuid: chat.uuid}
      |> Attachment.changeset(
        Map.merge(
          %{filename: "notes.txt", content_type: "text/plain", size_bytes: 10, kind: "text"},
          attrs
        )
      )
      |> Repo.insert!()
    end

    test "a ready attachment of the chat is linked to the message and its text sent", ctx do
      att = attachment!(ctx.user, ctx.chat, %{status: "ready", extracted_text: "Sofa 3 pcs"})

      answer_next(text_answer("Read it."))
      turn_ref = start!(ctx, "See file", attachments: [att.uuid])
      await_end(ctx.chat, turn_ref)

      [user_msg | _] = messages(ctx.chat)
      assert Repo.get!(Attachment, att.uuid).message_uuid == user_msg.uuid

      assert_received {:model_request, body}
      assert [%{"role" => "user", "content" => content}] = chat_messages(body)
      assert content =~ "See file"
      assert content =~ "Sofa 3 pcs"
      assert content =~ "notes.txt"
    end

    test "an attachment of someone else, or not ready, is refused", ctx do
      other = user_fixture("other")
      other_chat = conversation_fixture(other)
      foreign = attachment!(other, other_chat, %{status: "ready", extracted_text: "x"})
      pending = attachment!(ctx.user, ctx.chat, %{status: "pending"})

      for uuid <- [foreign.uuid, pending.uuid, UUIDv7.generate(), "junk"] do
        assert {:error, :invalid_attachments} =
                 Turns.start(ctx.ref, false, ctx.chat.uuid, "Hi", [uuid])
      end

      assert messages(ctx.chat) == []
      assert unlocked?(ctx)
    end
  end

  # ── a start that fails after the locks (continued) ──────────────────

  describe "the deadline and the start" do
    test "the deadline of a task that never got its go-ahead writes nothing", ctx do
      # go_wait is 200 ms, the deadline 50 ms: before, the deadline killed the
      # orphan task first and wrote a `deadline` notice under its ref.
      Application.put_env(:phoenix_kit_agent, :turn_handshake_ms, 100)
      on_exit(fn -> Application.delete_env(:phoenix_kit_agent, :turn_handshake_ms) end)

      monitor = suspend_monitor()

      assert {:error, {:monitor_unavailable, :timeout}} =
               Turns.start(ctx.ref, false, ctx.chat.uuid, "Hi", [], deadline_ms: 50)

      hang_next()
      :ok = :sys.resume(monitor)
      _ = :sys.get_state(monitor)

      for pid <- Task.Supervisor.children(PhoenixKitAgent.Turns.TaskSupervisor) do
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :not_started}}, 2_000
      end

      chat_uuid = ctx.chat.uuid
      assert_receive {:agent_turn_finished, ^chat_uuid, _turn_ref}, 2_000
      _ = :sys.get_state(monitor)

      assert messages(ctx.chat) == []
      assert unlocked?(ctx)
    end
  end

  describe "the task supervisor while it restarts" do
    test "a start is refused and leaves nothing; the monitor stays up", ctx do
      monitor = Process.whereis(PhoenixKitAgent.Turns.Monitor)
      {name, pid} = hide_task_supervisor()

      assert {:error, {:not_started, :noproc}} =
               Turns.start(ctx.ref, false, ctx.chat.uuid, "Hi")

      assert unlocked?(ctx)
      assert messages(ctx.chat) == []
      assert Process.whereis(PhoenixKitAgent.Turns.Monitor) == monitor

      true = Process.register(pid, name)
      answer_next(text_answer("Back."))
      turn_ref = start!(ctx, "Hi")
      await_end(ctx.chat, turn_ref)
    end

    test "a turn that ends then is still ended: notice, locks freed, monitor up", ctx do
      monitor = Process.whereis(PhoenixKitAgent.Turns.Monitor)

      hang_next()
      turn_ref = start!(ctx, "Hi")
      assert_receive {:model_waiting, _pid}, 5_000
      [{task, _}] = Registry.lookup(PhoenixKitAgent.Turns.Registry, turn_ref)

      {name, pid} = hide_task_supervisor()
      Process.exit(task, :kill)
      await_end(ctx.chat, turn_ref)
      true = Process.register(pid, name)

      assert Process.whereis(PhoenixKitAgent.Turns.Monitor) == monitor
      assert %Message{role: "notice", error: "interrupted"} = List.last(messages(ctx.chat))
      assert unlocked?(ctx)
    end
  end

  # ── "Stop" for a turn on another node (spec §6.1) ───────────────────

  describe "stop on another node" do
    # The topic of a turn, as the spec names it: the stop request carries
    # the turn ref and nothing else.
    defp turn_topic(turn_ref), do: "agent:turn:" <> turn_ref

    # In the turn's task (a model answer's `before`): this node's registry
    # forgets the task, as if it ran on another node.
    defp leave_registry do
      registry = PhoenixKitAgent.Turns.Registry
      for key <- Registry.keys(registry, self()), do: Registry.unregister(registry, key)
      :ok
    end

    defp lock_chat(chat, turn_ref, busy_since) do
      Repo.update_all(from(c in Conversation, where: c.uuid == ^chat.uuid),
        set: [busy_since: busy_since, busy_turn_ref: turn_ref]
      )
    end

    defp pubsub_subscribers(topic),
      do: for({pid, _} <- Registry.lookup(:phoenix_kit_internal_pubsub, topic), do: pid)

    test "a turn this node does not run is asked over PubSub, and its node stops it", ctx do
      answer_next(tool_answer([call("c1", "agenttest_list_items", %{})]), &leave_registry/0)
      hang_next()

      turn_ref = start!(ctx, "Hi")
      assert_receive {:model_waiting, _pid}, 5_000
      assert Registry.lookup(PhoenixKitAgent.Turns.Registry, turn_ref) == []

      # Another subscriber of the topic, as the monitor of another node is.
      :ok = PubSub.subscribe(turn_topic(turn_ref))

      assert :ok = Turns.stop(ctx.ref, false, ctx.chat.uuid, turn_ref)
      assert_receive {:agent_stop_turn, ^turn_ref}, 1_000
      await_end(ctx.chat, turn_ref)

      # Stopped, not interrupted: no answer kept, no notice, locks freed.
      roles = Enum.map(messages(ctx.chat), & &1.role)
      assert roles == ["user", "assistant", "tool"]
      assert unlocked?(ctx)
    end

    test "the monitor listens to the topic of each turn it runs, until the turn ends", ctx do
      hang_next()
      turn_ref = start!(ctx, "Hi")
      assert_receive {:model_waiting, _pid}, 5_000

      monitor = Process.whereis(PhoenixKitAgent.Turns.Monitor)
      assert monitor in pubsub_subscribers(turn_topic(turn_ref))

      :ok =
        PubSub.broadcast(turn_topic(turn_ref), {:agent_stop_turn, turn_ref})

      await_end(ctx.chat, turn_ref)

      assert [%Message{role: "user"}] = messages(ctx.chat)
      assert unlocked?(ctx)
      _ = :sys.get_state(monitor)
      refute monitor in pubsub_subscribers(turn_topic(turn_ref))
    end

    test "a stop request for another turn ref stops nothing", ctx do
      hang_next()
      turn_ref = start!(ctx, "Hi")
      assert_receive {:model_waiting, _pid}, 5_000

      other = UUIDv7.generate()
      :ok = PubSub.broadcast(turn_topic(turn_ref), {:agent_stop_turn, other})
      :ok = PubSub.broadcast(turn_topic(other), {:agent_stop_turn, other})
      :ok = PubSub.broadcast(turn_topic(turn_ref), {:agent_stop_turn, 42})
      turns = :sys.get_state(PhoenixKitAgent.Turns.Monitor)

      # The monitor has taken the three requests: none of them asked the turn
      # to stop, and it is still running after a stop's grace period.
      assert [%{stop: nil}] = for({_ref, %{turn: %{turn_ref: ^turn_ref}} = e} <- turns, do: e)
      refute_receive {:agent_turn_finished, _, ^turn_ref}, Monitor.stop_grace_ms() + 300
      assert [{_pid, _}] = Registry.lookup(PhoenixKitAgent.Turns.Registry, turn_ref)

      :ok = Turns.stop(ctx.ref, false, ctx.chat.uuid, turn_ref)
      await_end(ctx.chat, turn_ref)
    end

    test "a stop with a turn ref the chat's lock does not hold asks no node", ctx do
      turn_ref = UUIDv7.generate()
      lock_chat(ctx.chat, turn_ref, DateTime.utc_now())
      other = UUIDv7.generate()
      :ok = PubSub.subscribe(turn_topic(turn_ref))
      :ok = PubSub.subscribe(turn_topic(other))

      assert {:error, :not_running} = Turns.stop(ctx.ref, false, ctx.chat.uuid, other)
      refute_received {:agent_stop_turn, _}
    end

    test "someone else's session or an impersonated one asks no node", ctx do
      turn_ref = UUIDv7.generate()
      lock_chat(ctx.chat, turn_ref, DateTime.utc_now())
      :ok = PubSub.subscribe(turn_topic(turn_ref))

      other = user_with(["agent", "dashboard"], "other")
      {other_ref, _} = session_fixture(other)

      assert {:error, :not_found} = Turns.stop(other_ref, false, ctx.chat.uuid, turn_ref)
      assert {:error, :not_found} = Turns.stop(other_ref, false, ctx.chat.uuid)
      assert {:error, :impersonated} = Turns.stop(ctx.ref, true, ctx.chat.uuid, turn_ref)

      Auth.delete_user_session_token(ctx.token)
      assert {:error, _revoked} = Turns.stop(ctx.ref, false, ctx.chat.uuid, turn_ref)

      refute_received {:agent_stop_turn, _}
    end

    test "a fresh lock with no task here: the request goes out with the ref only", ctx do
      turn_ref = UUIDv7.generate()
      lock_chat(ctx.chat, turn_ref, DateTime.utc_now())
      :ok = PubSub.subscribe(turn_topic(turn_ref))

      assert :ok = Turns.stop(ctx.ref, false, ctx.chat.uuid)
      assert_receive message, 1_000
      assert message == {:agent_stop_turn, turn_ref}
    end

    test "a lock past its TTL is no turn anywhere: not running, nobody asked", ctx do
      turn_ref = UUIDv7.generate()
      ttl_s = Config.turn_deadline_s() + 60
      lock_chat(ctx.chat, turn_ref, DateTime.add(DateTime.utc_now(), -(ttl_s + 30), :second))
      :ok = PubSub.subscribe(turn_topic(turn_ref))

      assert {:error, :not_running} = Turns.stop(ctx.ref, false, ctx.chat.uuid, turn_ref)
      refute_received {:agent_stop_turn, _}
    end
  end

  describe "stop on another node, with no PubSub" do
    # The PubSub's registry not there, as when it is restarting: its table
    # goes by another name for the test.
    defp without_pubsub(fun) do
      name = :phoenix_kit_internal_pubsub
      away = :phoenix_kit_internal_pubsub_away
      :ets.rename(name, away)

      try do
        fun.()
      after
        :ets.rename(away, name)
      end
    end

    test "the request is refused, not raised", ctx do
      turn_ref = UUIDv7.generate()

      Repo.update_all(from(c in Conversation, where: c.uuid == ^ctx.chat.uuid),
        set: [busy_since: DateTime.utc_now(), busy_turn_ref: turn_ref]
      )

      assert {:error, :not_running} = without_pubsub(fn -> Monitor.broadcast_stop(turn_ref) end)

      assert {:error, :not_running} =
               without_pubsub(fn -> Turns.stop(ctx.ref, false, ctx.chat.uuid, turn_ref) end)
    end
  end

  describe "the monitor while it restarts" do
    test "a stop is refused, not raised; the turn runs on", ctx do
      hang_next()
      turn_ref = start!(ctx, "Hi")
      assert_receive {:model_waiting, _pid}, 5_000

      name = PhoenixKitAgent.Turns.Monitor
      monitor = Process.whereis(name)
      true = Process.unregister(name)

      on_exit(fn ->
        if Process.alive?(monitor) and Process.whereis(name) == nil,
          do: Process.register(monitor, name)
      end)

      result = Turns.stop(ctx.ref, false, ctx.chat.uuid, turn_ref)
      true = Process.register(monitor, name)

      assert result == {:error, :not_running}
      assert :ok = Turns.stop(ctx.ref, false, ctx.chat.uuid, turn_ref)
      await_end(ctx.chat, turn_ref)
    end
  end

  # ── a chat deleted while its turn runs ──────────────────────────────

  describe "a chat deleted mid-turn" do
    # Has the turn's task tell the test how it ended: called in that task (a
    # model answer's `before`), it returns once a watcher monitors it.
    defp watch_turn_task(test) do
      task = self()

      spawn(fn ->
        ref = Process.monitor(task)
        send(task, :watching)

        receive do
          {:DOWN, ^ref, :process, ^task, reason} -> send(test, {:turn_task_down, reason})
        end
      end)

      receive do
        :watching -> :ok
      end
    end

    test "the turn ends quietly: no notice, no further model call", ctx do
      test = self()

      answer_next(tool_answer([call("c1", "agenttest_list_items", %{})]), fn ->
        watch_turn_task(test)

        Repo.update_all(from(c in Conversation, where: c.uuid == ^ctx.chat.uuid),
          set: [status: "deleted"]
        )
      end)

      {turn_ref, logs} =
        LogProbe.capture(fn ->
          turn_ref = start!(ctx, "Hi")
          await_end(ctx.chat, turn_ref)
          turn_ref
        end)

      assert is_binary(turn_ref)
      assert_received {:model_request, _}
      refute_received {:model_request, _}
      refute_received {:agent_test_tool, _, _, _}

      assert [%Message{role: "user"}] = messages(ctx.chat)
      assert unlocked?(ctx)
      assert_receive {:turn_task_down, {:shutdown, :chat_gone}}, 5_000
      refute Enum.any?(logs, &(&1 =~ "terminating"))
      refute Enum.any?(logs, &(&1 =~ "a turn crashed"))
    end

    test "deleted after a round was stored: the next round does not call the model", ctx do
      # The chat is deleted in the same transaction that stores the tool
      # result, so every write of the round goes through and only the check
      # before the next round sees the chat gone.
      Repo.query!("""
      CREATE FUNCTION pg_temp.agent_delete_chat_on_tool() RETURNS trigger AS $$
      BEGIN
        IF NEW.role = 'tool' THEN
          UPDATE phoenix_kit_agent_conversations SET status = 'deleted'
          WHERE uuid = NEW.conversation_uuid;
        END IF;
        RETURN NEW;
      END $$ LANGUAGE plpgsql
      """)

      Repo.query!("""
      CREATE TRIGGER agent_delete_chat_on_tool AFTER INSERT ON phoenix_kit_agent_messages
      FOR EACH ROW EXECUTE FUNCTION pg_temp.agent_delete_chat_on_tool()
      """)

      test = self()

      answer_next(tool_answer([call("c1", "agenttest_list_items", %{})]), fn ->
        watch_turn_task(test)
      end)

      {turn_ref, logs} =
        LogProbe.capture(fn ->
          turn_ref = start!(ctx, "Hi")
          await_end(ctx.chat, turn_ref)
          turn_ref
        end)

      assert is_binary(turn_ref)
      assert_received {:model_request, _}
      refute_received {:model_request, _}
      assert_receive {:turn_task_down, {:shutdown, :chat_gone}}, 5_000

      assert [%Message{role: "user"}, %Message{role: "assistant"}, %Message{role: "tool"}] =
               messages(ctx.chat)

      assert unlocked?(ctx)
      refute Enum.any?(logs, &(&1 =~ "a turn crashed"))
    end
  end

  # ── what the model answers ──────────────────────────────────────────

  describe "the model's answer" do
    test "an answer of NUL characters only is the empty-answer notice", ctx do
      answer_next(text_answer(<<0, 0>> <> " " <> <<0>>))

      turn_ref = start!(ctx, "Hi")
      await_end(ctx.chat, turn_ref)

      assert [%Message{role: "user"}, %Message{role: "notice", error: "empty_answer"}] =
               messages(ctx.chat)
    end

    test "a tool call without a name is not run, stored or replayed", ctx do
      nameless = %{"id" => "n1", "type" => "function", "function" => %{"arguments" => "{}"}}
      blank = call("n2", " ", %{})

      answer_next(
        tool_answer([nameless, blank, call("c1", "agenttest_list_items", %{"query" => "q"})])
      )

      answer_next(text_answer("Done."))

      turn_ref = start!(ctx, "List")
      await_end(ctx.chat, turn_ref)

      assert_received {:model_request, _}
      assert_received {:model_request, second}

      assistant = Enum.find(second["messages"], &(&1["role"] == "assistant"))
      assert Enum.map(assistant["tool_calls"], & &1["id"]) == ["c1"]
      refute Enum.any?(assistant["tool_calls"], &(&1["function"]["name"] in ["", nil]))

      assert Enum.map(
               Enum.filter(second["messages"], &(&1["role"] == "tool")),
               & &1["tool_call_id"]
             ) ==
               ["c1"]

      call_msg = Enum.find(messages(ctx.chat), &(&1.role == "assistant" and &1.tool_calls))
      assert Enum.map(call_msg.tool_calls, & &1["id"]) == ["c1"]

      assert [%Message{tool_call_id: "c1"}] =
               Enum.filter(messages(ctx.chat), &(&1.role == "tool"))
    end

    test "an answer with neither text nor a named tool call is a notice, not an empty answer",
         ctx do
      empty = %{
        "model" => @model,
        "choices" => [%{"message" => %{"role" => "assistant", "content" => nil}}],
        "usage" => %{"prompt_tokens" => 7, "completion_tokens" => 0, "total_tokens" => 7}
      }

      answer_next(empty)
      first = start!(ctx, "Hi")
      await_end(ctx.chat, first)

      assert [%Message{role: "user"}, %Message{role: "notice", error: "empty_answer"} = notice] =
               messages(ctx.chat)

      assert is_binary(notice.ai_request_uuid)
      assert notice.input_tokens == 7

      nameless = %{"id" => "n1", "type" => "function", "function" => %{"arguments" => "{}"}}
      answer_next(tool_answer([nameless]))
      second = start!(ctx, "Again")
      await_end(ctx.chat, second)

      assert %Message{role: "notice", error: "empty_answer"} = List.last(messages(ctx.chat))
      refute Enum.any?(messages(ctx.chat), &(&1.role == "assistant"))
      assert unlocked?(ctx)
    end

    test "NUL characters in the text, the answer or a tool result are cut before storing",
         ctx do
      answer_next(tool_answer([call("c1", "agenttest_list_items", %{"say" => "ch\u0000air"})]))
      answer_next(text_answer("Fo\u0000und."))

      turn_ref = start!(ctx, "Li\u0000st")
      await_end(ctx.chat, turn_ref)

      assert [user_msg, _call, tool_msg, answer_msg] = messages(ctx.chat)
      assert user_msg.content == "List"
      assert tool_msg.tool_result == %{"items" => ["chair"]}
      assert answer_msg.content == "Found."
      assert unlocked?(ctx)
    end
  end

  # ── the size of one turn (spec §6.4) ────────────────────────────────

  describe "the transcript of one turn" do
    test "older results of the turn give way to a stub once the turn's results pass the budget",
         ctx do
      # One result is at most 500 characters, so the turn keeps at most
      # 10 × 500 characters of results; the newest round is always whole.
      {:ok, _} = Settings.update_setting("agent_tool_result_chars", "500")

      round = fn tag ->
        tool_answer(
          for i <- 1..10, do: call("#{tag}#{i}", "agenttest_list_items", %{"size" => 400})
        )
      end

      answer_next(round.("a"))
      answer_next(round.("b"))
      answer_next(text_answer("Done."))

      turn_ref = start!(ctx, "Big")
      await_end(ctx.chat, turn_ref)

      assert_received {:model_request, _}
      assert_received {:model_request, _}
      assert_received {:model_request, third}

      results = Enum.filter(third["messages"], &(&1["role"] == "tool"))
      assert length(results) == 20

      {older, newest} = Enum.split(results, 10)
      kept = Enum.reject(older, &Map.has_key?(Jason.decode!(&1["content"]), "omitted"))
      stubbed = older -- kept

      # 10 × ~414 characters of the newest round leave room for two older
      # results: the two newest of them are kept, the eight before them stubbed.
      assert length(stubbed) == 8
      assert stubbed == Enum.take(older, 8)
      assert kept == Enum.take(older, -2)
      assert Enum.all?(newest, &(Jason.decode!(&1["content"])["items"] != nil))

      for stub <- stubbed do
        assert %{"omitted" => true, "hint" => _} = Jason.decode!(stub["content"])
      end

      assert (kept ++ newest) |> Enum.map(&String.length(&1["content"])) |> Enum.sum() <= 5_000

      # The database keeps every result as it was.
      assert 20 ==
               messages(ctx.chat)
               |> Enum.filter(&(&1.role == "tool"))
               |> Enum.count(&is_list(&1.tool_result["items"]))
    end
  end

  # ── nothing of a turn reaches the log (spec §8.2) ───────────────────

  # ── the limits (spec §7.3, §7.4) ────────────────────────────────────

  describe "the limits" do
    defp limits!(user, attrs) do
      Repo.insert!(struct(UserSettings, Map.merge(%{user_uuid: user.uuid}, Map.new(attrs))))
    end

    defp spend!(user, endpoint, cost) do
      Repo.insert!(%PhoenixKitAI.Request{
        endpoint_uuid: endpoint.uuid,
        user_uuid: user.uuid,
        model: endpoint.model,
        status: "success",
        request_type: "vision",
        cost: journal_cost(cost),
        metadata: %{"source" => "agent"},
        inserted_at: DateTime.truncate(DateTime.utc_now(), :second)
      })
    end

    defp notifications_of(user) do
      Repo.all(
        from(n in PhoenixKit.Notifications.Notification, where: n.recipient_uuid == ^user.uuid)
      )
    end

    defp answer_with_cost(answer, usd), do: put_in(answer, ["usage", "cost"], usd)

    test "a used-up turn limit: no model call, a notice in the chat, the locks freed", ctx do
      limits!(ctx.user, daily_turn_limit: 1)

      answer_next(text_answer("First answer."))
      turn_ref = start!(ctx, "First")
      await_end(ctx.chat, turn_ref)
      assert_received {:model_request, _}

      assert {:error, {:limit_reached, :daily_turns}} =
               Turns.start(ctx.ref, false, ctx.chat.uuid, "Second")

      refute_received {:model_request, _}
      assert unlocked?(ctx)

      assert [
               %Message{role: "user", content: "First"},
               %Message{role: "assistant"},
               %Message{role: "notice", error: "daily_turn_limit", turn_ref: notice_ref}
             ] = messages(ctx.chat)

      assert is_binary(notice_ref) and notice_ref != turn_ref

      assert [%{metadata: %{"dedupe_key" => "agent:limit:daily_turns:" <> _}}] =
               notifications_of(ctx.user)
    end

    test "money in the AI journal, a vision call no message records, blocks the turn", ctx do
      spend!(ctx.user, ctx.endpoint, 1_000_000)

      assert {:error, {:limit_reached, :daily_cost}} =
               Turns.start(ctx.ref, false, ctx.chat.uuid, "Hi")

      refute_received {:model_request, _}
      assert [%Message{role: "notice", error: "daily_cost_limit"}] = messages(ctx.chat)
      assert unlocked?(ctx)
    end

    test "the watchers hear of it once, and only with notify_on_limit", ctx do
      owner = owner_fixture()
      limits!(ctx.user, daily_turn_limit: 0)

      for _ <- 1..2 do
        assert {:error, {:limit_reached, :daily_turns}} =
                 Turns.start(ctx.ref, false, ctx.chat.uuid, "Hi")
      end

      assert notifications_of(owner) == []
      assert [_one] = notifications_of(ctx.user)

      # Switched on later the same day: the watchers were not told of this
      # period yet, so they are now — once; the user is not told again.
      Repo.update_all(from(s in UserSettings, where: s.user_uuid == ^ctx.user.uuid),
        set: [notify_on_limit: true]
      )

      for _ <- 1..2 do
        assert {:error, {:limit_reached, :daily_turns}} =
                 Turns.start(ctx.ref, false, ctx.chat.uuid, "Hi")
      end

      assert [%{metadata: %{"notification_text" => text}}] = notifications_of(owner)
      assert text =~ ctx.user.email
      assert [_one] = notifications_of(ctx.user)
    end

    test "a refusal repeated in one period leaves one notice in the chat", ctx do
      limits!(ctx.user, daily_turn_limit: 0)
      other_chat = conversation_fixture(ctx.user)

      for _ <- 1..3 do
        assert {:error, {:limit_reached, :daily_turns}} =
                 Turns.start(ctx.ref, false, ctx.chat.uuid, "Hi")
      end

      assert [%Message{role: "notice", error: "daily_turn_limit"}] = messages(ctx.chat)

      # Another chat says it once too.
      assert {:error, {:limit_reached, :daily_turns}} =
               Turns.start(ctx.ref, false, other_chat.uuid, "Hi")

      assert [%Message{role: "notice", error: "daily_turn_limit"}] = messages(other_chat)

      # Another limit is another notice.
      Repo.update_all(from(s in UserSettings, where: s.user_uuid == ^ctx.user.uuid),
        set: [daily_turn_limit: 10]
      )

      spend!(ctx.user, ctx.endpoint, 1_000_000)

      assert {:error, {:limit_reached, :daily_cost}} =
               Turns.start(ctx.ref, false, ctx.chat.uuid, "Hi")

      assert Enum.map(messages(ctx.chat), & &1.error) == ["daily_turn_limit", "daily_cost_limit"]
      assert unlocked?(ctx)
    end

    test "a notice of an earlier period does not stand for this one", ctx do
      limits!(ctx.user, daily_turn_limit: 0)
      {day_start, _} = PhoenixKitAgent.Spend.windows().day

      {:ok, _} =
        Conversations.add_turn_message(ctx.user.uuid, ctx.chat.uuid, %{
          turn_ref: "earlier",
          role: "notice",
          content: "You have used all your assistant turns for today.",
          error: "daily_turn_limit"
        })

      Repo.update_all(from(m in Message, where: m.conversation_uuid == ^ctx.chat.uuid),
        set: [inserted_at: DateTime.add(day_start, -60, :second)]
      )

      assert {:error, {:limit_reached, :daily_turns}} =
               Turns.start(ctx.ref, false, ctx.chat.uuid, "Hi")

      assert [%Message{turn_ref: "earlier"}, %Message{error: "daily_turn_limit"}] =
               messages(ctx.chat)
    end

    test "with notify_on_limit the watchers hear of it once a period", ctx do
      owner = owner_fixture()
      limits!(ctx.user, daily_turn_limit: 0, notify_on_limit: true)

      for _ <- 1..3 do
        assert {:error, {:limit_reached, :daily_turns}} =
                 Turns.start(ctx.ref, false, ctx.chat.uuid, "Hi")
      end

      assert [%{metadata: %{"notification_text" => text}}] = notifications_of(owner)
      assert text =~ ctx.user.email
    end

    test "the limits are checked under the locks: a turn in flight is :turn_in_flight", ctx do
      other_chat = conversation_fixture(ctx.user)
      :ok = Conversations.subscribe(ctx.ref, other_chat.uuid, @me)

      hang_next()
      turn_ref = start!(ctx, "First")
      assert_receive {:model_waiting, _pid}, 5_000

      # What the turn in flight is spending reaches the limit.
      spend!(ctx.user, ctx.endpoint, 1_000_000)

      assert {:error, :turn_in_flight} = Turns.start(ctx.ref, false, other_chat.uuid, "Second")
      assert messages(other_chat) == []
      assert Repo.all(PhoenixKitAgent.Schemas.LimitEvent) == []

      :ok = Turns.stop(ctx.ref, false, ctx.chat.uuid)
      await_end(ctx.chat, turn_ref)

      assert {:error, {:limit_reached, :daily_cost}} =
               Turns.start(ctx.ref, false, other_chat.uuid, "Second")
    end

    test "two starts at the edge of the limit give one turn", ctx do
      limits!(ctx.user, daily_turn_limit: 1)
      other_chat = conversation_fixture(ctx.user)
      :ok = Conversations.subscribe(ctx.ref, other_chat.uuid, @me)

      hang_next()

      results =
        [ctx.chat.uuid, other_chat.uuid]
        |> Enum.map(fn chat_uuid ->
          Task.async(fn -> {chat_uuid, Turns.start(ctx.ref, false, chat_uuid, "Go")} end)
        end)
        |> Task.await_many(10_000)

      assert [{started_chat, {:ok, turn_ref}}] =
               Enum.filter(results, &match?({_, {:ok, _}}, &1))

      assert [{_, {:error, refusal}}] = Enum.reject(results, &match?({_, {:ok, _}}, &1))
      assert refusal in [:turn_in_flight, :conversation_busy]

      assert_receive {:model_waiting, _pid}, 5_000
      :ok = Turns.stop(ctx.ref, false, started_chat)
      assert_receive {:agent_turn_finished, ^started_chat, ^turn_ref}, 5_000

      for chat_uuid <- [ctx.chat.uuid, other_chat.uuid] do
        assert {:error, {:limit_reached, :daily_turns}} =
                 Turns.start(ctx.ref, false, chat_uuid, "Again")
      end
    end

    test "a turn that started under its limit plays to its end", ctx do
      limits!(ctx.user, daily_cost_limit_micro_usd: 1_000)

      answer_next(answer_with_cost(tool_answer([call("c1", "agenttest_list_items", %{})]), 0.005))

      answer_next(answer_with_cost(text_answer("Done."), 0.005))

      turn_ref = start!(ctx, "Hi")
      await_end(ctx.chat, turn_ref)

      assert %Message{role: "assistant", content: "Done."} = List.last(messages(ctx.chat))

      assert PhoenixKitAgent.Spend.for_users([ctx.user.uuid])[ctx.user.uuid].day_micro_usd ==
               10_000

      assert {:error, {:limit_reached, :daily_cost}} =
               Turns.start(ctx.ref, false, ctx.chat.uuid, "More")
    end

    test "an answer's cost in dollars is kept on its message in whole micro-dollars", ctx do
      answer_next(answer_with_cost(tool_answer([call("c1", "agenttest_list_items", %{})]), 0.005))
      answer_next(answer_with_cost(text_answer("Done."), 0.0000025))

      turn_ref = start!(ctx, "Hi")
      await_end(ctx.chat, turn_ref)

      assert [5_000, 3] =
               for(
                 %Message{role: "assistant", cost_micro_usd: cost} <- messages(ctx.chat),
                 do: cost
               )
    end

    test "an endpoint without a cost: the money limit does not act, the turn limit does", ctx do
      direct = endpoint_fixture(%{provider: "deepseek", model: "deepseek-chat"})

      limits!(ctx.user,
        endpoint_uuid: direct.uuid,
        daily_cost_limit_micro_usd: 0,
        daily_turn_limit: 1
      )

      answer_next(text_answer("Fine."))
      turn_ref = start!(ctx, "Hi")
      await_end(ctx.chat, turn_ref)

      assert %Message{role: "assistant", content: "Fine.", cost_micro_usd: nil} =
               List.last(messages(ctx.chat))

      assert {:error, {:limit_reached, :daily_turns}} =
               Turns.start(ctx.ref, false, ctx.chat.uuid, "Again")
    end

    test "the AI budget used up: a notice, and one signal to the watchers, from the AI module",
         ctx do
      owner = owner_fixture()
      {:ok, _} = PhoenixKitAI.Budget.set_limit(:user_calls, 1)
      ai_request_fixture(ctx.user, ctx.endpoint)

      for _ <- 1..2 do
        turn_ref = start!(ctx, "Hi")
        await_end(ctx.chat, turn_ref)

        assert %Message{role: "notice", error: "budget_exceeded"} =
                 List.last(messages(ctx.chat))
      end

      refute_received {:model_request, _}

      # Told once, by phoenix_kit_ai (a link to its pages), not by the module
      # (whose limit notices link to the assistant's spending).
      assert [%{metadata: %{"notification_link" => link}}] = notifications_of(owner)
      assert link =~ "/admin/ai/"
      refute link =~ "/admin/agent/"
      assert notifications_of(ctx.user) == []

      assert Repo.all(
               from(e in PhoenixKitAgent.Schemas.LimitEvent, where: e.limit_kind == "ai_budget")
             ) == []
    end
  end

  # ── stopping between steps ──────────────────────────────────────────

  describe "stop and deadline let a model call finish" do
    setup do
      Application.put_env(:phoenix_kit_agent, :turn_stop_grace_ms, 5_000)
      on_exit(fn -> Application.put_env(:phoenix_kit_agent, :turn_stop_grace_ms, 200) end)
      :ok
    end

    # The next model request waits for `:answer`, then answers with a cost.
    defp answer_on_demand(answer) do
      test = self()

      Req.Test.expect(@stub, fn conn ->
        send(test, {:model_waiting, self()})

        receive do
          :answer -> Req.Test.json(conn, put_in(answer, ["usage", "cost"], 0.002))
        end
      end)
    end

    defp journal(user) do
      Repo.all(
        from(r in PhoenixKitAI.Request,
          where: r.user_uuid == ^user.uuid and fragment("?->>'source' = 'agent'", r.metadata)
        )
      )
    end

    test "stop: the call finishes and its cost is in the journal; the answer is not kept",
         ctx do
      answer_on_demand(tool_answer([call("c1", "agenttest_list_items", %{})]))
      turn_ref = start!(ctx, "Hi")
      assert_receive {:model_waiting, stub}, 5_000
      [{task, _}] = Registry.lookup(PhoenixKitAgent.Turns.Registry, turn_ref)
      down = Process.monitor(task)

      assert :ok = Turns.stop(ctx.ref, false, ctx.chat.uuid)
      _ = :sys.get_state(PhoenixKitAgent.Turns.Monitor)
      send(stub, :answer)

      assert_receive {:DOWN, ^down, :process, ^task, {:shutdown, :stopped}}, 5_000
      await_end(ctx.chat, turn_ref)

      assert [%Message{role: "user"}] = messages(ctx.chat)
      assert [%{cost: cost}] = journal(ctx.user)
      assert Decimal.equal?(cost, "0.002")
      refute_received {:agent_test_tool, _, _, _}
      assert unlocked?(ctx)
    end

    test "the deadline: the call finishes, then the deadline notice", ctx do
      answer_on_demand(text_answer("Late."))
      turn_ref = start!(ctx, "Hi", deadline_ms: 100)
      assert_receive {:model_waiting, stub}, 5_000
      [{task, _}] = Registry.lookup(PhoenixKitAgent.Turns.Registry, turn_ref)
      down = Process.monitor(task)

      monitor = Process.whereis(PhoenixKitAgent.Turns.Monitor)

      wait_until(fn ->
        monitor |> :sys.get_state() |> Map.values() |> Enum.any?(&(&1.stop == :deadline))
      end)

      send(stub, :answer)
      assert_receive {:DOWN, ^down, :process, ^task, {:shutdown, :deadline}}, 5_000
      await_end(ctx.chat, turn_ref)

      assert [%Message{role: "user"}, %Message{role: "notice", error: "deadline"}] =
               messages(ctx.chat)

      assert [%{cost: cost}] = journal(ctx.user)
      assert Decimal.equal?(cost, "0.002")
      assert unlocked?(ctx)
    end

    test "a stop that comes while the model answers: no answer kept, no tool run", ctx do
      answer_next(tool_answer([call("c1", "agenttest_list_items", %{})]), fn ->
        :ok = Turns.stop(ctx.ref, false, ctx.chat.uuid)
        _ = :sys.get_state(PhoenixKitAgent.Turns.Monitor)
      end)

      turn_ref = start!(ctx, "Hi")
      await_end(ctx.chat, turn_ref)

      assert [%Message{role: "user"}] = messages(ctx.chat)
      refute_received {:agent_test_tool, _, _, _}
    end

    test "a turn that does not stop within the grace period is killed", ctx do
      Application.put_env(:phoenix_kit_agent, :turn_stop_grace_ms, 100)

      hang_next()
      turn_ref = start!(ctx, "Hi")
      assert_receive {:model_waiting, _stub}, 5_000
      [{task, _}] = Registry.lookup(PhoenixKitAgent.Turns.Registry, turn_ref)
      down = Process.monitor(task)

      :ok = Turns.stop(ctx.ref, false, ctx.chat.uuid)
      assert_receive {:DOWN, ^down, :process, ^task, :killed}, 5_000
      await_end(ctx.chat, turn_ref)

      assert [%Message{role: "user"}] = messages(ctx.chat)
      assert unlocked?(ctx)
    end

    test "a deadline after a stop does not turn it into a deadline", ctx do
      Application.put_env(:phoenix_kit_agent, :turn_stop_grace_ms, 300)

      hang_next()
      turn_ref = start!(ctx, "Hi", deadline_ms: 150)
      assert_receive {:model_waiting, _stub}, 5_000

      :ok = Turns.stop(ctx.ref, false, ctx.chat.uuid)
      await_end(ctx.chat, turn_ref)

      assert [%Message{role: "user"}] = messages(ctx.chat)
    end
  end

  describe "a stop that arrives during a tool call" do
    test "the next tool call of the same answer does not run", ctx do
      chat_uuid = ctx.chat.uuid
      ref = ctx.ref

      Application.put_env(:phoenix_kit_agent, :test_tool_hook, fn
        _name, %{"say" => "first"} ->
          :ok = Turns.stop(ref, false, chat_uuid)
          # The monitor has passed the request on to this task.
          _ = :sys.get_state(Monitor)
          :ok

        _name, _input ->
          :ok
      end)

      on_exit(fn -> Application.delete_env(:phoenix_kit_agent, :test_tool_hook) end)

      answer_next(
        tool_answer([
          call("c1", "agenttest_list_items", %{"say" => "first"}),
          call("c2", "agenttest_list_items", %{"say" => "second"})
        ])
      )

      turn_ref = start!(ctx, "Two tools")
      await_end(ctx.chat, turn_ref)

      assert_received {:agent_test_tool, "agenttest.list_items", %{"say" => "first"}, _}
      refute_received {:agent_test_tool, _, %{"say" => "second"}, _}
      assert_received {:model_request, _}
      refute_received {:model_request, _}

      # A stop asked for by the user writes no notice.
      assert [
               %Message{role: "user"},
               %Message{role: "assistant"},
               %Message{role: "tool", tool_call_id: "c1"}
             ] = messages(ctx.chat)

      assert unlocked?(ctx)
    end
  end

  describe "a lock taken over before the tool calls" do
    test "the tools are not run; the turn ends with a notice", ctx do
      answer_next(tool_answer([call("c1", "agenttest_list_items", %{})]), fn ->
        Repo.update_all(from(c in Conversation, where: c.uuid == ^ctx.chat.uuid),
          set: [busy_since: DateTime.utc_now(), busy_turn_ref: "newer"]
        )
      end)

      turn_ref = start!(ctx, "Hi")
      await_end(ctx.chat, turn_ref)

      refute_received {:agent_test_tool, _, _, _}
      refute Enum.any?(messages(ctx.chat), &(&1.role == "tool"))
      assert %Message{role: "notice", error: "lock_lost"} = List.last(messages(ctx.chat))
    end
  end

  describe "the log" do
    @secret "S3CRET-7F2A"

    defp refute_leak(logs, result \\ nil) do
      for line <- logs, do: refute(line =~ @secret, "leaked to the log: " <> line)
      refute inspect(result, limit: :infinity, printable_limit: :infinity) =~ @secret
    end

    # phoenix_kit_ai itself logs the provider's error message (a warning in
    # `PhoenixKitAI.Completion.handle_error_status/2`); a provider that echoed
    # the prompt there would leak it — that is phoenix_kit_ai's to fix.
    test "the personal instructions, the admin's prompt and a failing addendum are not logged",
         ctx do
      {:ok, _} = UserConfig.put_personal_instructions(ctx.ref, "Personal " <> @secret, @me)

      {:ok, _, _} =
        UserConfig.admin_update(scope_of(owner_fixture()), ctx.user.uuid, %{
          "system_prompt" => "Admin " <> @secret
        })

      Application.put_env(:phoenix_kit_agent, :prompt_addendum, {Addenda, :raises})
      on_exit(fn -> Application.delete_env(:phoenix_kit_agent, :prompt_addendum) end)
      answer_next(text_answer("ok"))

      {_, logs} =
        LogProbe.capture(fn ->
          turn_ref = start!(ctx, "Hi")
          await_end(ctx.chat, turn_ref)
        end)

      refute_leak(logs)
      for line <- logs, do: refute(line =~ "addendum boom", "leaked to the log: " <> line)
      assert Enum.any?(logs, &(&1 =~ "prompt addendum skipped"))
    end

    test "a model error logs nothing of the user's text", ctx do
      error_next(500)

      {_, logs} =
        LogProbe.capture(fn ->
          turn_ref = start!(ctx, "Find " <> @secret)
          await_end(ctx.chat, turn_ref)
        end)

      refute_leak(logs)
      assert %Message{role: "notice", error: "api_error"} = List.last(messages(ctx.chat))
    end

    test "an answer the database refuses logs no part of it, and no crash report", ctx do
      bad = put_in(text_answer("Answer " <> @secret), ["usage", "prompt_tokens"], -1)
      answer_next(bad)

      {_, logs} =
        LogProbe.capture(fn ->
          turn_ref = start!(ctx, "Ask " <> @secret)
          await_end(ctx.chat, turn_ref)
        end)

      refute_leak(logs)
      refute Enum.any?(logs, &(&1 =~ "terminating"))
      assert %Message{role: "notice", error: "interrupted"} = List.last(messages(ctx.chat))
      assert unlocked?(ctx)
    end

    test "a crash while a tool result is stored logs no part of it", ctx do
      Repo.query!("""
      CREATE FUNCTION pg_temp.agent_refuse_tool_rows() RETURNS trigger AS $$
      BEGIN
        IF NEW.role = 'tool' THEN RAISE EXCEPTION 'no tool rows here'; END IF;
        RETURN NEW;
      END $$ LANGUAGE plpgsql
      """)

      Repo.query!("""
      CREATE TRIGGER agent_refuse_tool_rows BEFORE INSERT ON phoenix_kit_agent_messages
      FOR EACH ROW EXECUTE FUNCTION pg_temp.agent_refuse_tool_rows()
      """)

      answer_next(tool_answer([call("c1", "agenttest_list_items", %{"say" => @secret})]))

      {_, logs} =
        LogProbe.capture(fn ->
          turn_ref = start!(ctx, "Ask " <> @secret)
          await_end(ctx.chat, turn_ref)
        end)

      refute_leak(logs)
      refute Enum.any?(logs, &(&1 =~ "terminating"))
      assert Enum.any?(logs, &(&1 =~ "Postgrex.Error"))
      assert %Message{role: "notice", error: "interrupted"} = List.last(messages(ctx.chat))
      assert unlocked?(ctx)
    end

    test "a monitor that does not answer in time: the refusal and the log hold no turn data",
         ctx do
      Application.put_env(:phoenix_kit_agent, :turn_handshake_ms, 100)
      on_exit(fn -> Application.delete_env(:phoenix_kit_agent, :turn_handshake_ms) end)
      {:ok, _} = Config.put_system_prompt("Prompt " <> @secret, [])

      monitor = suspend_monitor()

      {result, logs} =
        LogProbe.capture(fn ->
          result = Turns.start(ctx.ref, false, ctx.chat.uuid, "Ask " <> @secret)
          :ok = :sys.resume(monitor)
          _ = :sys.get_state(monitor)

          for pid <- Task.Supervisor.children(PhoenixKitAgent.Turns.TaskSupervisor) do
            ref = Process.monitor(pid)
            assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
          end

          _ = :sys.get_state(monitor)
          result
        end)

      assert result == {:error, {:monitor_unavailable, :timeout}}
      refute_leak(logs, result)
    end

    test "the monitor's crash report would show no turn data" do
      turn = %{turn_ref: "t1", text: @secret, history: [%{content: @secret}]}
      message = {:"$gen_call", {self(), make_ref()}, {:start, turn, 1_000, [self()], make_ref()}}

      status = %{
        message: message,
        state: %{},
        reason: {%MatchError{term: @secret}, [{Mod, :fun, [@secret], []}]},
        log: [message]
      }

      formatted = Monitor.format_status(status)
      refute inspect(formatted, limit: :infinity, printable_limit: :infinity) =~ @secret
      assert inspect(formatted) =~ "t1"
    end
  end
end
