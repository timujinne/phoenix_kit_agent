defmodule PhoenixKitAgent.ConfirmationsTest do
  @moduledoc """
  A write of the assistant (spec §12 Ф2, Б2.2): the model asks for it in a turn,
  core holds it for the user's confirmation (`PhoenixKit.API.Executor.execute_as/5`
  with `allow: :all`), the turn ends with the card, and the user's click runs it
  (`PhoenixKitAgent.Confirmations`, `Executor.redeem_as/6`), turns it down or asks
  for it again.

  The model is a `Req.Test` stub of the provider behind `phoenix_kit_ai`; the
  tools are `PhoenixKitAgent.Test.Tools` (its write, `agenttest.write_item`,
  previews and writes the setting `agenttest_written`), run through the real
  executor with real sessions, roles, permissions and confirmation rows.
  """

  use PhoenixKitAgent.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.API.Confirm
  alias PhoenixKit.API.Confirm.Confirmation
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings
  alias PhoenixKit.Settings.Setting
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKitAgent.{Confirmations, Conversations, Turns}
  alias PhoenixKitAgent.Schemas.{Message, UserSettings}
  alias PhoenixKitAgent.Test.{LogProbe, Tools}
  alias PhoenixKitAgent.Turns.Locks

  @stub __MODULE__
  @me [impersonated: false]
  @model "deepseek/deepseek-v4.1-flash"
  @write "agenttest_write_item"

  setup do
    {:ok, _} = PhoenixKitAgent.enable_system()
    {:ok, _} = PhoenixKitAI.enable_system()
    :ok = ModuleRegistry.register(Tools)
    open_writes(true)

    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, @stub}, retry: false)
    Application.put_env(:phoenix_kit_agent, :test_tool_listener, self())

    on_exit(fn ->
      ModuleRegistry.unregister(Tools)
      Application.delete_env(:phoenix_kit_ai, :req_options)
      Application.delete_env(:phoenix_kit_agent, :test_tool_listener)
    end)

    endpoint = endpoint_fixture(%{model: @model})
    {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", endpoint.uuid)

    {:ok, role} = Roles.create_role(%{name: "AgentConfirm#{System.unique_integer([:positive])}"})
    _ = owner_fixture()
    for key <- ["agent", "dashboard"], do: {:ok, _} = Permissions.grant_permission(role.uuid, key)
    user = user_fixture("confirm")
    {:ok, _} = Roles.assign_role(user, role.name)

    {ref, token} = session_fixture(user)
    chat = conversation_fixture(user)
    :ok = Conversations.subscribe(ref, chat.uuid, @me)

    %{user: user, role: role, ref: ref, token: token, chat: chat}
  end

  # The test tools' module may (or may not) let a live session write
  # (`api_session_write_modules`, the "Agent may act" box of Settings -> API).
  defp open_writes(true),
    do: {:ok, _} = Settings.update_setting("api_session_write_modules", "agent_test_tools")

  defp open_writes(false),
    do: Repo.delete_all(from(s in Setting, where: s.key == "api_session_write_modules"))

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

  defp answer_next(answer) do
    test = self()

    Req.Test.expect(@stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:model_request, Jason.decode!(raw)})
      Req.Test.json(conn, answer)
    end)
  end

  # ── helpers ─────────────────────────────────────────────────────────

  defp run_turn(ctx, text) do
    assert {:ok, turn_ref} = Turns.start(ctx.ref, false, ctx.chat.uuid, text, [], [])
    chat_uuid = ctx.chat.uuid
    assert_receive {:agent_turn_finished, ^chat_uuid, ^turn_ref}, 5_000
    turn_ref
  end

  # A turn whose model asks for one write; returns the tool message of its
  # card, the chat's last.
  defp card!(ctx, args \\ %{"name" => "new"}) do
    before = length(cards(ctx.chat))
    answer_next(tool_answer([call("w1", @write, args)]))
    run_turn(ctx, "Rename the item")
    assert_received {:model_request, _body}
    assert_received {:agent_test_preview, _input}
    assert length(cards(ctx.chat)) == before + 1
    List.last(cards(ctx.chat))
  end

  # Spent by core, as by a click that was lost before it wrote its notice.
  defp spend!(uuid) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update_all(from(c in Confirmation, where: c.uuid == ^uuid),
      set: [status: "used", used_at: now]
    )
  end

  # Waits up to 2 s for `fun` to be true (a keep runs on a timer).
  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        receive do
        after
          20 -> eventually(fun, tries - 1)
        end
    end
  end

  defp messages(chat) do
    Repo.all(
      from(m in Message,
        where: m.conversation_uuid == ^chat.uuid,
        order_by: [asc: m.inserted_at, asc: m.uuid]
      )
    )
  end

  defp cards(chat),
    do:
      Enum.filter(
        messages(chat),
        &(&1.role == "tool" and &1.tool_outcome == "needs_confirmation")
      )

  defp outcome_notices(chat),
    do: Enum.filter(messages(chat), &(&1.role == "notice" and &1.confirmation_uuid != nil))

  defp row(uuid), do: Repo.get!(Confirmation, uuid)

  defp expire!(uuid) do
    past = DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:second)
    Repo.update_all(from(c in Confirmation, where: c.uuid == ^uuid), set: [expires_at: past])
  end

  defp written, do: Settings.get_setting("agenttest_written")

  defp confirm(ctx, card, opts \\ []),
    do: Confirmations.confirm(ctx.ref, false, ctx.chat.uuid, card.uuid, opts)

  defp card_state(ctx, card) do
    assert {:ok, %{} = by_uuid} = Confirmations.cards(ctx.ref, false, ctx.chat.uuid, [card])
    Map.fetch!(by_uuid, card.uuid)
  end

  # ── the turn ────────────────────────────────────────────────────────

  describe "a write asked for in a turn" do
    test "the model sees the write tool only when its module lets a session write", ctx do
      answer_next(text_answer("ok"))
      run_turn(ctx, "Hi")
      assert_received {:model_request, open}
      assert @write in Enum.map(open["tools"], & &1["function"]["name"])

      open_writes(false)
      answer_next(text_answer("ok"))
      run_turn(ctx, "Hi again")
      assert_received {:model_request, closed}
      refute @write in Enum.map(closed["tools"] || [], & &1["function"]["name"])
    end

    test "a write of a module that is not opened is denied: no preview, no card", ctx do
      open_writes(false)
      answer_next(tool_answer([call("w1", @write, %{"name" => "x"})]))
      answer_next(text_answer("I cannot."))

      run_turn(ctx, "Rename")

      refute_received {:agent_test_preview, _}

      assert [%Message{tool_outcome: "denied"}] =
               Enum.filter(messages(ctx.chat), &(&1.role == "tool"))

      assert cards(ctx.chat) == []
    end

    test "dry_run: false and confirm_token are cut: a preview, a card, nothing written", ctx do
      args = %{"name" => "new", "dry_run" => false, "confirm_token" => "forged-token"}
      answer_next(tool_answer([call("w1", @write, args)]))
      run_turn(ctx, "Rename the item")
      [card] = cards(ctx.chat)

      assert_received {:agent_test_preview, %{"name" => "new"} = input}
      refute Map.has_key?(input, "dry_run")
      refute Map.has_key?(input, "confirm_token")
      refute_received {:agent_test_tool, "agenttest.write_item", _, _}
      assert written() == nil

      assert card.tool_name == "agenttest.write_item"
      assert card.tool_call_id == "w1"
      assert is_binary(card.confirmation_uuid)
      assert %Message{role: "assistant"} = Repo.get!(Message, card.assistant_message_uuid)

      # Only the uuid of the confirmation: no code, no preview, no arguments.
      assert card.tool_result == %{
               "status" => "confirmation_required",
               "confirmation_id" => card.confirmation_uuid
             }

      assert row(card.confirmation_uuid).status == "unused"
      assert row(card.confirmation_uuid).actor_user_uuid == ctx.user.uuid
    end

    test "the turn ends with the card: the model is not called again", ctx do
      answer_next(
        tool_answer([
          call("r1", "agenttest_list_items", %{"query" => "chairs"}),
          call("w1", @write, %{"name" => "new"})
        ])
      )

      run_turn(ctx, "List and rename")

      assert_received {:model_request, _first}
      refute_received {:model_request, _second}

      # The read of the same round ran; the last message is the card.
      assert_received {:agent_test_tool, "agenttest.list_items", _, _}

      assert %Message{role: "tool", tool_outcome: "needs_confirmation"} =
               List.last(messages(ctx.chat))

      refute Enum.any?(messages(ctx.chat), &(&1.role == "assistant" and is_binary(&1.content)))
      assert %UserSettings{busy_turn_ref: nil} = Repo.get!(UserSettings, ctx.user.uuid)
    end

    test "a second write of the round is denied: confirm the first one first", ctx do
      answer_next(
        tool_answer([
          call("w1", @write, %{"name" => "first"}),
          call("w2", @write, %{"name" => "second"})
        ])
      )

      run_turn(ctx, "Rename twice")

      assert_received {:agent_test_preview, %{"name" => "first"}}
      refute_received {:agent_test_preview, %{"name" => "second"}}

      tools = Enum.filter(messages(ctx.chat), &(&1.role == "tool"))

      assert Enum.map(tools, &{&1.tool_call_id, &1.tool_outcome}) == [
               {"w1", "needs_confirmation"},
               {"w2", "denied"}
             ]

      assert [_one] =
               Repo.all(from(c in Confirmation, where: c.actor_user_uuid == ^ctx.user.uuid))

      assert %{"error" => "denied", "message" => message} = List.last(tools).tool_result
      assert message =~ "Confirm"
    end

    test "a read after the held write of the same answer is denied: it is not run", ctx do
      answer_next(
        tool_answer([
          call("w1", @write, %{"name" => "new"}),
          call("r1", "agenttest_list_items", %{"query" => "chairs"})
        ])
      )

      run_turn(ctx, "Rename and list")

      assert_received {:model_request, _first}
      refute_received {:model_request, _second}
      refute_received {:agent_test_tool, "agenttest.list_items", _, _}

      tools = Enum.filter(messages(ctx.chat), &(&1.role == "tool"))

      assert Enum.map(tools, &{&1.tool_call_id, &1.tool_outcome}) == [
               {"w1", "needs_confirmation"},
               {"r1", "denied"}
             ]

      assert %{"error" => "denied", "message" => message} = List.last(tools).tool_result
      assert message =~ "held for confirmation"
    end

    test "a card still waiting is in the next turn's history; settled, its outcome only",
         ctx do
      card = card!(ctx)
      waiting = %{"role" => "user", "content" => "[confirmation] waiting: agenttest_write_item"}

      answer_next(text_answer("It waits for you."))
      run_turn(ctx, "Well?")
      assert_received {:model_request, body}

      # Where the card stands: after the message that asked for it.
      assert [
               {"user", "Rename the item"},
               {"user", "[confirmation] waiting: agenttest_write_item"},
               {"user", "Well?"}
             ] =
               for(
                 %{"role" => role, "content" => content} <- body["messages"],
                 role != "system",
                 do: {role, content}
               )

      refute Jason.encode!(body["messages"]) =~ card.confirmation_uuid

      assert {:ok, :confirmed} = confirm(ctx, card)
      answer_next(text_answer("Good."))
      run_turn(ctx, "And now?")
      assert_received {:model_request, settled}

      refute waiting in settled["messages"]

      assert %{"role" => "user", "content" => "[confirmation] done: agenttest_write_item"} in settled[
               "messages"
             ]
    end

    test "the same write again while its card waits is denied: no second card", ctx do
      card = card!(ctx)

      answer_next(tool_answer([call("w2", @write, %{"name" => "new"})]))
      answer_next(text_answer("It already waits for you."))
      run_turn(ctx, "Did you do it?")

      refute_received {:agent_test_preview, _}
      assert Enum.map(cards(ctx.chat), & &1.uuid) == [card.uuid]

      assert [_one] =
               Repo.all(from(c in Confirmation, where: c.actor_user_uuid == ^ctx.user.uuid))

      denied = List.last(Enum.filter(messages(ctx.chat), &(&1.role == "tool")))
      assert %Message{tool_call_id: "w2", tool_outcome: "denied"} = denied
      assert denied.tool_result["message"] =~ "already waiting for confirmation"

      # Nothing waits in this round: the model is called again, and answers.
      assert_received {:model_request, _first}
      assert_received {:model_request, _second}

      # Other arguments are another change: a card of their own.
      other = card!(ctx, %{"name" => "other"})
      assert other.uuid != card.uuid
    end

    test "a settled card no longer blocks the same write: it gets a card again", ctx do
      card = card!(ctx)
      assert {:ok, :rejected} = Confirmations.reject(ctx.ref, false, ctx.chat.uuid, card.uuid)

      again = card!(ctx)
      assert again.uuid != card.uuid
      assert again.confirmation_uuid != card.confirmation_uuid
    end

    test "waiting_same?/3: the same tool and arguments, of a card core still holds", ctx do
      card = card!(ctx)
      turn = %{session_ref: ctx.ref, user_uuid: ctx.user.uuid, conversation_uuid: ctx.chat.uuid}

      assert Confirmations.waiting_same?(turn, "agenttest.write_item", %{"name" => "new"})
      refute Confirmations.waiting_same?(turn, "agenttest.write_item", %{"name" => "other"})
      refute Confirmations.waiting_same?(turn, "agenttest.list_items", %{"name" => "new"})

      # Its row ran out: nothing waits, whatever the chat says.
      expire!(card.confirmation_uuid)
      refute Confirmations.waiting_same?(turn, "agenttest.write_item", %{"name" => "new"})
    end

    test "a row core spent with no notice: the next turn closes it as done and says so",
         ctx do
      card = card!(ctx)
      spend!(card.confirmation_uuid)

      answer_next(text_answer("Done, then."))
      run_turn(ctx, "Well?")
      assert_received {:model_request, body}

      contents = Enum.map(body["messages"], & &1["content"])
      assert "[confirmation] done: agenttest_write_item" in contents
      refute "[confirmation] waiting: agenttest_write_item" in contents

      assert [%Message{tool_outcome: "confirmed"} = notice] = outcome_notices(ctx.chat)
      assert notice.confirmation_uuid == card.confirmation_uuid
      refute_received {:agent_test_tool, "agenttest.write_item", _, _}
    end

    test "a card that ran out with no notice: the next turn closes it as expired, and the " <>
           "same write is a new card",
         ctx do
      card = card!(ctx)
      expire!(card.confirmation_uuid)

      answer_next(tool_answer([call("w2", @write, %{"name" => "new"})]))
      run_turn(ctx, "Try again")
      assert_received {:model_request, body}

      contents = Enum.map(body["messages"], & &1["content"])
      assert "[confirmation] expired, nothing was done: agenttest_write_item" in contents
      refute "[confirmation] waiting: agenttest_write_item" in contents

      assert [%Message{tool_outcome: "expired"}] = outcome_notices(ctx.chat)
      assert [_old, fresh] = cards(ctx.chat)
      assert fresh.tool_call_id == "w2"
    end

    test "a write whose call id is not unique in the answer is denied", ctx do
      answer_next(
        tool_answer([
          call("same", "agenttest_list_items", %{}),
          call("same", @write, %{"name" => "new"})
        ])
      )

      answer_next(text_answer("Done."))
      run_turn(ctx, "Twice")

      refute_received {:agent_test_preview, _}
      assert cards(ctx.chat) == []
    end

    test "the next turn's history has no token, no preview and no tool result", ctx do
      card = card!(ctx)
      assert {:ok, :confirmed} = confirm(ctx, card)

      answer_next(text_answer("Anything else?"))
      run_turn(ctx, "Thanks")
      assert_received {:model_request, body}

      json = Jason.encode!(body["messages"])
      refute json =~ card.confirmation_uuid
      refute json =~ "confirmation_required"
      refute json =~ "\"rows\""
      refute Enum.any?(body["messages"], &(&1["role"] == "tool"))

      # The outcome is said in the module's own words, as a user message.
      assert %{"role" => "user", "content" => "[confirmation] done: agenttest_write_item"} in body[
               "messages"
             ]
    end

    test "the outcome is said in the user's language; other notices stay out", ctx do
      card = card!(ctx)
      assert {:ok, :rejected} = Confirmations.reject(ctx.ref, false, ctx.chat.uuid, card.uuid)

      {:ok, _} =
        Conversations.add_turn_message(ctx.user.uuid, ctx.chat.uuid, %{
          role: "notice",
          content: "OTHER-NOTICE",
          error: "empty_answer"
        })

      Gettext.put_locale(PhoenixKitAgent.Gettext, "ru")
      on_exit(fn -> Gettext.put_locale(PhoenixKitAgent.Gettext, "en") end)

      answer_next(text_answer("Хорошо."))
      run_turn(ctx, "Ладно")
      assert_received {:model_request, body}

      assert %{"role" => "user", "content" => "[подтверждение] отменено: agenttest_write_item"} in body[
               "messages"
             ]

      refute Jason.encode!(body["messages"]) =~ "OTHER-NOTICE"
    end
  end

  # ── the click ───────────────────────────────────────────────────────

  describe "confirm/5" do
    test "runs the write, notices confirmed, calls no model and spends no turn", ctx do
      card = card!(ctx)
      turns_before = Repo.aggregate(from(m in Message, where: m.role == "user"), :count)

      assert {:ok, :confirmed} = confirm(ctx, card)

      assert written() == "new"
      assert_received {:agent_test_tool, "agenttest.write_item", %{"name" => "new"}, tool_ctx}
      assert tool_ctx.confirmation_uuid == card.confirmation_uuid
      assert row(card.confirmation_uuid).status == "used"

      assert [notice] = outcome_notices(ctx.chat)
      assert notice.confirmation_uuid == card.confirmation_uuid
      assert notice.tool_outcome == "confirmed"
      assert notice.tool_name == "agenttest.write_item"
      assert notice.tool_result == nil

      refute_received {:model_request, _}
      assert Repo.aggregate(from(m in Message, where: m.role == "user"), :count) == turns_before
      assert %{state: "confirmed", repeatable?: false} = card_state(ctx, card)
    end

    test "core's audit names the assistant as what asked, without the input", ctx do
      card = card!(ctx, %{"name" => "AUDIT-SECRET"})
      assert {:ok, :confirmed} = confirm(ctx, card)

      user_uuid = ctx.user.uuid

      entries =
        Repo.all(
          from(e in PhoenixKit.Activity.Entry,
            where: e.action == "api.request" and e.actor_uuid == ^user_uuid
          )
        )

      assert [_ | _] = entries
      assert Enum.all?(entries, &(&1.metadata["via"] == "agent"))
      assert Enum.any?(entries, &(&1.metadata["confirmation_uuid"] == card.confirmation_uuid))
      refute Jason.encode!(Enum.map(entries, & &1.metadata)) =~ "AUDIT-SECRET"
    end

    test "the click frees the user's lock it took", ctx do
      card = card!(ctx)
      assert {:ok, :confirmed} = confirm(ctx, card)
      assert %UserSettings{busy_turn_ref: nil} = Repo.get!(UserSettings, ctx.user.uuid)
    end

    test "a second click runs nothing again", ctx do
      card = card!(ctx)
      assert {:ok, :confirmed} = confirm(ctx, card)
      assert {:error, :not_waiting} = confirm(ctx, card)

      assert_received {:agent_test_tool, "agenttest.write_item", _, _}
      refute_received {:agent_test_tool, "agenttest.write_item", _, _}
      assert [_one] = outcome_notices(ctx.chat)
    end

    test "while a turn of the user runs, the click is refused and the card waits", ctx do
      card = card!(ctx)
      other = conversation_fixture(ctx.user)
      :ok = Locks.acquire(ctx.user.uuid, other.uuid, "a-turn", 600)

      assert {:error, :turn_running} = confirm(ctx, card)

      assert written() == nil
      assert row(card.confirmation_uuid).status == "unused"
      assert outcome_notices(ctx.chat) == []
      assert %{state: "waiting"} = card_state(ctx, card)
    end

    test "after its time: expired, nothing written, and it can be asked for again", ctx do
      card = card!(ctx)
      expire!(card.confirmation_uuid)

      assert {:ok, :expired} = confirm(ctx, card)
      assert written() == nil
      assert [%Message{tool_outcome: "expired"}] = outcome_notices(ctx.chat)
      assert %{state: "expired", repeatable?: true} = card_state(ctx, card)

      assert {:ok, :repeated} = Confirmations.repeat(ctx.ref, false, ctx.chat.uuid, card.uuid)

      assert [old, fresh] = cards(ctx.chat)
      assert old.uuid == card.uuid
      assert fresh.confirmation_uuid != card.confirmation_uuid
      assert fresh.assistant_message_uuid == card.assistant_message_uuid
      assert fresh.tool_call_id == card.tool_call_id
      assert %{state: "expired", repeatable?: false} = card_state(ctx, card)
      assert %{state: "waiting"} = card_state(ctx, fresh)

      assert {:ok, :confirmed} = confirm(ctx, fresh)
      assert written() == "new"
    end

    test "the data changed since the preview: a new card, nothing written", ctx do
      card = card!(ctx)
      {:ok, _} = Settings.update_setting("agenttest_written", "someone else's")

      assert {:ok, :changed} = confirm(ctx, card)

      assert written() == "someone else's"
      refute_received {:agent_test_tool, "agenttest.write_item", _, _}
      assert [%Message{tool_outcome: "changed"} = notice] = outcome_notices(ctx.chat)
      assert [_old, fresh] = cards(ctx.chat)
      # The notice and the new card right after it, stored together.
      assert [^notice, ^fresh] = Enum.take(messages(ctx.chat), -2)
      assert fresh.assistant_message_uuid == card.assistant_message_uuid
      assert row(card.confirmation_uuid).status == "expired"

      assert %{state: "changed"} = card_state(ctx, card)
      assert %{state: "waiting", preview: preview} = card_state(ctx, fresh)
      assert %{"rows" => [%{"changes" => %{"name" => %{"from" => "someone else's"}}}]} = preview
    end

    test "a new card that cannot be stored takes its notice with it: nothing half-written",
         ctx do
      card = card!(ctx)
      {:ok, _} = Settings.update_setting("agenttest_written", "someone else's")

      # The database refuses a card that no turn writes (the click's new one),
      # for this test only (the sandbox rolls it back).
      Repo.query!("""
      CREATE FUNCTION agent_test_refuse_card() RETURNS trigger LANGUAGE plpgsql
      AS $$ BEGIN RAISE EXCEPTION 'no card here'; END $$
      """)

      Repo.query!("""
      CREATE TRIGGER agent_test_refuse_card BEFORE INSERT ON phoenix_kit_agent_messages
      FOR EACH ROW WHEN (NEW.role = 'tool' AND NEW.turn_ref IS NULL)
      EXECUTE FUNCTION agent_test_refuse_card()
      """)

      assert_raise Postgrex.Error, fn -> confirm(ctx, card) end

      assert outcome_notices(ctx.chat) == []
      assert Enum.map(cards(ctx.chat), & &1.uuid) == [card.uuid]
      assert %UserSettings{busy_turn_ref: nil} = Repo.get!(UserSettings, ctx.user.uuid)
    end

    test "a row core spent with no notice here (its click was lost): confirmed, not run again",
         ctx do
      card = card!(ctx)
      spend!(card.confirmation_uuid)

      assert {:ok, :confirmed} = confirm(ctx, card)

      refute_received {:agent_test_tool, "agenttest.write_item", _, _}
      assert [%Message{tool_outcome: "confirmed"}] = outcome_notices(ctx.chat)
      assert %{state: "confirmed"} = card_state(ctx, card)
    end

    test "a notice that cannot be stored: the click says so, nothing claims it was noted",
         ctx do
      card = card!(ctx)
      chat_uuid = ctx.chat.uuid

      # The chat is deleted while the handler runs: the notice has nowhere to go.
      Application.put_env(:phoenix_kit_agent, :test_tool_hook, fn "agenttest.write_item",
                                                                  _input ->
        Repo.update_all(
          from(c in PhoenixKitAgent.Schemas.Conversation, where: c.uuid == ^chat_uuid),
          set: [status: "deleted"]
        )
      end)

      on_exit(fn -> Application.delete_env(:phoenix_kit_agent, :test_tool_hook) end)

      {result, _events} = LogProbe.capture(fn -> confirm(ctx, card) end)

      assert {:error, :not_stored} = result
      assert written() == "new"
      assert outcome_notices(ctx.chat) == []
    end

    test "a row core has deleted: expired, nothing written", ctx do
      card = card!(ctx)
      Repo.delete_all(from(c in Confirmation, where: c.uuid == ^card.confirmation_uuid))

      assert {:ok, :expired} = confirm(ctx, card)
      assert written() == nil
      assert [%Message{tool_outcome: "expired"}] = outcome_notices(ctx.chat)
    end

    test "a click keeps the user's lock for as long as it runs: no turn, no other click",
         ctx do
      card = card!(ctx)
      test = self()

      Application.put_env(:phoenix_kit_agent, :click_keep_ms, 10)

      Application.put_env(:phoenix_kit_agent, :test_tool_hook, fn "agenttest.write_item",
                                                                  _input ->
        send(test, {:writing, self()})

        receive do
          :go -> :ok
        after
          5_000 -> :ok
        end
      end)

      on_exit(fn ->
        Application.delete_env(:phoenix_kit_agent, :click_keep_ms)
        Application.delete_env(:phoenix_kit_agent, :test_tool_hook)
      end)

      click = Task.async(fn -> confirm(ctx, card) end)
      assert_receive {:writing, writer}, 5_000

      # The lock as if taken an hour ago: only its keeping holds it now.
      Repo.update_all(from(s in UserSettings, where: s.user_uuid == ^ctx.user.uuid),
        set: [busy_since: DateTime.add(DateTime.utc_now(), -3_600, :second)]
      )

      stale = DateTime.add(DateTime.utc_now(), -Turns.lock_ttl_s(), :second)

      assert eventually(fn ->
               since = Repo.get!(UserSettings, ctx.user.uuid).busy_since
               DateTime.compare(since, stale) == :gt
             end)

      assert {:error, :click_in_flight} =
               Turns.start(ctx.ref, false, ctx.chat.uuid, "Is it done?", [], [])

      assert {:error, :click_running} =
               Confirmations.reject(ctx.ref, false, ctx.chat.uuid, card.uuid)

      send(writer, :go)
      assert {:ok, :confirmed} = Task.await(click, 5_000)
      assert written() == "new"
      assert %UserSettings{busy_turn_ref: nil} = Repo.get!(UserSettings, ctx.user.uuid)
    end

    test "a refusal before the confirmation is spent leaves the card waiting", ctx do
      card = card!(ctx)

      # The module's box was cleared after the card was made.
      open_writes(false)
      assert {:error, {:refused, :module_write_disabled}} = confirm(ctx, card)
      open_writes(true)

      # The person lost the permission the tool needs.
      :ok = Permissions.revoke_permission(ctx.role.uuid, "dashboard")
      assert {:error, {:refused, :forbidden}} = confirm(ctx, card)
      {:ok, _} = Permissions.grant_permission(ctx.role.uuid, "dashboard")

      assert written() == nil
      assert outcome_notices(ctx.chat) == []
      assert row(card.confirmation_uuid).status == "unused"
      assert %{state: "waiting"} = card_state(ctx, card)

      assert {:ok, :confirmed} = confirm(ctx, card)
    end

    test "a handler that refuses its dry run now leaves the card waiting", ctx do
      card = card!(ctx)
      {:ok, _} = Settings.update_setting("agenttest_locked", "yes")

      assert {:error, {:refused, :conflict}} = confirm(ctx, card)
      assert written() == nil
      assert outcome_notices(ctx.chat) == []
      assert row(card.confirmation_uuid).status == "unused"
      assert %{state: "waiting"} = card_state(ctx, card)
    end

    test "a handler that fails after the confirmation is spent: failed", ctx do
      card = card!(ctx, %{"name" => "fail"})

      assert {:ok, :failed} = confirm(ctx, card)
      assert [%Message{tool_outcome: "failed"}] = outcome_notices(ctx.chat)
      assert row(card.confirmation_uuid).status == "used"
      assert %{state: "failed", repeatable?: false} = card_state(ctx, card)
    end

    test "another user's session cannot confirm, reject or repeat it", ctx do
      card = card!(ctx)
      stranger = user_with(["agent", "dashboard"], "stranger")
      {stranger_ref, _token} = session_fixture(stranger)

      for action <- [:confirm, :reject, :repeat] do
        assert {:error, :not_found} =
                 apply(Confirmations, action, [stranger_ref, false, ctx.chat.uuid, card.uuid])
      end

      assert {:error, :not_found} =
               Confirmations.cards(stranger_ref, false, ctx.chat.uuid, [card])

      assert written() == nil
      assert row(card.confirmation_uuid).status == "unused"
      assert outcome_notices(ctx.chat) == []
    end

    test "an impersonated session is refused before anything is read", ctx do
      card = card!(ctx)

      for action <- [:confirm, :reject, :repeat] do
        assert {:error, :impersonated} =
                 apply(Confirmations, action, [ctx.ref, true, ctx.chat.uuid, card.uuid])
      end

      assert {:error, :impersonated} = Confirmations.cards(ctx.ref, true, ctx.chat.uuid, [card])
      assert row(card.confirmation_uuid).status == "unused"
    end

    test "a revoked session is refused, the card waits", ctx do
      card = card!(ctx)
      :ok = Auth.delete_user_session_token(ctx.token)

      assert {:error, :session_gone} = confirm(ctx, card)
      assert row(card.confirmation_uuid).status == "unused"
    end

    test "a message that is not a card is not confirmed", ctx do
      answer_next(text_answer("Hello."))
      run_turn(ctx, "Hi")
      [user_message | _] = messages(ctx.chat)

      assert {:error, :not_waiting} =
               Confirmations.confirm(ctx.ref, false, ctx.chat.uuid, user_message.uuid)

      assert {:error, :not_waiting} =
               Confirmations.confirm(ctx.ref, false, ctx.chat.uuid, Ecto.UUID.generate())
    end

    test "nothing of the write reaches the log: not the arguments, not the preview", ctx do
      {result, events} =
        LogProbe.capture(fn ->
          card = card!(ctx, %{"name" => "SECRET-NAME-42"})
          {confirm(ctx, card), Confirmations.cards(ctx.ref, false, ctx.chat.uuid, [card])}
        end)

      assert {{:ok, :confirmed}, {:ok, _cards}} = result

      # Not the module's: the test tool's own write of its setting (core's
      # settings log it).
      leaks =
        events
        |> Enum.filter(&(&1 =~ "SECRET-NAME-42"))
        |> Enum.reject(&(&1 =~ "agenttest_written"))

      assert leaks == []
    end
  end

  describe "reject/5" do
    test "turns it down: rejected, nothing written, and it cannot be confirmed after", ctx do
      card = card!(ctx)

      assert {:ok, :rejected} = Confirmations.reject(ctx.ref, false, ctx.chat.uuid, card.uuid)

      assert row(card.confirmation_uuid).status == "rejected"
      assert [%Message{tool_outcome: "rejected"}] = outcome_notices(ctx.chat)
      assert {:error, :not_waiting} = confirm(ctx, card)
      assert written() == nil
      assert %{state: "rejected", repeatable?: false} = card_state(ctx, card)
    end

    test "a row core spent with no notice here: confirmed, the right to its tool or not",
         ctx do
      card = card!(ctx)
      spend!(card.confirmation_uuid)

      # The person may no longer write with the tool: core's card read is
      # withheld, the user's own row still says it was spent.
      :ok = Permissions.revoke_permission(ctx.role.uuid, "dashboard")

      assert {:ok, :confirmed} = Confirmations.reject(ctx.ref, false, ctx.chat.uuid, card.uuid)
      assert [%Message{tool_outcome: "confirmed"}] = outcome_notices(ctx.chat)
      refute_received {:agent_test_tool, "agenttest.write_item", _, _}
    end

    test "a card whose tool the user may no longer use can still be cancelled", ctx do
      card = card!(ctx)
      :ok = Permissions.revoke_permission(ctx.role.uuid, "dashboard")

      assert %{state: "unavailable", rejectable?: true, preview: nil, arguments: nil} =
               card_state(ctx, card)

      assert {:error, {:refused, :forbidden}} = confirm(ctx, card)
      assert {:ok, :rejected} = Confirmations.reject(ctx.ref, false, ctx.chat.uuid, card.uuid)
      assert row(card.confirmation_uuid).status == "rejected"
      assert %{state: "rejected", rejectable?: false} = card_state(ctx, card)
    end

    test "a card past its time is closed as expired", ctx do
      card = card!(ctx)
      expire!(card.confirmation_uuid)
      assert {:ok, :expired} = Confirmations.reject(ctx.ref, false, ctx.chat.uuid, card.uuid)
      assert [%Message{tool_outcome: "expired"}] = outcome_notices(ctx.chat)
    end
  end

  describe "repeat/5" do
    test "an expired card cannot duplicate the same write waiting from a later turn", ctx do
      old = card!(ctx)
      expire!(old.confirmation_uuid)
      fresh = card!(ctx)

      assert old.assistant_message_uuid != fresh.assistant_message_uuid
      assert %{state: "waiting"} = card_state(ctx, fresh)
      assert %{state: "expired", repeatable?: false} = card_state(ctx, old)

      assert {:error, :already_waiting} =
               Confirmations.repeat(ctx.ref, false, ctx.chat.uuid, old.uuid)

      # The check also holds before the expired card's notice was settled.
      Repo.delete_all(
        from(m in Message,
          where: m.confirmation_uuid == ^old.confirmation_uuid and m.role == "notice"
        )
      )

      assert {:error, :already_waiting} =
               Confirmations.repeat(ctx.ref, false, ctx.chat.uuid, old.uuid)

      assert Enum.map(cards(ctx.chat), & &1.uuid) == [old.uuid, fresh.uuid]
      assert outcome_notices(ctx.chat) == []
      refute_received {:agent_test_preview, _}
      assert %UserSettings{busy_turn_ref: nil} = Repo.get!(UserSettings, ctx.user.uuid)

      # Once that proposal is cancelled, the expired card can be used again.
      assert {:ok, :rejected} = Confirmations.reject(ctx.ref, false, ctx.chat.uuid, fresh.uuid)
      assert %{state: "expired", repeatable?: true} = card_state(ctx, old)
      assert {:ok, :repeated} = Confirmations.repeat(ctx.ref, false, ctx.chat.uuid, old.uuid)
    end

    test "is refused for a card still waiting", ctx do
      card = card!(ctx)

      assert {:error, :not_expired} =
               Confirmations.repeat(ctx.ref, false, ctx.chat.uuid, card.uuid)

      assert [_only] = cards(ctx.chat)
    end

    test "is refused with the reason when the user may no longer use its tool", ctx do
      card = card!(ctx)
      expire!(card.confirmation_uuid)
      :ok = Permissions.revoke_permission(ctx.role.uuid, "dashboard")

      assert {:error, {:refused, :forbidden}} =
               Confirmations.repeat(ctx.ref, false, ctx.chat.uuid, card.uuid)

      assert [_only] = cards(ctx.chat)
    end

    test "a card whose row core has deleted is asked for again too", ctx do
      card = card!(ctx)
      Repo.delete_all(from(c in Confirmation, where: c.uuid == ^card.confirmation_uuid))

      assert %{state: "expired", repeatable?: true} = card_state(ctx, card)
      assert {:ok, :repeated} = Confirmations.repeat(ctx.ref, false, ctx.chat.uuid, card.uuid)
      assert [_old, _fresh] = cards(ctx.chat)
      assert [%Message{tool_outcome: "expired"}] = outcome_notices(ctx.chat)
    end
  end

  describe "settle_lapsed/3" do
    test "closes the cards core no longer holds, by what core says; one that waits stays",
         ctx do
      spent = card!(ctx, %{"name" => "spent"})
      turned_down = card!(ctx, %{"name" => "turned down"})
      late = card!(ctx, %{"name" => "late"})
      gone = card!(ctx, %{"name" => "gone"})
      waiting = card!(ctx, %{"name" => "waiting"})

      spend!(spent.confirmation_uuid)

      Repo.update_all(from(c in Confirmation, where: c.uuid == ^turned_down.confirmation_uuid),
        set: [status: "rejected"]
      )

      expire!(late.confirmation_uuid)
      Repo.delete_all(from(c in Confirmation, where: c.uuid == ^gone.confirmation_uuid))

      assert :ok = Confirmations.settle_lapsed(ctx.ref, false, ctx.chat.uuid)

      assert ctx.chat |> outcome_notices() |> Map.new(&{&1.confirmation_uuid, &1.tool_outcome}) ==
               %{
                 spent.confirmation_uuid => "confirmed",
                 turned_down.confirmation_uuid => "rejected",
                 late.confirmation_uuid => "expired",
                 gone.confirmation_uuid => "expired"
               }

      assert {:ok, [still]} = Confirmations.waiting_cards(ctx.ref, false, ctx.chat.uuid)
      assert still.uuid == waiting.uuid
      assert %{state: "expired", repeatable?: true} = card_state(ctx, late)

      # Once is enough: nothing is closed twice.
      assert :ok = Confirmations.settle_lapsed(ctx.ref, false, ctx.chat.uuid)
      assert length(outcome_notices(ctx.chat)) == 4
      assert %UserSettings{busy_turn_ref: nil} = Repo.get!(UserSettings, ctx.user.uuid)
    end

    test "writes nothing while a turn or a click holds the lock; needs no lock for nothing",
         ctx do
      card = card!(ctx)
      other = conversation_fixture(ctx.user)
      :ok = Locks.acquire(ctx.user.uuid, other.uuid, "a-turn", 600)

      # Nothing lapsed: no lock is asked for.
      assert :ok = Confirmations.settle_lapsed(ctx.ref, false, ctx.chat.uuid)

      spend!(card.confirmation_uuid)
      assert {:error, :turn_running} = Confirmations.settle_lapsed(ctx.ref, false, ctx.chat.uuid)
      assert outcome_notices(ctx.chat) == []

      assert {:error, :impersonated} = Confirmations.settle_lapsed(ctx.ref, true, ctx.chat.uuid)
    end
  end

  describe "cards/4" do
    test "a waiting card: core's preview, the arguments as text, the time it runs out", ctx do
      card = card!(ctx, %{"name" => "<b>**bold**</b>"})

      assert %{
               state: "waiting",
               tool: "agenttest.write_item",
               preview: %{"rows" => [_]},
               arguments: arguments,
               expires_at: %DateTime{},
               repeatable?: false
             } = card_state(ctx, card)

      assert arguments =~ "<b>**bold**</b>"
      assert Confirm.get_for_user(card.confirmation_uuid, ctx.ref) |> elem(0) == :ok
    end

    test "waiting_cards/3: the cards that wait, in the whole chat, as a client sees them",
         ctx do
      first = card!(ctx, %{"name" => "first"})
      assert {:ok, :rejected} = Confirmations.reject(ctx.ref, false, ctx.chat.uuid, first.uuid)
      second = card!(ctx, %{"name" => "second"})

      assert {:ok, [waiting]} = Confirmations.waiting_cards(ctx.ref, false, ctx.chat.uuid)
      assert waiting.uuid == second.uuid
      assert waiting.tool_result == nil
      assert waiting.confirmation_uuid == second.confirmation_uuid

      assert {:error, :impersonated} = Confirmations.waiting_cards(ctx.ref, true, ctx.chat.uuid)

      stranger = user_with(["agent", "dashboard"], "stranger")
      {stranger_ref, _token} = session_fixture(stranger)

      assert {:error, :not_found} =
               Confirmations.waiting_cards(stranger_ref, false, ctx.chat.uuid)
    end

    test "a message of another chat of the user is no card here", ctx do
      card = card!(ctx)
      other = conversation_fixture(ctx.user)
      assert {:ok, %{} = none} = Confirmations.cards(ctx.ref, false, other.uuid, [card])
      assert none == %{}
    end
  end
end
