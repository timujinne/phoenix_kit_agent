defmodule PhoenixKitAgent.TelegramTest do
  @moduledoc """
  A linked Telegram chat as the second kind of actor of the module
  (`{:telegram_link, user_uuid, connection_uuid, chat_id}` from core): the
  trusted entry points for a bridge, the checks the chat passes on every call
  (the link, the account gate, the right `agent.telegram`), a turn that reads
  and never writes, the shared locks and limits, the prompt for the channel,
  and the refusals of what a chat cannot do (confirm, attach).
  """

  use PhoenixKitAgent.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Integrations.Telegram.Linking
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.PubSub.Manager, as: PubSub
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.{Permissions, Roles}
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitAgent.{Attachments, Confirmations, Conversations, Prompt, Turns, UserConfig}
  alias PhoenixKitAgent.Schemas.{Conversation, Message, UserSettings}
  alias PhoenixKitAgent.Test.Tools

  @stub __MODULE__
  @me [impersonated: false]
  @model "deepseek/deepseek-v4.1-flash"
  @chat_id 428_897_538

  setup do
    {:ok, _} = PhoenixKitAgent.enable_system()
    {:ok, _} = PhoenixKitAI.enable_system()
    :ok = ModuleRegistry.register(Tools)

    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, @stub}, retry: false)
    Application.put_env(:phoenix_kit_agent, :test_tool_listener, self())

    on_exit(fn ->
      ModuleRegistry.unregister(Tools)
      Application.delete_env(:phoenix_kit_ai, :req_options)
      Application.delete_env(:phoenix_kit_agent, :test_tool_listener)
    end)

    endpoint = endpoint_fixture(%{model: @model})
    {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", endpoint.uuid)

    user = user_with(["agent", "agent.telegram", "dashboard"], "tg")
    connection = UUIDv7.generate()
    ref = linked!(user, connection)

    %{user: user, connection: connection, ref: ref, endpoint: endpoint}
  end

  # ── helpers ─────────────────────────────────────────────────────────

  defp linked!(user, connection, chat_id \\ @chat_id) do
    confirm_email!(user)
    {:ok, _} = Linking.link_chat(user, connection, chat_id)
    {:telegram_link, user.uuid, connection, chat_id}
  end

  defp confirm_email!(user) do
    Repo.update_all(from(u in User, where: u.uuid == ^user.uuid),
      set: [confirmed_at: DateTime.utc_now()]
    )
  end

  defp trusted_chat!(%{user: user, ref: ref}, metadata \\ %{"source" => "telegram"}) do
    {:ok, chat} = Conversations.create_conversation_for(user, metadata: metadata)
    :ok = PubSub.subscribe(Conversations.topic(chat.uuid))
    assert {:ok, _} = Conversations.owned_conversation(ref, chat.uuid, @me)
    chat
  end

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

  defp answer_next(answer) do
    test = self()

    Req.Test.expect(@stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:model_request, Jason.decode!(raw)})
      Req.Test.json(conn, answer)
    end)
  end

  defp hang_next do
    test = self()

    Req.Test.expect(@stub, fn conn ->
      send(test, {:model_waiting, self()})

      receive do
        :never -> conn
      end
    end)
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

  defp tool_names(body), do: Enum.map(body["tools"] || [], & &1["function"]["name"])

  defp unlink!(user) do
    :ok = Linking.unlink(user)
  end

  # ── the gate for a chat ─────────────────────────────────────────────

  describe "a chat reference at the gate of Conversations" do
    test "a linked chat of a user holding agent and agent.telegram passes", ctx do
      assert {:ok, user_uuid} = Conversations.authorize_session(ctx.ref, @me)
      assert user_uuid == ctx.user.uuid
    end

    test "impersonated: true is refused for a chat as for a session", ctx do
      assert {:error, :impersonated} =
               Conversations.authorize_session(ctx.ref, impersonated: true)
    end

    test "the flag is still required", ctx do
      assert_raise ArgumentError, fn -> Conversations.authorize_session(ctx.ref, []) end
    end

    test "a user without agent.telegram is refused, though they hold agent" do
      user = user_with(["agent", "dashboard"], "no-tg")
      ref = linked!(user, UUIDv7.generate())

      assert {:error, :forbidden} = Conversations.authorize_session(ref, @me)
    end

    test "the Owner holds agent.telegram through \"*\"", _ctx do
      owner = owner_fixture()
      ref = linked!(owner, UUIDv7.generate(), 777)

      assert {:ok, _} = Conversations.authorize_session(ref, @me)
    end

    test "a web session needs no agent.telegram", _ctx do
      user = user_with(["agent"], "web")
      {session, _token} = session_fixture(user)

      assert {:ok, _} = Conversations.authorize_session(session, @me)
    end

    test "an unlinked chat is refused on the very next call", ctx do
      assert {:ok, _} = Conversations.authorize_session(ctx.ref, @me)
      unlink!(ctx.user)

      assert {:error, :session_gone} = Conversations.authorize_session(ctx.ref, @me)
    end

    test "a link dropped by an account recovery is refused", ctx do
      :ok = Linking.drop_links(ctx.user.uuid)

      assert {:error, :session_gone} = Conversations.authorize_session(ctx.ref, @me)
    end

    test "another chat id, another bot or another user is not the link", ctx do
      {:telegram_link, uuid, connection, chat_id} = ctx.ref
      other_user = user_with(["agent", "agent.telegram"], "other")

      for ref <- [
            {:telegram_link, uuid, connection, chat_id + 1},
            {:telegram_link, uuid, UUIDv7.generate(), chat_id},
            {:telegram_link, other_user.uuid, connection, chat_id},
            {:telegram_link, nil, connection, chat_id},
            {:telegram_link, uuid, nil, chat_id},
            {:telegram_link, uuid, connection, nil}
          ] do
        assert {:error, :session_gone} = Conversations.authorize_session(ref, @me)
      end
    end

    test "a blocked user is refused with the account gate's answer", ctx do
      Repo.update_all(from(u in User, where: u.uuid == ^ctx.user.uuid), set: [is_active: false])

      assert {:error, :inactive} = Conversations.authorize_session(ctx.ref, @me)
    end

    test "the assistant switched off for the user refuses their chat too", ctx do
      Repo.insert!(%UserSettings{user_uuid: ctx.user.uuid, enabled: false})

      assert {:error, :forbidden} = Conversations.authorize_session(ctx.ref, @me)
    end

    test "the module switched off refuses the chat", ctx do
      {:ok, _} = PhoenixKitAgent.disable_system()

      assert {:error, :forbidden} = Conversations.authorize_session(ctx.ref, @me)
    end

    test "the scope is the user's default narrowed role", ctx do
      assert {:ok, scope} = Conversations.authorized_scope(ctx.ref, @me)
      assert Scope.user_uuid(scope) == ctx.user.uuid
    end

    test "agent.telegram on a role other than the default one does not reach the chat" do
      {:ok, _} = Settings.update_setting("role_switcher_enabled", "true")
      user = user_with(["agent"], "two_roles")
      {:ok, extra} = Roles.create_role(%{name: "AgentTg#{System.unique_integer([:positive])}"})
      {:ok, _} = Permissions.grant_permission(extra.uuid, "agent")
      {:ok, _} = Permissions.grant_permission(extra.uuid, "agent.telegram")
      {:ok, _} = Roles.assign_role(user, extra.name)
      ref = linked!(user, UUIDv7.generate())

      # The union of the roles would allow it; the default role alone does not.
      assert user.uuid
             |> then(&Repo.get!(User, &1))
             |> Scope.for_user(narrow: false)
             |> Scope.can?("agent.telegram")

      assert {:error, :forbidden} = Conversations.authorize_session(ref, @me)
    end

    test "only the owner's chats are reachable through a chat reference", ctx do
      mine = trusted_chat!(ctx)
      other = user_with(["agent"], "stranger")
      theirs = conversation_fixture(other)

      assert {:ok, _} = Conversations.owned_conversation(ctx.ref, mine.uuid, @me)
      assert {:error, :not_found} = Conversations.owned_conversation(ctx.ref, theirs.uuid, @me)
    end
  end

  # ── the trusted functions of the bridge ─────────────────────────────

  describe "what a chat reference cannot write" do
    test "no chat is made, renamed, archived or deleted through it, nor a message added", ctx do
      chat = trusted_chat!(ctx)

      assert {:error, :not_in_telegram} = Conversations.create_conversation(ctx.ref, %{}, @me)

      assert {:error, :not_in_telegram} =
               Conversations.rename_conversation(ctx.ref, chat.uuid, "New", @me)

      assert {:error, :not_in_telegram} =
               Conversations.archive_conversation(ctx.ref, chat.uuid, @me)

      assert {:error, :not_in_telegram} =
               Conversations.delete_conversation(ctx.ref, chat.uuid, @me)

      assert {:error, :not_in_telegram} =
               Conversations.add_message(ctx.ref, chat.uuid, %{content: "Hi"}, @me)

      reloaded = Repo.get!(Conversation, chat.uuid)
      assert reloaded.status == "active"
      assert reloaded.title == chat.title
      assert reloaded.message_count == 0
    end

    test "nor the personal instructions", ctx do
      assert {:error, :not_in_telegram} =
               UserConfig.put_personal_instructions(ctx.ref, "OBEY", @me)

      assert Repo.get(UserSettings, ctx.user.uuid) == nil
    end

    test "it still reads the user's chats and instructions", ctx do
      chat = trusted_chat!(ctx)

      assert {:ok, _} = Conversations.get_conversation(ctx.ref, chat.uuid, @me)
      assert {:ok, []} = Conversations.list_messages(ctx.ref, chat.uuid, @me)
      assert {:ok, nil} = UserConfig.get_personal_instructions(ctx.ref, @me)
    end
  end

  describe "create_conversation_for/2 and latest_telegram_conversation/1" do
    test "create a chat of the user with the source in its metadata", ctx do
      metadata = %{"source" => "telegram", "chat_id" => @chat_id}

      assert {:ok, %Conversation{} = chat} =
               Conversations.create_conversation_for(ctx.user, metadata: metadata)

      assert chat.user_uuid == ctx.user.uuid
      assert chat.status == "active"
      assert chat.metadata == %{"source" => "telegram", "chat_id" => @chat_id}
    end

    test "a user uuid does for the user too", ctx do
      assert {:ok, chat} =
               Conversations.create_conversation_for(ctx.user.uuid,
                 metadata: %{"source" => "telegram"}
               )

      assert chat.user_uuid == ctx.user.uuid
    end

    test "without metadata the chat is an ordinary one", ctx do
      assert {:ok, %Conversation{metadata: %{}}} =
               Conversations.create_conversation_for(ctx.user, [])
    end

    test "the latest active Telegram chat of the user is found", ctx do
      assert Conversations.latest_telegram_conversation(ctx.user.uuid) == nil

      first = trusted_chat!(ctx)
      assert %Conversation{uuid: uuid} = Conversations.latest_telegram_conversation(ctx.user.uuid)
      assert uuid == first.uuid

      second = trusted_chat!(ctx)
      assert Conversations.latest_telegram_conversation(ctx.user.uuid).uuid == second.uuid
    end

    test "a message moves a chat to the front", ctx do
      first = trusted_chat!(ctx)
      _second = trusted_chat!(ctx)

      {:ok, _} =
        Conversations.add_turn_message(ctx.user.uuid, first.uuid, %{role: "user", content: "Hi"})

      assert Conversations.latest_telegram_conversation(ctx.user.uuid).uuid == first.uuid
    end

    test "archived, deleted, other-source and other users' chats do not count", ctx do
      archived = trusted_chat!(ctx)
      deleted = trusted_chat!(ctx)
      {site, _token} = session_fixture(ctx.user)
      {:ok, _} = Conversations.archive_conversation(site, archived.uuid, @me)
      {:ok, _} = Conversations.delete_conversation(site, deleted.uuid, @me)

      _web = conversation_fixture(ctx.user)
      {:ok, _} = Conversations.create_conversation_for(ctx.user, metadata: %{"source" => "email"})

      other = user_with(["agent"], "stranger")
      {:ok, _} = Conversations.create_conversation_for(other, metadata: %{"source" => "telegram"})

      assert Conversations.latest_telegram_conversation(ctx.user.uuid) == nil
    end

    test "a user that is not a uuid is an error, not a raise", _ctx do
      assert {:error, :not_found} = Conversations.create_conversation_for("not-a-uuid")
      assert {:error, :not_found} = Conversations.create_conversation_for(%{name: "no uuid"})
      assert {:error, :not_found} = Conversations.create_conversation_for(nil)
    end

    test "a malformed user uuid finds nothing", _ctx do
      assert Conversations.latest_telegram_conversation("not-a-uuid") == nil
      assert Conversations.latest_telegram_conversation(nil) == nil
    end
  end

  describe "turn_result/2" do
    setup ctx do
      %{chat: trusted_chat!(ctx), turn_ref: UUIDv7.generate()}
    end

    defp store!(ctx, attrs) do
      {:ok, message} =
        Conversations.add_turn_message(
          ctx.user.uuid,
          ctx.chat.uuid,
          Map.merge(%{turn_ref: ctx.turn_ref}, attrs)
        )

      message
    end

    test "nothing stored is :none", ctx do
      assert Conversations.turn_result(ctx.chat.uuid, ctx.turn_ref) == :none
      store!(ctx, %{role: "user", content: "Hi"})
      assert Conversations.turn_result(ctx.chat.uuid, ctx.turn_ref) == :none
    end

    test "the last assistant text without tool calls is the answer", ctx do
      store!(ctx, %{role: "user", content: "Hi"})
      store!(ctx, %{role: "assistant", content: "Let me look.", tool_calls: [%{"id" => "c1"}]})
      store!(ctx, %{role: "tool", tool_name: "x.y", tool_outcome: "ok", tool_call_id: "c1"})
      store!(ctx, %{role: "assistant", content: "Three orders."})

      assert Conversations.turn_result(ctx.chat.uuid, ctx.turn_ref) == {:answer, "Three orders."}
    end

    test "an assistant message with calls only is not an answer", ctx do
      store!(ctx, %{role: "assistant", content: "Looking…", tool_calls: [%{"id" => "c1"}]})

      assert Conversations.turn_result(ctx.chat.uuid, ctx.turn_ref) == :none
    end

    test "an empty assistant message is not an answer", ctx do
      store!(ctx, %{role: "assistant", content: "   "})

      assert Conversations.turn_result(ctx.chat.uuid, ctx.turn_ref) == :none
    end

    test "a notice outranks an earlier text of the same turn", ctx do
      store!(ctx, %{role: "user", content: "Hi"})
      store!(ctx, %{role: "assistant", content: "Half an answer."})
      store!(ctx, %{role: "notice", content: "Out of time.", error: "deadline"})

      assert Conversations.turn_result(ctx.chat.uuid, ctx.turn_ref) == {:notice, "deadline"}
    end

    test "a notice without an error code (a confirmation outcome) does not count", ctx do
      store!(ctx, %{role: "assistant", content: "Done."})
      store!(ctx, %{role: "notice", content: "Confirmed.", tool_outcome: "confirmed"})

      assert Conversations.turn_result(ctx.chat.uuid, ctx.turn_ref) == {:answer, "Done."}
    end

    test "messages of another turn or another chat are not read", ctx do
      other_turn = UUIDv7.generate()
      store!(ctx, %{role: "assistant", content: "This turn."})

      {:ok, _} =
        Conversations.add_turn_message(ctx.user.uuid, ctx.chat.uuid, %{
          turn_ref: other_turn,
          role: "notice",
          content: "x",
          error: "deadline"
        })

      assert Conversations.turn_result(ctx.chat.uuid, ctx.turn_ref) == {:answer, "This turn."}
      assert Conversations.turn_result(UUIDv7.generate(), ctx.turn_ref) == :none
      assert Conversations.turn_result("not-a-uuid", ctx.turn_ref) == :none
    end
  end

  # ── a turn for a chat ───────────────────────────────────────────────

  describe "a turn started for a chat" do
    test "runs on the user's behalf and its answer is read with turn_result/2", ctx do
      chat = trusted_chat!(ctx)
      answer_next(text_answer("Hello from the model."))

      assert {:ok, turn_ref} = Turns.start(ctx.ref, false, chat.uuid, "Hi")
      await_end(chat, turn_ref)

      assert Conversations.turn_result(chat.uuid, turn_ref) == {:answer, "Hello from the model."}
      assert [%Message{role: "user", content: "Hi"}, %Message{role: "assistant"}] = messages(chat)
    end

    test "the model sees the read tools only; a write tool is not offered", ctx do
      chat = trusted_chat!(ctx)
      answer_next(text_answer("ok"))

      {:ok, turn_ref} = Turns.start(ctx.ref, false, chat.uuid, "Hi")
      await_end(chat, turn_ref)

      assert_received {:model_request, body}
      assert tool_names(body) == ["agenttest_list_items"]
    end

    test "a read tool runs as the chat: the handler's context says telegram", ctx do
      chat = trusted_chat!(ctx)
      answer_next(tool_answer([call("r1", "agenttest_list_items", %{})]))
      answer_next(text_answer("Three items."))

      {:ok, turn_ref} = Turns.start(ctx.ref, false, chat.uuid, "List")
      await_end(chat, turn_ref)

      assert_received {:agent_test_tool, "agenttest.list_items", _input, ctx_of_call}
      assert ctx_of_call.actor.source == "telegram"
      assert Conversations.turn_result(chat.uuid, turn_ref) == {:answer, "Three items."}
    end

    test "a write named by the model is denied: no handler, no confirmation", ctx do
      chat = trusted_chat!(ctx)
      answer_next(tool_answer([call("w1", "agenttest_write_item", %{"name" => "x"})]))
      answer_next(text_answer("I cannot change that here."))

      {:ok, turn_ref} = Turns.start(ctx.ref, false, chat.uuid, "Change it")
      await_end(chat, turn_ref)

      refute_received {:agent_test_tool, "agenttest.write_item", _, _}
      assert Settings.get_setting("agenttest_written") == nil

      assert [%Message{tool_call_id: "w1", tool_outcome: "denied"}] =
               Enum.filter(messages(chat), &(&1.role == "tool"))

      assert Conversations.turn_result(chat.uuid, turn_ref) ==
               {:answer, "I cannot change that here."}
    end

    test "a turn ends with a notice when the link is dropped between rounds", ctx do
      chat = trusted_chat!(ctx)
      answer_next(tool_answer([call("r1", "agenttest_list_items", %{})]))

      Application.put_env(:phoenix_kit_agent, :test_tool_hook, fn _name, _input ->
        :ok = Linking.drop_links(ctx.user.uuid)
      end)

      on_exit(fn -> Application.delete_env(:phoenix_kit_agent, :test_tool_hook) end)

      {:ok, turn_ref} = Turns.start(ctx.ref, false, chat.uuid, "List")
      await_end(chat, turn_ref)

      assert {:notice, "session_gone"} = Conversations.turn_result(chat.uuid, turn_ref)
    end

    test "a turn ends with a notice when agent.telegram is taken away between rounds", ctx do
      chat = trusted_chat!(ctx)
      answer_next(tool_answer([call("r1", "agenttest_list_items", %{})]))

      Application.put_env(:phoenix_kit_agent, :test_tool_hook, fn _name, _input ->
        [name] = ctx.user |> Roles.get_user_roles() |> Enum.reject(&(&1 == "User"))
        role = Roles.get_role_by_name(name)
        :ok = Permissions.revoke_permission(role.uuid, "agent.telegram")
      end)

      on_exit(fn -> Application.delete_env(:phoenix_kit_agent, :test_tool_hook) end)

      {:ok, turn_ref} = Turns.start(ctx.ref, false, chat.uuid, "List")
      await_end(chat, turn_ref)

      assert {:notice, "forbidden"} = Conversations.turn_result(chat.uuid, turn_ref)
    end

    test "the user's own model is used and the spending is theirs", ctx do
      own = endpoint_fixture(%{model: "mistralai/own-model"})
      Repo.insert!(%UserSettings{user_uuid: ctx.user.uuid, endpoint_uuid: own.uuid})
      chat = trusted_chat!(ctx)
      answer_next(text_answer("ok"))

      {:ok, turn_ref} = Turns.start(ctx.ref, false, chat.uuid, "Hi")
      await_end(chat, turn_ref)

      assert_received {:model_request, body}
      assert body["model"] == "mistralai/own-model"

      request =
        Repo.one(
          from(r in PhoenixKitAI.Request,
            where: r.user_uuid == ^ctx.user.uuid,
            order_by: [desc: r.inserted_at, desc: r.uuid],
            limit: 1
          )
        )

      assert request.endpoint_uuid == own.uuid
      assert request.metadata["source"] == "agent"
    end

    test "the user's personal instructions are in the prompt", ctx do
      chat = trusted_chat!(ctx)
      {site, _token} = session_fixture(ctx.user)
      {:ok, _} = UserConfig.put_personal_instructions(site, "ALWAYS-BRIEF", @me)
      answer_next(text_answer("ok"))

      {:ok, turn_ref} = Turns.start(ctx.ref, false, chat.uuid, "Hi")
      await_end(chat, turn_ref)

      assert_received {:model_request, body}
      assert [%{"role" => "system", "content" => system} | _] = body["messages"]
      assert system =~ "ALWAYS-BRIEF"
    end

    test "the prompt is the Telegram one", ctx do
      chat = trusted_chat!(ctx)
      answer_next(text_answer("ok"))

      {:ok, turn_ref} = Turns.start(ctx.ref, false, chat.uuid, "Hi")
      await_end(chat, turn_ref)

      assert_received {:model_request, body}
      assert [%{"role" => "system", "content" => system} | _] = body["messages"]
      assert system =~ "Telegram"
      refute system =~ "waits for the user to confirm it in the chat"
    end

    test "the limits are the user's: a used-up turn limit is a refusal", ctx do
      chat = trusted_chat!(ctx)
      Repo.insert!(%UserSettings{user_uuid: ctx.user.uuid, daily_turn_limit: 0})

      assert {:error, {:limit_reached, :daily_turns}} =
               Turns.start(ctx.ref, false, chat.uuid, "Hi")

      refute_received {:model_request, _}
    end

    test "a turn running on the site blocks the chat's: turn_in_flight", ctx do
      {session, _token} = session_fixture(ctx.user)
      web_chat = conversation_fixture(ctx.user)
      chat = trusted_chat!(ctx)

      hang_next()
      {:ok, web_turn} = Turns.start(session, false, web_chat.uuid, "On the site")
      assert_receive {:model_waiting, _pid}, 5_000

      assert {:error, :turn_in_flight} = Turns.start(ctx.ref, false, chat.uuid, "In Telegram")
      assert messages(chat) == []

      :ok = Turns.stop(session, false, web_chat.uuid)
      _ = web_turn
    end

    test "a second turn in the same chat is :conversation_busy", ctx do
      chat = trusted_chat!(ctx)
      hang_next()
      {:ok, _turn} = Turns.start(ctx.ref, false, chat.uuid, "First")
      assert_receive {:model_waiting, _pid}, 5_000

      assert {:error, :conversation_busy} = Turns.start(ctx.ref, false, chat.uuid, "Second")

      :ok = Turns.stop(ctx.ref, false, chat.uuid)
    end

    test "an unlinked chat cannot start a turn", ctx do
      chat = trusted_chat!(ctx)
      unlink!(ctx.user)

      assert {:error, :session_gone} = Turns.start(ctx.ref, false, chat.uuid, "Hi")
      refute_received {:model_request, _}
    end
  end

  # ── the prompt for the channel ──────────────────────────────────────

  describe "Prompt for the Telegram channel" do
    defp build(ctx, extra) do
      Prompt.build(
        Map.merge(
          %{
            user_uuid: ctx.user.uuid,
            scope: scope_of(ctx.user),
            locale: "en",
            now: ~U[2026-07-15 12:00:00Z]
          },
          extra
        )
      )
    end

    test "plain text, short, absolute links, changes only on the site", ctx do
      prompt = build(ctx, %{channel: :telegram})

      assert prompt =~ "Telegram"
      assert prompt =~ "plain text"
      assert prompt =~ Routes.url("/admin")
      assert prompt =~ "on the site"
    end

    test "replaces the write rule: no promise of a confirmation in the chat", ctx do
      prompt = build(ctx, %{channel: :telegram})

      refute prompt =~ "[confirmation]"
      refute prompt =~ "waits for the user to confirm it in the chat"
    end

    test "without a channel the prompt is the site's, unchanged", ctx do
      prompt = build(ctx, %{})

      assert prompt =~ "[confirmation]"
      refute prompt =~ "Telegram"
    end

    test "the rule sits above the user's own text", ctx do
      Repo.insert!(%UserSettings{user_uuid: ctx.user.uuid, personal_instructions: "PERSONAL"})
      prompt = build(ctx, %{channel: :telegram})

      {rule, _} = :binary.match(prompt, "Telegram")
      {personal, _} = :binary.match(prompt, "PERSONAL")
      assert rule < personal
    end
  end

  # ── what a chat cannot do ───────────────────────────────────────────

  describe "Confirmations and Attachments with a chat reference" do
    test "every click and read of cards is :not_in_telegram", ctx do
      chat = trusted_chat!(ctx)
      message_uuid = UUIDv7.generate()

      assert {:error, :not_in_telegram} =
               Confirmations.confirm(ctx.ref, false, chat.uuid, message_uuid)

      assert {:error, :not_in_telegram} =
               Confirmations.reject(ctx.ref, false, chat.uuid, message_uuid)

      assert {:error, :not_in_telegram} =
               Confirmations.repeat(ctx.ref, false, chat.uuid, message_uuid)

      assert {:error, :not_in_telegram} = Confirmations.cards(ctx.ref, false, chat.uuid, [])
      assert {:error, :not_in_telegram} = Confirmations.waiting_cards(ctx.ref, false, chat.uuid)
      assert {:error, :not_in_telegram} = Confirmations.settle_lapsed(ctx.ref, false, chat.uuid)
    end

    test "a turn's settling of lapsed cards touches nothing for a chat", ctx do
      chat = trusted_chat!(ctx)

      {:ok, card} =
        Conversations.add_turn_message(
          ctx.user.uuid,
          chat.uuid,
          %{
            turn_ref: UUIDv7.generate(),
            role: "tool",
            tool_name: "agenttest.write_item",
            tool_outcome: "needs_confirmation"
          },
          confirmation_uuid: UUIDv7.generate()
        )

      before = length(messages(chat))
      assert :ok = Confirmations.settle_lapsed_in_turn(ctx.ref, chat)
      assert length(messages(chat)) == before
      assert card.uuid
    end

    test "every attachment function is :not_in_telegram", ctx do
      chat = trusted_chat!(ctx)
      upload = %{path: "/nonexistent", name: "a.txt", content_type: "text/plain"}
      uuid = UUIDv7.generate()

      assert {:error, :not_in_telegram} = Attachments.add(ctx.ref, chat.uuid, upload, @me)
      assert {:error, :not_in_telegram} = Attachments.get(ctx.ref, uuid, @me)
      assert {:error, :not_in_telegram} = Attachments.list_unsent(ctx.ref, chat.uuid, @me)
      assert {:error, :not_in_telegram} = Attachments.discard(ctx.ref, uuid, @me)
      assert {:error, :not_in_telegram} = Attachments.url(ctx.ref, uuid, @me)
    end
  end

  # ── the permission ──────────────────────────────────────────────────

  describe "the agent.telegram sub-permission" do
    test "is declared by the module, marked opt-in" do
      %{sub_permissions: subs} = PhoenixKitAgent.permission_metadata()

      assert %{key: "telegram", opt_in: true, label: label} =
               Enum.find(subs, &(&1.key == "telegram"))

      assert is_binary(label)
    end

    test "is a known key of the registry" do
      assert "agent.telegram" in Permissions.sub_permission_keys()
    end

    test "a role holds it only when it is granted" do
      {:ok, role} = Roles.create_role(%{name: "TgRole#{System.unique_integer([:positive])}"})
      refute Permissions.role_has_permission?(role.uuid, "agent.telegram")

      {:ok, _} = Permissions.grant_permission(role.uuid, "agent.telegram")
      assert Permissions.role_has_permission?(role.uuid, "agent.telegram")
    end
  end
end
