defmodule PhoenixKitAgent.Telegram.FlowTest do
  @moduledoc """
  A message of a linked chat from the bridge to the answer in the chat: the
  conversation, the turn of the user (with the model stubbed behind
  `phoenix_kit_ai`), the reactions, the queue of the chat and what is said
  when something goes wrong. The bot is `PhoenixKitAgent.Test.TelegramClient`:
  every call to Telegram comes to the test as `{:tg, call}`.
  """

  use PhoenixKitAgent.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Integrations.Telegram.Linking
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings
  alias PhoenixKitAgent.{Config, Conversations}
  alias PhoenixKitAgent.Schemas.{Conversation, Message, UserSettings}
  alias PhoenixKitAgent.Telegram.{Bridge, Format, Limiter, Texts}
  alias PhoenixKitAgent.Test.{LogProbe, TelegramClient, Tools}

  @stub __MODULE__
  @model "deepseek/deepseek-v4.1-flash"
  @chat 428_897_538

  setup do
    {:ok, _} = PhoenixKitAgent.enable_system()
    {:ok, _} = PhoenixKitAI.enable_system()
    :ok = ModuleRegistry.register(Tools)

    Req.Test.set_req_test_to_shared()
    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, @stub}, retry: false)
    TelegramClient.start()

    end_queues()

    on_exit(fn ->
      stop_all_turns()
      end_queues()
      TelegramClient.stop()
      ModuleRegistry.unregister(Tools)
      Application.delete_env(:phoenix_kit_ai, :req_options)
      Req.Test.set_req_test_to_private()
    end)

    endpoint = endpoint_fixture(%{model: @model})
    {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", endpoint.uuid)

    user = user_with(["agent", "agent.telegram", "dashboard"], "flow")
    connection = UUIDv7.generate()
    ref = telegram_link_fixture(user, connection, @chat)
    Limiter.clear_unlinked(connection)

    %{user: user, connection: connection, ref: ref, endpoint: endpoint}
  end

  # ── helpers ─────────────────────────────────────────────────────────

  defp answer(text) do
    %{
      "model" => @model,
      "choices" => [%{"message" => %{"role" => "assistant", "content" => text}}],
      "usage" => %{"prompt_tokens" => 11, "completion_tokens" => 4, "total_tokens" => 15}
    }
  end

  defp model_says(text) do
    Req.Test.expect(@stub, fn conn -> Req.Test.json(conn, answer(text)) end)
  end

  defp model_hangs do
    test = self()

    Req.Test.expect(@stub, fn conn ->
      send(test, {:model_waiting, self()})

      receive do
        :release -> Req.Test.json(conn, answer("Finally."))
      end
    end)
  end

  defp send_update(ctx, text, opts \\ []) do
    Bridge.dispatch(ctx.connection, TelegramClient.update(@chat, text, opts))
  end

  # The calls to the bot, in order, until `done` matches one; typing is left out.
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

  defp texts(calls), do: for({:send_message, _, _, text} <- calls, do: text)
  defp emojis(calls), do: for({:react, _, _, _, emoji} <- calls, do: emoji)

  # The queues of earlier tests, and the turns and replies they started, end
  # with the test: a turn left waiting for a model would answer into the next.
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

  # Until the jobs and replies the bridge started have ended (what they log
  # and send is all there by then); no sleeping on a guess.
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

  defp set_locale(user, locale) do
    fresh = Repo.get!(PhoenixKit.Users.Auth.User, user.uuid)
    fields = Map.put(fresh.custom_fields || %{}, "preferred_locale", locale)

    Repo.update_all(from(u in PhoenixKit.Users.Auth.User, where: u.uuid == ^user.uuid),
      set: [custom_fields: fields]
    )
  end

  # ── the happy path ──────────────────────────────────────────────────

  describe "a question" do
    test "is answered: 👀, then the answer, then 👍, in the user's own conversation", ctx do
      model_says("You have three orders.")
      send_update(ctx, "How many orders?", message_id: 41)

      calls = calls_until(reaction?("👍"))

      assert emojis(calls) == ["👀", "👍"]
      assert texts(calls) == ["You have three orders."]
      assert Enum.all?(calls, &(elem(&1, 1) == ctx.connection))
      assert {:react, _, @chat, 41, "👀"} = hd(calls)

      assert %Conversation{metadata: %{"source" => "telegram", "chat_id" => @chat}} =
               chat = Conversations.latest_telegram_conversation(ctx.user.uuid)

      assert [%Message{role: "user", content: "How many orders?"}, %Message{role: "assistant"}] =
               Repo.all(
                 from(m in Message,
                   where: m.conversation_uuid == ^chat.uuid,
                   order_by: m.inserted_at
                 )
               )
    end

    test "the conversation is the user's own, whatever the update names", ctx do
      stranger = user_with(["agent"], "other")
      theirs = conversation_fixture(stranger)

      model_says("Mine.")

      send_update(ctx, "Hello",
        extra: %{"conversation_uuid" => theirs.uuid, "reply_to_message" => %{"message_id" => 1}}
      )

      calls_until(reaction?("👍"))

      mine = Conversations.latest_telegram_conversation(ctx.user.uuid)
      assert mine.uuid != theirs.uuid
      assert mine.user_uuid == ctx.user.uuid

      assert Repo.aggregate(
               from(m in Message, where: m.conversation_uuid == ^theirs.uuid),
               :count
             ) == 0
    end

    test "the next message continues the same conversation; /new starts another", ctx do
      model_says("First.")
      send_update(ctx, "One", message_id: 1)
      calls_until(reaction?("👍"))
      first = Conversations.latest_telegram_conversation(ctx.user.uuid)

      model_says("Second.")
      send_update(ctx, "Two", message_id: 2)
      calls_until(reaction?("👍"))
      assert Conversations.latest_telegram_conversation(ctx.user.uuid).uuid == first.uuid

      send_update(ctx, "/new", message_id: 3)
      calls = calls_until(reaction?("👍"))
      assert texts(calls) == [Texts.static(:new_started)]
      refute Conversations.latest_telegram_conversation(ctx.user.uuid).uuid == first.uuid
    end

    test "markdown is taken out and a long answer comes in parts", ctx do
      long = String.duplicate("word ", 1_100) |> String.trim()

      model_says(
        "## Orders\n\n**Three** orders, see [them](https://shop.example/admin/orders).\n\n" <>
          long
      )

      send_update(ctx, "Orders?")

      calls = calls_until(reaction?("👍"))
      parts = texts(calls)

      assert hd(parts) =~ "Orders\n\nThree orders, see them https://shop.example/admin/orders."
      assert length(parts) == 3
      assert Enum.all?(parts, &(Format.units(&1) <= 4_096))
    end

    test "two messages in a row are answered one after the other, in order", ctx do
      model_hangs()
      send_update(ctx, "First", message_id: 1)
      assert_receive {:model_waiting, first_model}, 5_000

      model_says("Second answer.")
      send_update(ctx, "Second", message_id: 2)
      refute_received {:tg, {:react, _, _, 2, _}}

      send(first_model, :release)
      calls = calls_until(&match?({:react, _, _, 2, "👍"}, &1))

      assert texts(calls) == ["Finally.", "Second answer."]

      assert [{1, "👀"}, {1, "👍"}, {2, "👀"}, {2, "👍"}] =
               for({:react, _, _, id, emoji} <- calls, do: {id, emoji})
    end

    test "the sixth message while one runs and three wait is told to wait", ctx do
      model_hangs()
      send_update(ctx, "One", message_id: 1)
      assert_receive {:model_waiting, _model}, 5_000

      for id <- 2..4, do: send_update(ctx, "Waiting #{id}", message_id: id)
      send_update(ctx, "Too many", message_id: 5)

      calls = calls_until(&match?({:react, _, _, 5, "🤷"}, &1))
      assert Texts.static(:wait) in texts(calls)
    end

    test "typing is shown while the agent works", ctx do
      model_hangs()
      send_update(ctx, "Slow", message_id: 1)

      assert_receive {:tg, {:typing, _, @chat}}, 5_000
      assert_receive {:model_waiting, model}, 5_000
      send(model, :release)
      calls_until(reaction?("👍"))
    end
  end

  # ── the user's own turn ─────────────────────────────────────────────

  describe "the turn is the user's own" do
    test "their model and their limits", ctx do
      own = endpoint_fixture(%{model: "mistralai/own-model"})
      Repo.insert!(%UserSettings{user_uuid: ctx.user.uuid, endpoint_uuid: own.uuid})

      test = self()

      Req.Test.expect(@stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:model_request, Jason.decode!(raw)})
        Req.Test.json(conn, answer("Own."))
      end)

      send_update(ctx, "Hi")
      calls_until(reaction?("👍"))

      assert_received {:model_request, %{"model" => "mistralai/own-model"}}
    end

    test "a used-up limit is told in the chat, with 🤷", ctx do
      Repo.insert!(%UserSettings{user_uuid: ctx.user.uuid, daily_turn_limit: 0})
      send_update(ctx, "Hi", message_id: 9)

      calls = calls_until(reaction?("🤷"))

      assert texts(calls) == ["You have used all your assistant turns for today."]
      assert emojis(calls) == ["👀", "🤷"]
    end

    test "no model: told so, with 🤷", ctx do
      {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", "")
      send_update(ctx, "Hi")

      calls = calls_until(reaction?("🤷"))
      assert [text] = texts(calls)
      assert text =~ "No model is chosen"
    end

    test "a turn running on the site: told it is answering elsewhere", ctx do
      {session, _token} = session_fixture(ctx.user)
      web_chat = conversation_fixture(ctx.user)
      model_hangs()
      assert {:ok, _} = PhoenixKitAgent.Turns.start(session, false, web_chat.uuid, "On the site")
      assert_receive {:model_waiting, model}, 5_000

      send_update(ctx, "In Telegram")
      calls = calls_until(reaction?("🤷"))
      assert texts(calls) == [Texts.refusal(:turn_in_flight)]

      send(model, :release)
    end

    test "a model error is a notice: 🤷 and the text of the notice", ctx do
      Req.Test.expect(@stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => %{"message" => "boom"}}))
      end)

      send_update(ctx, "Hi")
      calls = calls_until(reaction?("🤷"))

      assert [text] = texts(calls)
      assert text =~ "did not answer"
      refute text =~ "Stop"
    end

    test "a link dropped while the turn runs is told as 'not linked'", ctx do
      Req.Test.expect(@stub, fn conn ->
        calls = [
          %{
            "id" => "r1",
            "type" => "function",
            "function" => %{"name" => "agenttest_list_items", "arguments" => "{}"}
          }
        ]

        Req.Test.json(conn, %{
          "model" => @model,
          "choices" => [
            %{
              "message" => %{"role" => "assistant", "content" => nil, "tool_calls" => calls},
              "finish_reason" => "tool_calls"
            }
          ],
          "usage" => %{"prompt_tokens" => 20, "completion_tokens" => 9, "total_tokens" => 29}
        })
      end)

      Application.put_env(:phoenix_kit_agent, :test_tool_hook, fn _name, _input ->
        :ok = Linking.drop_links(ctx.user.uuid)
      end)

      on_exit(fn -> Application.delete_env(:phoenix_kit_agent, :test_tool_hook) end)

      send_update(ctx, "List things")
      calls = calls_until(reaction?("🤷"), 10_000)
      assert texts(calls) == [Texts.static(:unlinked)]
    end

    test "the user's language", ctx do
      set_locale(ctx.user, "ru")
      send_update(ctx, "/help")

      calls = calls_until(&match?({:send_message, _, _, _}, &1))
      assert [text] = texts(calls)
      refute text == Texts.static(:help)
      assert text =~ "Напишите"
    end
  end

  # ── what needs no turn ──────────────────────────────────────────────

  describe "replies without a turn" do
    test "help, forwarded, not text", ctx do
      send_update(ctx, "/help", message_id: 1)
      assert [text] = texts(calls_until(&match?({:send_message, _, _, _}, &1)))
      assert text == Texts.static(:help)

      send_update(ctx, "Do it", message_id: 2, extra: %{"forward_origin" => %{"type" => "user"}})
      calls = calls_until(reaction?("🤷"))
      assert texts(calls) == [Texts.static(:forwarded)]

      send_update(ctx, nil, message_id: 3, extra: %{"photo" => [%{}]})
      calls = calls_until(reaction?("🤷"))
      assert texts(calls) == [Texts.static(:text_only)]
    end

    test "none of these starts a turn", ctx do
      send_update(ctx, "/help")
      send_update(ctx, "/start sometoken")
      send_update(ctx, nil, extra: %{"voice" => %{}})
      calls_until(reaction?("🤷"))

      assert Conversations.latest_telegram_conversation(ctx.user.uuid) == nil
    end

    test "a stranger is told to link the chat, once", ctx do
      stranger = TelegramClient.update(777, "Hello")
      Bridge.dispatch(ctx.connection, stranger)
      Bridge.dispatch(ctx.connection, stranger)

      assert_receive {:tg, {:send_message, _, 777, text}}, 5_000
      assert text == Texts.static(:unlinked)
      settle()
      refute_received {:tg, {:send_message, _, 777, _}}
    end

    test "a bot with all its queues busy asks to write again", ctx do
      supervisor = PhoenixKitAgent.Telegram.QueueSupervisor

      pids =
        for _ <- 1..20 do
          {:ok, pid} =
            DynamicSupervisor.start_child(supervisor, %{
              id: make_ref(),
              start: {Agent, :start_link, [fn -> :busy end]},
              restart: :temporary
            })

          pid
        end

      on_exit(fn -> Enum.each(pids, &DynamicSupervisor.terminate_child(supervisor, &1)) end)

      send_update(ctx, "Hello", message_id: 1)
      calls = calls_until(reaction?("🤷"))
      assert texts(calls) == [Texts.static(:bot_busy)]
    end
  end

  # ── Telegram's side ─────────────────────────────────────────────────

  describe "Telegram refusing" do
    test "a rate limit is waited out once and the part is sent again", ctx do
      counter = :counters.new(1, [])

      TelegramClient.set(:send, fn _chat, _text ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == 1,
          do: {:error, "Too Many Requests: retry after 1"},
          else: {:ok, %{}}
      end)

      model_says("Answer.")
      send_update(ctx, "Hi")
      calls = calls_until(reaction?("👍"))

      assert texts(calls) == ["Answer.", "Answer."]
    end

    test "a reaction on a deleted message changes nothing", ctx do
      TelegramClient.set(:react, fn _chat, _id, _emoji ->
        {:error, "Bad Request: message to react not found"}
      end)

      model_says("Answer.")
      send_update(ctx, "Hi")
      calls = calls_until(reaction?("👍"))

      assert texts(calls) == ["Answer."]
    end

    test "a failing send is logged by its kind, never by the text", ctx do
      secret = "SECRET-QUESTION-TEXT"

      TelegramClient.set(:send, fn _chat, text ->
        raise "could not send #{text}"
      end)

      {_result, events} =
        LogProbe.capture(fn ->
          model_says("Answer with #{secret}.")
          send_update(ctx, "Hi")
          assert_receive {:tg, {:send_message, _, @chat, _}}, 5_000
          settle()
        end)

      refute Enum.any?(events, &String.contains?(&1, secret))
    end

    test "nothing of a message or the bot is logged", ctx do
      secret = "SECRET-QUESTION-TEXT"

      {_result, events} =
        LogProbe.capture(fn ->
          model_says("Fine.")
          send_update(ctx, "Tell me about #{secret}")
          calls_until(reaction?("👍"))

          Bridge.dispatch(ctx.connection, TelegramClient.update(777, "Stranger #{secret}"))
          assert_receive {:tg, {:send_message, _, 777, _}}, 5_000
          settle()
        end)

      refute Enum.any?(events, &String.contains?(&1, secret))
    end
  end

  # ── what the answer is, and what became of it ────────────────────────

  describe "the end of a turn" do
    test "an address with underscores comes through whole", ctx do
      model_says("Open **https://shop.example/admin/orders__list?a=1__2** now.")
      send_update(ctx, "Where?")

      calls = calls_until(reaction?("👍"))

      assert texts(calls) == ["Open https://shop.example/admin/orders__list?a=1__2 now."]
    end

    test "an answer that could not be sent is not a 👍", ctx do
      TelegramClient.set(:send, fn _chat, _text -> {:error, "Forbidden: bot was blocked"} end)
      model_says("Answer.")
      send_update(ctx, "Hi", message_id: 5)

      calls = calls_until(reaction?("🤷"))

      assert emojis(calls) == ["👀", "🤷"]
    end

    test "a request to change something is 🤷, with what the model said", ctx do
      call = %{
        "id" => "w1",
        "type" => "function",
        "function" => %{"name" => "agenttest_write_item", "arguments" => ~s({"name":"x"})}
      }

      Req.Test.expect(@stub, fn conn ->
        Req.Test.json(conn, %{
          "model" => @model,
          "choices" => [
            %{
              "message" => %{"role" => "assistant", "content" => nil, "tool_calls" => [call]},
              "finish_reason" => "tool_calls"
            }
          ],
          "usage" => %{"prompt_tokens" => 20, "completion_tokens" => 9, "total_tokens" => 29}
        })
      end)

      model_says("I cannot change that here. Do it on the site.")
      send_update(ctx, "Change the item", message_id: 6)

      calls = calls_until(reaction?("🤷"))

      assert emojis(calls) == ["👀", "🤷"]
      assert texts(calls) == ["I cannot change that here. Do it on the site."]
      refute Settings.get_setting("agenttest_written")
    end

    test "a tool the model made up is not a refused change: 👍", ctx do
      call = %{
        "id" => "x1",
        "type" => "function",
        "function" => %{"name" => "no_such_tool", "arguments" => "{}"}
      }

      Req.Test.expect(@stub, fn conn ->
        Req.Test.json(conn, %{
          "model" => @model,
          "choices" => [
            %{
              "message" => %{"role" => "assistant", "content" => nil, "tool_calls" => [call]},
              "finish_reason" => "tool_calls"
            }
          ],
          "usage" => %{"prompt_tokens" => 20, "completion_tokens" => 9, "total_tokens" => 29}
        })
      end)

      model_says("Here is your answer.")
      send_update(ctx, "Anything", message_id: 8)

      calls = calls_until(reaction?("👍"))

      assert texts(calls) == ["Here is your answer."]
    end

    test "a turn that never says it has ended is given up on with a notice", ctx do
      Application.put_env(:phoenix_kit_agent, :telegram_turn_wait_ms, 300)
      on_exit(fn -> Application.delete_env(:phoenix_kit_agent, :telegram_turn_wait_ms) end)

      model_hangs()
      send_update(ctx, "Slow one", message_id: 7)

      calls = calls_until(reaction?("🤷"))

      assert texts(calls) == [Texts.notice("deadline")]
      assert emojis(calls) == ["👀", "🤷"]
    end

    test "a turn task that dies lets the next message run", ctx do
      model_hangs()
      send_update(ctx, "First", message_id: 1)
      assert_receive {:model_waiting, _model}, 5_000
      [task] = Task.Supervisor.children(PhoenixKitAgent.Telegram.TaskSupervisor)

      send_update(ctx, "Second", message_id: 2)
      Process.exit(task, :kill)

      # The first turn is still running in the agent, so the second is told so:
      # what matters is that the queue went on to it.
      calls = calls_until(&match?({:react, _, _, 2, "🤷"}, &1))

      assert Texts.static(:wait) in texts(calls)
    end

    test "an idle queue ends by itself", ctx do
      Application.put_env(:phoenix_kit_agent, :telegram_queue_idle_ms, 50)
      on_exit(fn -> Application.delete_env(:phoenix_kit_agent, :telegram_queue_idle_ms) end)

      model_says("Done.")
      send_update(ctx, "Hi")
      calls_until(reaction?("👍"))

      key = {ctx.connection, @chat}
      assert [{_pid, _}] = Registry.lookup(PhoenixKitAgent.Telegram.Registry, key)
      await(fn -> Registry.lookup(PhoenixKitAgent.Telegram.Registry, key) == [] end)
    end
  end

  describe "when the task supervisor is full" do
    setup do
      sup = PhoenixKitAgent.Telegram.TaskSupervisor

      pids =
        for _ <- 1..100 do
          {:ok, pid} = Task.Supervisor.start_child(sup, fn -> Process.sleep(:infinity) end)
          pid
        end

      on_exit(fn -> Enum.each(pids, &Task.Supervisor.terminate_child(sup, &1)) end)
      :ok
    end

    test "the message is answered 'busy', the queue stays, and nothing is logged", ctx do
      secret = "SECRET-QUESTION-TEXT"

      {_result, events} =
        LogProbe.capture(fn ->
          send_update(ctx, "Tell me about #{secret}", message_id: 1)
          calls = calls_until(reaction?("🤷"))
          assert texts(calls) == [Texts.static(:bot_busy)]

          key = {ctx.connection, @chat}
          assert [{queue, _}] = Registry.lookup(PhoenixKitAgent.Telegram.Registry, key)
          assert Process.alive?(queue)
          settle()
        end)

      refute Enum.any?(events, &String.contains?(&1, secret))
    end

    test "every message is answered 'busy', none is left on 👀", ctx do
      send_update(ctx, "One", message_id: 1)
      calls_until(reaction?("🤷"))

      send_update(ctx, "Two", message_id: 2)

      assert {:react, _, @chat, 2, "🤷"} =
               List.last(calls_until(&match?({:react, _, _, 2, _}, &1)))
    end
  end

  describe "a task supervisor that is restarting" do
    test "the message is answered 'busy' and the queue stays", ctx do
      supervisor = PhoenixKitAgent.Telegram.Supervisor
      :ok = Supervisor.terminate_child(supervisor, :turn_supervisor)
      on_exit(fn -> Supervisor.restart_child(supervisor, :turn_supervisor) end)

      send_update(ctx, "Hello", message_id: 1)
      calls = calls_until(reaction?("🤷"))

      assert texts(calls) == [Texts.static(:bot_busy)]

      assert [{queue, _}] =
               Registry.lookup(PhoenixKitAgent.Telegram.Registry, {ctx.connection, @chat})

      assert Process.alive?(queue)
    end
  end

  describe "a refusal right after another reply" do
    test "is still told, with its reaction", ctx do
      Application.put_env(:phoenix_kit_agent, :telegram_quick_reply_ms, 60_000)
      on_exit(fn -> Application.put_env(:phoenix_kit_agent, :telegram_quick_reply_ms, 0) end)

      supervisor = PhoenixKitAgent.Telegram.QueueSupervisor

      pids =
        for _ <- 1..20 do
          {:ok, pid} =
            DynamicSupervisor.start_child(supervisor, %{
              id: make_ref(),
              start: {Agent, :start_link, [fn -> :busy end]},
              restart: :temporary
            })

          pid
        end

      on_exit(fn -> Enum.each(pids, &DynamicSupervisor.terminate_child(supervisor, &1)) end)

      send_update(ctx, "/help", message_id: 1)
      assert [help] = texts(calls_until(&match?({:send_message, _, _, _}, &1)))
      assert help == Texts.static(:help)

      send_update(ctx, "Hello", message_id: 2)
      calls = calls_until(reaction?("🤷"))

      assert texts(calls) == [Texts.static(:bot_busy)]
    end
  end

  describe "replies of a linked person that need no turn" do
    test "come once in a while for a chat, and not on the supervisor of the turns", ctx do
      Application.put_env(:phoenix_kit_agent, :telegram_quick_reply_ms, 60_000)
      on_exit(fn -> Application.put_env(:phoenix_kit_agent, :telegram_quick_reply_ms, 0) end)

      for id <- 1..5, do: send_update(ctx, "/help", message_id: id)
      settle()

      assert [_one] = Enum.filter(drain(), &match?({:send_message, _, @chat, _}, &1))
      assert Task.Supervisor.children(PhoenixKitAgent.Telegram.TaskSupervisor) == []
    end
  end

  defp drain do
    receive do
      {:tg, call} -> [call | drain()]
    after
      0 -> []
    end
  end

  defp await(done, tries \\ 200) do
    cond do
      done.() ->
        :ok

      tries == 0 ->
        flunk("it did not happen in time")

      true ->
        Process.sleep(10)
        await(done, tries - 1)
    end
  end

  test "the module's own setting is read from the database", _ctx do
    refute Config.telegram_enabled?()
  end
end
