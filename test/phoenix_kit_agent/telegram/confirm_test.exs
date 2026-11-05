defmodule PhoenixKitAgent.Telegram.ConfirmTest do
  @moduledoc """
  A change asked for in Telegram: the turn ends with a card (the assistant's
  text, then the preview with ✅ and ❌ under it), the press of a button runs
  or turns down the change for the person of the linked chat, and the card is
  edited to what became of it — also when the site settled it. The bot is
  `PhoenixKitAgent.Test.TelegramClient`: every call to Telegram comes to the
  test as `{:tg, call}`; the model is a `Req.Test` stub; the tools are
  `PhoenixKitAgent.Test.Tools`.

  Where the core at hand does not let a chat hold a write (no
  `Executor.link_writes?/0`), `PhoenixKitAgent.Test.FakeCore` plays that part
  on top of the real calls; on a core that does, nothing is stood in for.
  """

  use PhoenixKitAgent.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.API.Confirm.Confirmation
  alias PhoenixKit.API.Executor
  alias PhoenixKit.Integrations.Telegram.Linking
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKitAgent.{Config, Confirmations, Conversations, Prompt, Turns}
  alias PhoenixKitAgent.Schemas.{Conversation, Message}
  alias PhoenixKitAgent.Telegram.{Bridge, Limiter, Texts}
  alias PhoenixKitAgent.Test.{FakeCore, LogProbe, TelegramClient, Tools}
  alias PhoenixKitAgent.Turns.Locks

  @stub __MODULE__
  @model "deepseek/deepseek-v4.1-flash"
  @write "agenttest_write_item"
  @chat 428_897_538

  setup do
    {:ok, _} = PhoenixKitAgent.enable_system()
    {:ok, _} = PhoenixKitAI.enable_system()
    {:ok, _} = Config.put_telegram_enabled(true, log: false)
    :ok = ModuleRegistry.register(Tools)
    {:ok, _} = Settings.update_setting("api_session_write_modules", "agent_test_tools")

    Req.Test.set_req_test_to_shared()
    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, @stub}, retry: false)
    Application.put_env(:phoenix_kit_agent, :test_tool_listener, self())
    TelegramClient.start()
    end_queues()

    endpoint = endpoint_fixture(%{model: @model})
    {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", endpoint.uuid)

    {:ok, role} = Roles.create_role(%{name: "TgConfirm#{System.unique_integer([:positive])}"})
    _ = owner_fixture()

    for key <- ["agent", "agent.telegram", "dashboard"],
        do: {:ok, _} = Permissions.grant_permission(role.uuid, key)

    user = user_fixture("tgconfirm")
    {:ok, _} = Roles.assign_role(user, role.name)

    connection = UUIDv7.generate()
    ref = telegram_link_fixture(user, connection, @chat)
    Limiter.clear_unlinked(connection)
    {site_ref, _token} = session_fixture(user)

    TelegramClient.set(:connection, connection)
    core(fake?(), user, site_ref)

    on_exit(fn ->
      stop_all_turns()
      end_queues()
      TelegramClient.stop()
      ModuleRegistry.unregister(Tools)
      Application.put_env(:phoenix_kit_agent, :telegram_link_writes, false)
      Application.delete_env(:phoenix_kit_agent, :api_modules)
      Application.delete_env(:phoenix_kit_agent, :fake_core_listener)
      Application.delete_env(:phoenix_kit_agent, :fake_core_sessions)
      Application.delete_env(:phoenix_kit_agent, :test_tool_listener)
      Application.delete_env(:phoenix_kit_ai, :req_options)
      Req.Test.set_req_test_to_private()
    end)

    %{
      user: user,
      role: role,
      connection: connection,
      ref: ref,
      site_ref: site_ref,
      endpoint: endpoint
    }
  end

  # A core that cannot hold a chat's write gets `FakeCore`; one that can is used as it is.
  defp fake? do
    Code.ensure_loaded?(Executor)
    not function_exported?(Executor, :link_writes?, 0)
  end

  defp core(true, user, site_ref) do
    Application.put_env(:phoenix_kit_agent, :telegram_link_writes, true)
    Application.put_env(:phoenix_kit_agent, :api_modules, executor: FakeCore, confirm: FakeCore)
    Application.put_env(:phoenix_kit_agent, :fake_core_listener, self())
    FakeCore.install(user.uuid, site_ref)
  end

  defp core(false, _user, _site_ref),
    do: Application.delete_env(:phoenix_kit_agent, :telegram_link_writes)

  # ── the model ───────────────────────────────────────────────────────

  defp usage, do: %{"prompt_tokens" => 11, "completion_tokens" => 4, "total_tokens" => 15}

  defp model_says(text) do
    Req.Test.expect(@stub, fn conn ->
      Req.Test.json(conn, %{
        "model" => @model,
        "choices" => [%{"message" => %{"role" => "assistant", "content" => text}}],
        "usage" => usage()
      })
    end)
  end

  # The model proposes the change (the write tool) and says `text` with it.
  defp model_holds(text, args \\ %{"name" => "new"}) do
    Req.Test.expect(@stub, fn conn ->
      Req.Test.json(conn, %{
        "model" => @model,
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "content" => text,
              "tool_calls" => [
                %{
                  "id" => "w1",
                  "type" => "function",
                  "function" => %{"name" => @write, "arguments" => Jason.encode!(args)}
                }
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ],
        "usage" => usage()
      })
    end)
  end

  # ── what the bot is asked ───────────────────────────────────────────

  defp send_update(ctx, text, opts \\ []),
    do: Bridge.dispatch(ctx.connection, TelegramClient.update(@chat, text, opts))

  defp calls_until(done, timeout \\ 5_000) do
    receive do
      {:tg, {:typing, _, _}} ->
        calls_until(done, timeout)

      {:tg, call} ->
        if done.(call), do: [call], else: [call | calls_until(done, timeout)]
    after
      timeout -> flunk("the bot was not called as expected")
    end
  end

  defp reaction?(emoji), do: &match?({:react, _, _, _, ^emoji}, &1)

  # Every call to the bot that came so far, in order, typing left out.
  defp drain(acc \\ []) do
    receive do
      {:tg, {:typing, _, _}} -> drain(acc)
      {:tg, call} -> drain([call | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp answers(calls), do: for({:answer_callback, _, _, text} <- calls, do: text)

  defp edits(calls),
    do: for({:edit_message, _, _, id, text, markup} <- calls, do: {id, text, markup})

  defp sent(calls), do: for({:send_message, _, _, text} <- calls, do: text)

  defp cards_sent(calls),
    do: for({:send_message, _, _, text, reply_markup: markup} <- calls, do: {text, markup})

  # A held change asked for in Telegram: the card the bot sent, and where it stands.
  defp hold!(ctx, opts \\ []) do
    model_holds(Keyword.get(opts, :text, "I will rename the item."), %{
      "name" => Keyword.get(opts, :name, "new")
    })

    send_update(ctx, "Rename the item", message_id: 41)
    calls = calls_until(reaction?("👍"))
    assert [{text, markup}] = cards_sent(calls)
    assert_received {:agent_test_preview, _input}

    chat = Conversations.latest_telegram_conversation(ctx.user.uuid)

    [%{"text" => "✅ Confirm", "callback_data" => "c:" <> uuid}, _cancel] =
      hd(markup["inline_keyboard"])

    assert {_connection, @chat, message_id} = Conversations.telegram_card(chat, uuid)
    settle()
    drain()

    %{
      calls: calls,
      text: text,
      markup: markup,
      uuid: uuid,
      message_id: message_id,
      chat: chat,
      card: card_of(chat, uuid)
    }
  end

  defp card_of(chat, uuid) do
    Repo.one!(
      from(m in Message,
        where:
          m.conversation_uuid == ^chat.uuid and m.role == "tool" and m.confirmation_uuid == ^uuid
      )
    )
  end

  defp press(ctx, data, opts \\ []) do
    Bridge.dispatch(ctx.connection, TelegramClient.callback_update(@chat, data, opts))
    settle()
    drain()
  end

  defp confirm_data(held), do: "c:" <> held.uuid
  defp reject_data(held), do: "x:" <> held.uuid

  defp pressed(ctx, held, data, opts \\ []),
    do: press(ctx, data, Keyword.put_new(opts, :message_id, held.message_id))

  defp notices(chat),
    do:
      Repo.all(
        from(m in Message,
          where:
            m.conversation_uuid == ^chat.uuid and m.role == "notice" and
              not is_nil(m.confirmation_uuid),
          order_by: [asc: m.inserted_at, asc: m.uuid]
        )
      )

  defp row(uuid), do: Repo.get!(Confirmation, uuid)
  defp written, do: Settings.get_setting("agenttest_written")

  defp expire!(uuid) do
    past = DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:second)
    Repo.update_all(from(c in Confirmation, where: c.uuid == ^uuid), set: [expires_at: past])
  end

  defp end_queues do
    supervisor = PhoenixKitAgent.Telegram.QueueSupervisor

    for {_, pid, _, _} <- DynamicSupervisor.which_children(supervisor) do
      DynamicSupervisor.terminate_child(supervisor, pid)
    end

    for tasks <- [
          PhoenixKitAgent.Telegram.TaskSupervisor,
          PhoenixKitAgent.Telegram.ReplySupervisor
        ],
        pid <- Task.Supervisor.children(tasks) do
      Task.Supervisor.terminate_child(tasks, pid)
    end

    :ok
  end

  defp stop_all_turns do
    for {pid, _} <-
          Registry.select(PhoenixKitAgent.Turns.Registry, [{{:_, :"$1", :_}, [], [{{:"$1", 0}}]}]) do
      Process.exit(pid, :kill)
    end

    :ok
  end

  defp settle(tries \\ 250) do
    supervisors = [
      PhoenixKitAgent.Telegram.TaskSupervisor,
      PhoenixKitAgent.Telegram.ReplySupervisor
    ]

    if tries > 0 and Enum.any?(supervisors, &(Task.Supervisor.children(&1) != [])) do
      Process.sleep(10)
      settle(tries - 1)
    else
      :ok
    end
  end

  defp revoke!(ctx, key) do
    :ok = Permissions.revoke_permission(ctx.role.uuid, key)
  end

  # ── the turn ────────────────────────────────────────────────────────

  describe "a turn that ends with a held change" do
    test "the assistant's text, then the card with ✅ and ❌, and 👍 (not a deadline)", ctx do
      held = hold!(ctx)

      assert sent(held.calls) == ["I will rename the item."]
      assert for({:react, _, @chat, 41, emoji} <- held.calls, do: emoji) == ["👀", "👍"]

      # The preview, as plain text.
      assert held.text =~ "Confirm this change"
      assert held.text =~ "item — update"
      assert held.text =~ "name: — → new"

      # Both buttons; their data is "c:"/"x:" and the uuid, 38 bytes, nothing else.
      assert [[confirm, cancel]] = held.markup["inline_keyboard"]
      assert confirm == %{"text" => "✅ Confirm", "callback_data" => "c:" <> held.uuid}
      assert cancel == %{"text" => "❌ Cancel", "callback_data" => "x:" <> held.uuid}
      assert byte_size(confirm["callback_data"]) == 38
      refute held.text =~ "agenttest"
      refute inspect(held.markup) =~ "agenttest"
      refute inspect(held.markup) =~ ctx.user.uuid

      # Nothing is written yet; the card waits, and is the turn's own.
      assert written() == nil
      assert row(held.uuid).status == "unused"
      refute_received {:agent_test_tool, "agenttest.write_item", _, _}
      assert notices(held.chat) == []
      assert held.card.tool_outcome == "needs_confirmation"
    end

    test "the row is the chat's: the audit label of the hold is core's own", ctx do
      held = hold!(ctx)
      assert row(held.uuid).actor_user_uuid == ctx.user.uuid

      assert %{"origin" => "telegram", "connection_uuid" => connection, "chat_id" => "428897538"} =
               Map.take(row(held.uuid).context, ["origin", "connection_uuid", "chat_id"])

      assert connection == ctx.connection
    end

    test "without a text from the model there is only the card", ctx do
      model_holds(nil)
      send_update(ctx, "Rename the item", message_id: 41)
      calls = calls_until(reaction?("👍"))

      assert sent(calls) == []
      assert [{_text, _markup}] = cards_sent(calls)
    end

    test "a card Telegram would not take: one message to the site, 🤷, the change waits", ctx do
      model_holds("I will rename it.")

      TelegramClient.set(:send, fn _chat, _text, opts ->
        if opts[:reply_markup],
          do: {:error, "Bad Request: nope"},
          else: {:ok, %{"message_id" => 9}}
      end)

      send_update(ctx, "Rename the item", message_id: 41)
      calls = calls_until(reaction?("🤷"))

      assert sent(calls) == [
               "I will rename it.",
               "I could not show the buttons. Confirm the change on the site."
             ]

      assert [%Message{confirmation_uuid: uuid}] =
               Repo.all(from(m in Message, where: m.tool_outcome == "needs_confirmation"))

      assert row(uuid).status == "unused"
    end
  end

  # ── ✅ and ❌ ────────────────────────────────────────────────────────

  describe "✅" do
    test "answers the button, runs the change for the user, edits the card to Done", ctx do
      held = hold!(ctx)
      calls = pressed(ctx, held, confirm_data(held))

      # The "clock" is taken off first, with no toast; then the card is edited.
      assert [{:answer_callback, _, "cb-1", nil}, {:edit_message, _, @chat, mid, text, nil}] =
               calls

      assert mid == held.message_id
      assert text =~ "✅ Done"
      assert text =~ "update: 1"
      refute text =~ "Confirm this change"

      assert written() == "new"
      assert_received {:agent_test_tool, "agenttest.write_item", %{"name" => "new"}, _}
      assert row(held.uuid).status == "used"
      assert [%Message{tool_outcome: "confirmed"}] = notices(held.chat)

      # The audit label is the chat's: "telegram", not the site's "agent".
      if fake?(), do: assert_received({:fake_core, :redeem, "telegram"})
    end

    test "the model is not called after the press and spends nothing", ctx do
      held = hold!(ctx)
      before = journal_count()
      pressed(ctx, held, confirm_data(held))

      assert journal_count() == before
    end

    test "twice: the handler runs once, the second press is told it is handled", ctx do
      held = hold!(ctx)
      pressed(ctx, held, confirm_data(held))
      assert_received {:agent_test_tool, "agenttest.write_item", _, _}

      calls = pressed(ctx, held, confirm_data(held))

      refute_received {:agent_test_tool, "agenttest.write_item", _, _}
      assert answers(calls) == ["Already handled."]
      assert [{_, "✅ Done" <> _, nil}] = edits(calls)
      assert [_one] = notices(held.chat)
    end

    test "two at once: the handler runs once", ctx do
      held = hold!(ctx)
      data = confirm_data(held)

      Bridge.dispatch(
        ctx.connection,
        TelegramClient.callback_update(@chat, data, id: 1, callback_id: "a")
      )

      Bridge.dispatch(
        ctx.connection,
        TelegramClient.callback_update(@chat, data, id: 2, callback_id: "b")
      )

      settle()

      assert_received {:agent_test_tool, "agenttest.write_item", _, _}
      refute_received {:agent_test_tool, "agenttest.write_item", _, _}
      assert [%Message{tool_outcome: "confirmed"}] = notices(held.chat)
    end

    test "a row that ran out: a toast, the card said so without buttons, nothing written", ctx do
      held = hold!(ctx)
      expire!(held.uuid)

      calls = pressed(ctx, held, confirm_data(held))

      assert answers(calls) == ["The time to confirm ran out. Ask again."]
      assert [{mid, text, nil}] = edits(calls)
      assert mid == held.message_id
      assert text =~ "ran out"
      assert written() == nil
      assert notices(held.chat) == []
    end

    test "the values changed under the preview: the old card says so, a new one comes", ctx do
      held = hold!(ctx)
      {:ok, _} = Settings.update_setting("agenttest_written", "someone-else")

      calls = pressed(ctx, held, confirm_data(held))

      assert [%Message{tool_outcome: "changed"}] = notices(held.chat)
      assert written() == "someone-else"

      assert [{mid, "The data changed" <> _, nil}] = edits(calls)
      assert mid == held.message_id

      assert [{text, markup}] = cards_sent(calls)
      assert text =~ "name: someone-else → new"
      assert [[%{"callback_data" => "c:" <> new_uuid}, _]] = markup["inline_keyboard"]
      refute new_uuid == held.uuid

      # The new row is the chat's too, kept for the next edit, and ✅ on it works.
      assert row(new_uuid).status == "unused"
      assert row(new_uuid).context["origin"] == "telegram"
      chat = Repo.get!(Conversation, held.chat.uuid)
      assert {_, @chat, new_mid} = Conversations.telegram_card(chat, new_uuid)

      calls = press(ctx, "c:" <> new_uuid, message_id: new_mid)
      assert written() == "new"
      assert [{^new_mid, "✅ Done" <> _, nil}] = edits(calls)
    end

    test "while a turn of the user runs: the buttons stay, a line says to press again", ctx do
      held = hold!(ctx)
      other = conversation_fixture(ctx.user)
      :ok = Locks.acquire(ctx.user.uuid, other.uuid, "a-turn", 600)

      calls = pressed(ctx, held, confirm_data(held))

      assert answers(calls) == [nil]
      assert [{mid, text, markup}] = edits(calls)
      assert mid == held.message_id
      assert text =~ "⏳ The agent is answering"
      assert text =~ "name: — → new"
      assert [[_confirm, _cancel]] = markup["inline_keyboard"]
      assert written() == nil
      assert notices(held.chat) == []
      assert row(held.uuid).status == "unused"
    end

    test "while another press runs: the same", ctx do
      held = hold!(ctx)
      :ok = Locks.acquire_user(ctx.user.uuid, Locks.click_ref(), Turns.lock_ttl_s(), 30)

      calls = pressed(ctx, held, confirm_data(held))

      assert [{_, text, markup}] = edits(calls)
      assert text =~ "⏳"
      assert [[_, _]] = markup["inline_keyboard"]
      assert row(held.uuid).status == "unused"
    end

    test "the right to the tool is gone: not allowed, only ❌ is left, and ❌ works", ctx do
      held = hold!(ctx)
      revoke!(ctx, "dashboard")

      calls = pressed(ctx, held, confirm_data(held))

      assert answers(calls) == [nil]
      assert [{_, text, markup}] = edits(calls)
      assert text =~ "Not allowed: you have no right to make this change."
      assert [[%{"callback_data" => "x:" <> _}]] = markup["inline_keyboard"]
      assert written() == nil
      assert row(held.uuid).status == "unused"

      calls = pressed(ctx, held, reject_data(held))

      assert [%Message{tool_outcome: "rejected"}] = notices(held.chat)
      assert [{_, "❌ Cancelled" <> _, nil}] = edits(calls)
    end
  end

  describe "❌" do
    test "turns the change down: the card says cancelled, nothing is written", ctx do
      held = hold!(ctx)
      calls = pressed(ctx, held, reject_data(held))

      assert [{:answer_callback, _, _, nil}, {:edit_message, _, @chat, mid, text, nil}] = calls
      assert mid == held.message_id
      assert text =~ "❌ Cancelled"
      assert written() == nil
      assert row(held.uuid).status == "rejected"
      assert [%Message{tool_outcome: "rejected"}] = notices(held.chat)
    end

    test "a card that ran out: told so, nothing turned down", ctx do
      held = hold!(ctx)
      expire!(held.uuid)

      calls = pressed(ctx, held, reject_data(held))

      assert answers(calls) == ["The time to confirm ran out. Ask again."]
      assert [{_, _text, nil}] = edits(calls)
    end
  end

  # ── what a press may be ─────────────────────────────────────────────

  describe "a press that is not for a card of this chat" do
    defp card_in(conversation, uuid) do
      Repo.insert!(%Message{
        conversation_uuid: conversation.uuid,
        role: "tool",
        content: "{}",
        tool_name: "agenttest.write_item",
        tool_call_id: "w9",
        tool_outcome: "needs_confirmation",
        confirmation_uuid: uuid,
        tool_result: %{"status" => "confirmation_required", "confirmation_id" => uuid}
      })
    end

    test "an unknown card, another user's, the site's and another chat's are refused alike",
         ctx do
      held = hold!(ctx)

      stranger = user_with(["agent", "agent.telegram", "dashboard"], "stranger")

      theirs =
        conversation_fixture(stranger, %{metadata: %{"source" => "telegram", "chat_id" => @chat}})

      site = conversation_fixture(ctx.user)

      elsewhere =
        conversation_fixture(ctx.user, %{
          metadata: %{"source" => "telegram", "chat_id" => @chat + 1}
        })

      uuids =
        for conversation <- [theirs, site, elsewhere] do
          uuid = UUIDv7.generate()
          card_in(conversation, uuid)
          uuid
        end

      for uuid <- [UUIDv7.generate() | uuids], action <- ["c:", "x:"] do
        calls = pressed(ctx, held, action <> uuid)

        assert answers(calls) == ["This change is no longer available."]
        assert [{_, "This change is no longer available.", nil}] = edits(calls)
      end

      assert written() == nil
      assert row(held.uuid).status == "unused"
      assert notices(held.chat) == []
      refute_received {:agent_test_tool, "agenttest.write_item", _, _}
    end

    test "data the bot never wrote is an unknown button", ctx do
      held = hold!(ctx)

      for data <- [
            "",
            "c:",
            "c:not-a-uuid",
            "z:" <> held.uuid,
            "c:" <> String.upcase(held.uuid),
            "c:" <> held.uuid <> "x",
            String.duplicate("a", 200)
          ] do
        calls = pressed(ctx, held, data)
        assert answers(calls) == ["This button does not work any more."]
        assert edits(calls) == []
      end

      assert row(held.uuid).status == "unused"
    end

    test "from a group, or from someone else than the chat: an empty answer, nothing else", ctx do
      held = hold!(ctx)

      calls = pressed(ctx, held, confirm_data(held), chat_type: "group")
      assert answers(calls) == [nil]
      assert edits(calls) == []

      calls = pressed(ctx, held, confirm_data(held), from: 999)
      assert answers(calls) == [nil]
      assert edits(calls) == []

      assert row(held.uuid).status == "unused"
      assert written() == nil
    end

    test "from a chat that is not linked: told once, then nothing", ctx do
      held = hold!(ctx)

      Bridge.dispatch(ctx.connection, TelegramClient.callback_update(777, confirm_data(held)))
      settle()
      assert answers(drain()) == ["This chat is not linked to an account."]

      Bridge.dispatch(ctx.connection, TelegramClient.callback_update(777, confirm_data(held)))
      settle()
      assert answers(drain()) == [nil]
      assert row(held.uuid).status == "unused"
    end

    test "after the chat was unlinked: not linked, and the card waits", ctx do
      held = hold!(ctx)
      :ok = Linking.unlink(ctx.user)

      calls = pressed(ctx, held, confirm_data(held))

      assert answers(calls) == ["This chat is not linked to an account."]
      assert edits(calls) == []
      assert row(held.uuid).status == "unused"
      assert written() == nil
    end

    test "after agent.telegram was taken away: neither ✅ nor ❌, and the card waits", ctx do
      held = hold!(ctx)
      revoke!(ctx, "agent.telegram")

      for data <- [confirm_data(held), reject_data(held)] do
        calls = pressed(ctx, held, data)
        assert answers(calls) == ["You may not use the assistant in Telegram."]
        assert edits(calls) == []
      end

      assert row(held.uuid).status == "unused"
      assert notices(held.chat) == []
    end

    test "more than ten presses a minute: the rest get an empty answer and no lookup", ctx do
      held = hold!(ctx)

      for _ <- 1..10 do
        assert answers(pressed(ctx, held, "junk")) == ["This button does not work any more."]
      end

      assert answers(pressed(ctx, held, confirm_data(held))) == [nil]
      assert row(held.uuid).status == "unused"
      assert written() == nil
    end
  end

  # ── a card of an older conversation ─────────────────────────────────

  describe "the conversation of a card" do
    test "a chat the account was relinked to starts its own conversation: its cards can be pressed",
         ctx do
      old = hold!(ctx)

      :ok = Linking.unlink(ctx.user)
      new_chat = @chat + 1
      telegram_link_fixture(ctx.user, ctx.connection, new_chat)
      Limiter.clear_unlinked(ctx.connection)

      model_holds("I will rename it.")

      Bridge.dispatch(
        ctx.connection,
        TelegramClient.update(new_chat, "Rename the item", message_id: 41)
      )

      calls = calls_until(reaction?("👍"))
      settle()
      drain()

      assert [{_text, markup}] = cards_sent(calls)
      assert [[%{"callback_data" => "c:" <> uuid}, _]] = markup["inline_keyboard"]
      chat = Conversations.latest_telegram_conversation(ctx.user.uuid)
      assert chat.uuid != old.chat.uuid
      assert chat.metadata["chat_id"] == new_chat

      Bridge.dispatch(ctx.connection, TelegramClient.callback_update(new_chat, "c:" <> uuid))
      settle()
      assert written() == "new"
    end

    test "an older one, after /new, is still the user's: ✅ works", ctx do
      held = hold!(ctx)
      send_update(ctx, "/new", message_id: 50)
      calls_until(&match?({:send_message, _, _, "Started a new conversation."}, &1))
      settle()
      drain()

      assert Conversations.latest_telegram_conversation(ctx.user.uuid).uuid != held.chat.uuid

      pressed(ctx, held, confirm_data(held))

      assert written() == "new"
      assert [%Message{tool_outcome: "confirmed"}] = notices(held.chat)
    end

    test "a deleted one: the card is unavailable, its buttons come off, the row runs out", ctx do
      held = hold!(ctx)

      Repo.update_all(from(c in Conversation, where: c.uuid == ^held.chat.uuid),
        set: [status: "deleted"]
      )

      calls = pressed(ctx, held, confirm_data(held))

      assert answers(calls) == ["This change is no longer available."]
      assert [{_, "This change is no longer available.", nil}] = edits(calls)
      assert row(held.uuid).status == "unused"
      assert written() == nil
    end

    test "the message of the card is remembered by a press when the send did not", ctx do
      held = hold!(ctx)
      chat = Repo.get!(Conversation, held.chat.uuid)

      Repo.update_all(from(c in Conversation, where: c.uuid == ^chat.uuid),
        set: [metadata: Map.delete(chat.metadata, "telegram_cards")]
      )

      calls = press(ctx, confirm_data(held), message_id: 777)

      assert {_, @chat, 777} =
               Conversations.telegram_card(Repo.get!(Conversation, chat.uuid), held.uuid)

      # ...and the edit after the outcome finds it.
      assert [{777, "✅ Done" <> _, nil}] = edits(calls)
    end

    test "a press does not move the place the send kept", ctx do
      held = hold!(ctx)
      calls = press(ctx, confirm_data(held), message_id: 888)

      assert {_, @chat, mid} =
               Conversations.telegram_card(Repo.get!(Conversation, held.chat.uuid), held.uuid)

      assert mid == held.message_id
      assert [{^mid, "✅ Done" <> _, nil}] = edits(calls)
    end
  end

  # ── what the site settles ───────────────────────────────────────────

  describe "an outcome written elsewhere" do
    test "✅ on the site: the card in Telegram says done, without buttons", ctx do
      held = hold!(ctx)

      assert {:ok, :confirmed} =
               Confirmations.confirm(ctx.site_ref, false, held.chat.uuid, held.card.uuid)

      settle()
      assert [{mid, "✅ Done" <> _, nil}] = edits(drain())
      assert mid == held.message_id
      assert written() == "new"
      if fake?(), do: assert_received({:fake_core, :redeem, "agent"})
    end

    test "❌ on the site: cancelled", ctx do
      held = hold!(ctx)

      assert {:ok, :rejected} =
               Confirmations.reject(ctx.site_ref, false, held.chat.uuid, held.card.uuid)

      settle()
      assert [{_, "❌ Cancelled" <> _, nil}] = edits(drain())
    end

    test "a card that ran out, settled by the site: the time ran out", ctx do
      held = hold!(ctx)
      expire!(held.uuid)

      assert :ok = Confirmations.settle_lapsed(ctx.site_ref, false, held.chat.uuid)
      settle()

      assert [{_, "⌛" <> _, nil}] = edits(drain())
    end

    test "the data changed under the site's press: a new card with buttons here", ctx do
      held = hold!(ctx)
      {:ok, _} = Settings.update_setting("agenttest_written", "someone-else")

      assert {:ok, :changed} =
               Confirmations.confirm(ctx.site_ref, false, held.chat.uuid, held.card.uuid)

      settle()
      calls = drain()

      assert [{_, "The data changed" <> _, nil}] = edits(calls)
      assert [{text, markup}] = cards_sent(calls)
      assert text =~ "name: someone-else → new"
      assert [[%{"callback_data" => "c:" <> new_uuid}, _]] = markup["inline_keyboard"]
      assert row(new_uuid).context["origin"] == "telegram"
    end

    test "a new card that cannot be sent is told as a line that sends to the site", ctx do
      held = hold!(ctx)
      {:ok, _} = Settings.update_setting("agenttest_written", "someone-else")

      TelegramClient.set(:send, fn _chat, _text, opts ->
        if opts[:reply_markup],
          do: {:error, "Bad Request: nope"},
          else: {:ok, %{"message_id" => 9}}
      end)

      assert {:ok, :changed} =
               Confirmations.confirm(ctx.site_ref, false, held.chat.uuid, held.card.uuid)

      settle()

      assert ["I could not show the buttons. Confirm the change on the site."] = sent(drain())
    end

    test "nothing is edited for another bot, with the switch off, or without a kept place", ctx do
      held = hold!(ctx)
      chat = Repo.get!(Conversation, held.chat.uuid)
      cards = chat.metadata["telegram_cards"]
      moved = put_in(cards[held.uuid]["connection_uuid"], UUIDv7.generate())

      Repo.update_all(from(c in Conversation, where: c.uuid == ^chat.uuid),
        set: [metadata: Map.put(chat.metadata, "telegram_cards", moved)]
      )

      assert {:ok, :rejected} =
               Confirmations.reject(ctx.site_ref, false, held.chat.uuid, held.card.uuid)

      settle()
      assert edits(drain()) == []

      # The switch off.
      second = hold!(ctx, name: "second")
      {:ok, _} = Config.put_telegram_enabled(false, log: false)

      assert {:ok, :rejected} =
               Confirmations.reject(ctx.site_ref, false, second.chat.uuid, second.card.uuid)

      settle()
      assert edits(drain()) == []
    end
  end

  # ── a chat shared with the site ─────────────────────────────────────

  describe "a card of the site in the conversation of the chat" do
    defp site_card!(ctx) do
      model_says("Hi.")
      send_update(ctx, "Hi", message_id: 40)
      calls_until(reaction?("👍"))
      settle()
      drain()

      chat = Conversations.latest_telegram_conversation(ctx.user.uuid)
      :ok = Conversations.subscribe(ctx.site_ref, chat.uuid, impersonated: false)
      model_holds(nil)

      assert {:ok, turn_ref} =
               Turns.start(ctx.site_ref, false, chat.uuid, "Rename the item", [], [])

      chat_uuid = chat.uuid
      assert_receive {:agent_turn_finished, ^chat_uuid, ^turn_ref}, 5_000
      assert_received {:agent_test_preview, _}

      card =
        Repo.one!(
          from(m in Message,
            where: m.conversation_uuid == ^chat.uuid and m.tool_outcome == "needs_confirmation"
          )
        )

      {chat, card}
    end

    test "a turn from Telegram does not close it and does not ask for it twice", ctx do
      {chat, card} = site_card!(ctx)
      assert row(card.confirmation_uuid).context["origin"] == nil

      model_holds("Again.", %{"name" => "new"})
      model_says("It is waiting on the site.")
      send_update(ctx, "Rename the item", message_id: 60)
      calls_until(&match?({:react, _, _, 60, e} when e != "👀", &1))
      settle()

      assert notices(chat) == []

      assert [^card] =
               Repo.all(
                 from(m in Message,
                   where:
                     m.conversation_uuid == ^chat.uuid and m.tool_outcome == "needs_confirmation"
                 )
               )

      assert Repo.aggregate(
               from(m in Message,
                 where: m.conversation_uuid == ^chat.uuid and m.tool_outcome == "denied"
               ),
               :count
             ) == 1
    end

    test "the chat cannot confirm or turn it down: nothing is written", ctx do
      {chat, card} = site_card!(ctx)

      assert {:error, {:refused, "other_origin"}} =
               Confirmations.confirm_press(ctx.ref, card.confirmation_uuid)

      assert {:error, {:refused, "other_origin"}} =
               Confirmations.reject_press(ctx.ref, card.confirmation_uuid)

      assert notices(chat) == []
      assert row(card.confirmation_uuid).status == "unused"
      assert written() == nil

      # ...and a press on it says so, with nothing else done.
      calls = press(ctx, "c:" <> card.confirmation_uuid)
      assert answers(calls) == ["This change cannot be confirmed here. Open the site."]
      assert edits(calls) == []

      # The site can.
      assert {:ok, :confirmed} = Confirmations.confirm(ctx.site_ref, false, chat.uuid, card.uuid)
    end
  end

  # ── the places run out ──────────────────────────────────────────────

  describe "when the reply supervisor is full" do
    test "a press is still answered, as busy", ctx do
      held = hold!(ctx)
      supervisor = PhoenixKitAgent.Telegram.ReplySupervisor
      test = self()

      blockers =
        for _ <- 1..50 do
          {:ok, pid} =
            Task.Supervisor.start_child(supervisor, fn ->
              receive do
                :release -> send(test, :released)
              end
            end)

          pid
        end

      on_exit(fn -> Enum.each(blockers, &send(&1, :release)) end)

      Bridge.dispatch(ctx.connection, TelegramClient.callback_update(@chat, confirm_data(held)))
      assert_receive {:tg, {:answer_callback, _, "cb-1", text}}, 2_000
      assert text =~ "busy"

      Enum.each(blockers, &send(&1, :release))
      settle()
      assert written() == nil
      assert row(held.uuid).status == "unused"
    end
  end

  # ── logs ────────────────────────────────────────────────────────────

  describe "what is logged" do
    test "nothing of the text, the card, the button data or the user", ctx do
      {_, events} =
        LogProbe.capture(fn ->
          held = hold!(ctx, text: "SECRET-ASSISTANT-TEXT")
          pressed(ctx, held, "junk-SECRET-DATA")
          pressed(ctx, held, confirm_data(held))
          pressed(ctx, held, confirm_data(held))
          {:ok, _} = Settings.update_setting("agenttest_written", "x")
          Process.put(:held, held)
        end)

      held = Process.get(:held)
      log = events |> Enum.reject(&(&1 =~ "application: :ecto_sql")) |> Enum.join("\n")

      for secret <- [
            "SECRET-ASSISTANT-TEXT",
            "SECRET-DATA",
            "Rename the item",
            held.uuid,
            ctx.user.uuid,
            ctx.connection
          ] do
        refute log =~ secret
      end
    end

    test "a refusal of Telegram on an edit logs its kind only", ctx do
      held = hold!(ctx)

      TelegramClient.set(:edit, fn _id, _text, _markup ->
        {:error, "Bad Request: SECRET-DESCRIPTION"}
      end)

      {_, events} =
        LogProbe.capture(fn ->
          pressed(ctx, held, confirm_data(held))
        end)

      log = Enum.join(events, "\n")
      assert log =~ "card edit failed"
      refute log =~ "SECRET-DESCRIPTION"
    end
  end

  # ── a core that does not let a chat write ───────────────────────────

  describe "without writes for a chat (Config.writes?/0 false)" do
    setup do
      Application.put_env(:phoenix_kit_agent, :telegram_link_writes, false)
      :ok
    end

    test "the model is offered no write tool, and there is no card", ctx do
      test = self()

      Req.Test.expect(@stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:model_request, Jason.decode!(raw)})

        Req.Test.json(conn, %{
          "model" => @model,
          "choices" => [%{"message" => %{"role" => "assistant", "content" => "I can only read."}}],
          "usage" => usage()
        })
      end)

      send_update(ctx, "Rename the item")
      calls_until(reaction?("👍"))

      assert_received {:model_request, body}
      names = Enum.map(body["tools"] || [], & &1["function"]["name"])
      refute @write in names
      assert "agenttest_list_items" in names
      assert cards_sent(drain()) == []
    end

    test "a press is ignored, and the help does not promise buttons", ctx do
      uuid = UUIDv7.generate()
      update = TelegramClient.callback_update(@chat, "c:" <> uuid)

      assert Bridge.handle_update(ctx.connection, update) == :ignore
      assert Texts.static(:help) =~ "I cannot change anything here"
    end

    test "the system prompt tells the chat it only reads", ctx do
      prompt = telegram_prompt(ctx)
      assert prompt =~ "you can only read"
      refute prompt =~ "[confirmation]"
    end
  end

  describe "with writes for a chat" do
    test "the system prompt: a change is proposed, the buttons confirm it", ctx do
      prompt = telegram_prompt(ctx)

      assert prompt =~ "Confirm and a Cancel button"
      assert prompt =~ "[confirmation] done"
      refute prompt =~ "you can only read"
      assert Texts.static(:help) =~ "two buttons"
    end

    test "a press from a private chat is a decision with the chat's reference", ctx do
      uuid = UUIDv7.generate()

      update =
        TelegramClient.callback_update(@chat, "x:" <> uuid, callback_id: "cb-9", message_id: 5)

      assert {:press, {:telegram_link, user_uuid, connection, @chat},
              %{callback_id: "cb-9", message_id: 5, action: :reject, confirmation_uuid: ^uuid}} =
               Bridge.handle_update(ctx.connection, update)

      assert {user_uuid, connection} == {ctx.user.uuid, ctx.connection}
    end

    test "a press is not held to the ten minutes of a message", ctx do
      update = TelegramClient.callback_update(@chat, "x:" <> UUIDv7.generate())
      later = System.system_time(:second) + 100_000

      assert {:press, _ref, _press} = Bridge.handle_update(ctx.connection, update, now: later)
    end
  end

  defp telegram_prompt(ctx) do
    Prompt.build(%{
      user_uuid: ctx.user.uuid,
      scope: scope_of(ctx.user),
      locale: "en",
      channel: :telegram,
      now: ~U[2026-07-15 12:00:00Z]
    })
  end

  defp journal_count, do: Repo.aggregate(PhoenixKitAI.Request, :count)
end
