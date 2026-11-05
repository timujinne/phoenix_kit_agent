defmodule PhoenixKitAgent.Telegram.ReaderTest do
  @moduledoc """
  The reader of the site bot (`Reader.cycle/2` is one look and one poll,
  with the bot played by `PhoenixKitAgent.Test.TelegramClient`): when it
  reads, what it keeps of what it read, and how it behaves when Telegram
  or the database does not cooperate.
  """

  use PhoenixKitAgent.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias PhoenixKit.Integrations.Telegram.Linking
  alias PhoenixKit.Settings.History
  alias PhoenixKitAgent.Config
  alias PhoenixKitAgent.Telegram.{Limiter, Reader}
  alias PhoenixKitAgent.Test.TelegramClient

  @chat 428_897_538
  @reader :reader_under_test

  setup do
    {:ok, _} = PhoenixKitAgent.enable_system()
    TelegramClient.start()
    connection = UUIDv7.generate()
    TelegramClient.set(:connection, connection)
    {:ok, _} = Config.put_telegram_enabled(true, [])
    start_supervised!({Reader, name: @reader, autostart: false})

    Application.put_env(:phoenix_kit, :telegram_updates_reader, {Reader, :holds?, []})

    on_exit(fn ->
      settle_jobs()
      TelegramClient.stop()
      Application.delete_env(:phoenix_kit, :telegram_updates_reader)
      :persistent_term.erase({Reader, :status})
    end)

    %{connection: connection}
  end

  defp cycle, do: Reader.cycle(@reader)

  # The replies of the bridge run in tasks: let them end before the database goes
  # (and before the next test listens).
  defp settle_jobs(tries \\ 100) do
    supervisors = [
      PhoenixKitAgent.Telegram.TaskSupervisor,
      PhoenixKitAgent.Telegram.ReplySupervisor
    ]

    if tries > 0 and Enum.any?(supervisors, &(Task.Supervisor.children(&1) != [])) do
      Process.sleep(20)
      settle_jobs(tries - 1)
    end
  end

  defp polls do
    receive do
      {:tg, {:get_updates, _, opts}} -> [Map.new(opts) | polls()]
    after
      0 -> []
    end
  end

  defp stranger_update(id, opts \\ []), do: TelegramClient.update(777, "Hello", [id: id] ++ opts)

  describe "when it reads" do
    test "idle, nothing holds the bot; once reading, the name is taken", ctx do
      refute Reader.holds?(ctx.connection)
      refute Linking.resident_reader?(ctx.connection)

      assert {:reading, 0} = cycle()

      assert Reader.holds?(ctx.connection)
      assert Linking.resident_reader?(ctx.connection)
      assert [%{timeout: 25, limit: 100}] = polls()
    end

    test "the bot is told to send button presses too, where the core lets a chat write", ctx do
      Application.put_env(:phoenix_kit_agent, :telegram_link_writes, true)
      on_exit(fn -> Application.put_env(:phoenix_kit_agent, :telegram_link_writes, false) end)

      assert {:reading, 0} = cycle()
      assert [%{allowed_updates: ["message", "callback_query"]}] = polls()
      assert ctx.connection
    end

    test "and is not asked for them where it does not", _ctx do
      assert {:reading, 0} = cycle()
      assert [poll] = polls()
      refute Map.has_key?(poll, :allowed_updates)
    end

    test "holds? answers for anything that is not a bot, and never calls the process", ctx do
      refute Reader.holds?(nil)
      refute Reader.holds?(123)

      cycle()
      # The reader may be busy in a long poll: the answer does not wait for it.
      :ok = :sys.suspend(@reader)
      assert Reader.holds?(ctx.connection)
      :ok = :sys.resume(@reader)
    end

    test "switched off: nothing is read, and a held name is let go", ctx do
      cycle()
      assert Reader.holds?(ctx.connection)

      {:ok, _} = Config.put_telegram_enabled(false, [])
      _ = polls()

      assert {:off, 30_000} = cycle()
      refute Reader.holds?(ctx.connection)
      refute Linking.resident_reader?(ctx.connection)
      assert polls() == []
    end

    test "no bot chosen: nothing is read", ctx do
      TelegramClient.set(:connection, nil)

      assert {:no_bot, 30_000} = cycle()
      refute Reader.holds?(ctx.connection)
      assert polls() == []
    end

    test "a bot with a webhook is not read, and the webhook is asked about every 10 minutes only",
         ctx do
      TelegramClient.set(:webhook, true)

      assert {:webhook, 30_000} = cycle()
      assert {:webhook, 30_000} = cycle()

      assert_received {:tg, {:webhook_set?, _}}
      refute_received {:tg, {:webhook_set?, _}}
      refute_received {:tg, {:get_updates, _, _}}
      refute Reader.holds?(ctx.connection)
    end

    test "a node that does not get the name does not read", ctx do
      holder = spawn_link(fn -> receive do: (:stop -> :ok) end)
      :yes = :global.register_name(Reader.name_of(ctx.connection), holder)

      assert {:standby, 30_000} = cycle()
      assert polls() == []

      send(holder, :stop)
    end

    test "another bot is read from its own offset", ctx do
      {:ok, _} = Config.put_telegram_offset(ctx.connection, 50)
      other = UUIDv7.generate()
      TelegramClient.set(:connection, other)

      cycle()

      assert [%{timeout: 25, limit: 100}] = polls()
      assert Config.telegram_offset(ctx.connection) == 50
      assert Config.telegram_offset(other) == nil
      refute Reader.holds?(ctx.connection)
      assert Reader.holds?(other)
    end
  end

  describe "the offset" do
    test "is the last update id taken, and the next poll asks for the one after it", ctx do
      TelegramClient.set(:updates, [
        {:ok, [stranger_update(10), stranger_update(12), stranger_update(11)]}
      ])

      cycle()
      assert Config.telegram_offset(ctx.connection) == 12
      _ = polls()

      cycle()
      assert [%{offset: 13, timeout: 25, limit: 100}] = polls()
    end

    test "a restarted reader goes on after it: nothing read is answered twice", ctx do
      TelegramClient.set(:updates, [{:ok, [stranger_update(10)]}])
      cycle()
      assert_receive {:tg, {:send_message, _, 777, _}}, 5_000

      stop_supervised!(Reader)
      start_supervised!({Reader, name: @reader, autostart: false})
      _ = polls()

      cycle()

      assert [%{offset: 11, timeout: 25, limit: 100}] = polls()
      refute_receive {:tg, {:send_message, _, _, _}}, 200
    end

    test "is written before the updates are handed on", ctx do
      connection = ctx.connection
      test = self()

      TelegramClient.set(:send, fn _chat, _text ->
        send(test, {:offset_at_send, Config.telegram_offset(connection)})
        {:ok, %{}}
      end)

      TelegramClient.set(:updates, [{:ok, [stranger_update(31)]}])
      cycle()

      assert_receive {:offset_at_send, 31}, 5_000
    end

    test "is kept without a trace in the settings history" do
      TelegramClient.set(:updates, [{:ok, [stranger_update(5)]}])
      cycle()

      assert History.list("agent_telegram_offset") == []
    end
  end

  describe "a batch" do
    test "a batch core is busy with is read again after 2 seconds, the offset where it was",
         ctx do
      {:ok, _} = Config.put_telegram_offset(ctx.connection, 7)
      start_update = TelegramClient.update(@chat, "/start " <> String.duplicate("a", 43), id: 8)
      TelegramClient.set(:updates, [{:ok, [start_update]}, {:ok, [start_update]}])

      holder = hold_link_lock(ctx.connection)
      assert {:reading, 2_000} = cycle()
      assert Config.telegram_offset(ctx.connection) == 7
      refute_received {:tg, {:send_message, _, _, _}}

      release_link_lock(holder)
      assert {:reading, 0} = cycle()
      assert Config.telegram_offset(ctx.connection) == 8
    end

    test "a /start with a token is not given to the agent", ctx do
      TelegramClient.set(:updates, [
        {:ok, [TelegramClient.update(@chat, "/start " <> String.duplicate("a", 43), id: 3)]}
      ])

      cycle()

      assert Config.telegram_offset(ctx.connection) == 3
      refute_receive {:tg, {:react, _, _, _, _}}, 200
      refute_received {:tg, {:send_message, _, @chat, _}}
    end

    test "an old message is passed over without a word" do
      old = System.system_time(:second) - 3_600

      TelegramClient.set(:updates, [
        {:ok, [TelegramClient.update(777, "Hello", id: 4, date: old)]}
      ])

      cycle()

      refute_receive {:tg, {:send_message, _, _, _}}, 200
    end

    test "a chat linked by the batch is no longer remembered as a stranger", ctx do
      user = user_fixture("linker")

      Repo.update_all(from(u in PhoenixKit.Users.Auth.User, where: u.uuid == ^user.uuid),
        set: [confirmed_at: DateTime.utc_now()]
      )

      {:ok, token} = Linking.create_token(user, ctx.connection)
      Limiter.put_unlinked(ctx.connection, 999)
      assert Limiter.unlinked?(ctx.connection, 999)

      TelegramClient.set(:updates, [
        {:ok, [TelegramClient.update(999, "/start " <> token, id: 9)]}
      ])

      cycle()

      refute Limiter.unlinked?(ctx.connection, 999)
      assert Linking.linked_user(ctx.connection, 999)
      assert Config.telegram_offset(ctx.connection) == 9
    end
  end

  describe "owning the name" do
    test "a reader that lost the name after a netsplit stops reading", ctx do
      assert {:reading, 0} = cycle()
      _ = polls()
      name = Reader.name_of(ctx.connection)

      # What `:global` does when two partitions joined: the name stays with
      # the other node's process, and the loser is told.
      winner = spawn_link(fn -> receive do: (:stop -> :ok) end)
      :global.unregister_name(name)
      :yes = :global.register_name(name, winner)
      send(Process.whereis(@reader), {:global_name_conflict, name})

      assert {:standby, 30_000} = cycle()
      assert polls() == []
      assert :global.whereis_name(name) == winner

      send(winner, :stop)
    end

    test "even a message that did not come is no reason to read a bot someone else holds",
         ctx do
      assert {:reading, 0} = cycle()
      _ = polls()
      name = Reader.name_of(ctx.connection)

      winner = spawn_link(fn -> receive do: (:stop -> :ok) end)
      :global.unregister_name(name)
      :yes = :global.register_name(name, winner)

      assert {:standby, 30_000} = cycle()
      assert polls() == []

      send(winner, :stop)
    end

    test "when the name is free again the reader takes it and reads", ctx do
      assert {:reading, 0} = cycle()
      name = Reader.name_of(ctx.connection)
      winner = spawn(fn -> receive do: (:stop -> :ok) end)
      :global.unregister_name(name)
      :yes = :global.register_name(name, winner)
      send(Process.whereis(@reader), {:global_name_conflict, name})
      assert {:standby, 30_000} = cycle()

      send(winner, :stop)
      await_name_free(name)
      _ = polls()

      assert {:reading, 0} = cycle()
      assert [%{timeout: 25}] = polls()
      assert :global.whereis_name(name) == Process.whereis(@reader)
    end

    test "a batch taken after the name was lost in the long poll is left alone", ctx do
      name = Reader.name_of(ctx.connection)
      winner = spawn_link(fn -> receive do: (:stop -> :ok) end)

      # While the reader waits for Telegram, the name goes to another reader.
      TelegramClient.set(:updates, [
        fn ->
          :global.unregister_name(name)
          :yes = :global.register_name(name, winner)
          {:ok, [stranger_update(61)]}
        end
      ])

      assert {:standby, 30_000} = cycle()
      assert Config.telegram_offset(ctx.connection) == nil
      refute_received {:tg, {:send_message, _, _, _}}

      send(winner, :stop)
    end

    test "a conflict message about another name changes nothing", ctx do
      assert {:reading, 0} = cycle()
      send(Process.whereis(@reader), {:global_name_conflict, {Reader, "another-bot"}})

      assert {:reading, 0} = cycle()
    end
  end

  defp await_name_free(name, tries \\ 100) do
    if tries > 0 and :global.whereis_name(name) != :undefined do
      Process.sleep(10)
      await_name_free(name, tries - 1)
    end
  end

  describe "an update that cannot be handled" do
    test "is logged by its class and update_id, never by its text, and the batch goes on" do
      # No supervisor to answer a stranger: handing the update on fails.
      supervisor = PhoenixKitAgent.Telegram.Supervisor
      :ok = Supervisor.terminate_child(supervisor, :reply_supervisor)
      on_exit(fn -> Supervisor.restart_child(supervisor, :reply_supervisor) end)

      TelegramClient.set(:updates, [
        {:ok,
         [
           TelegramClient.update(777, "SECRET-TEXT-ONE", id: 77),
           TelegramClient.update(778, "SECRET-TEXT-TWO", id: 78)
         ]}
      ])

      log = capture_log([level: :warning], fn -> assert {:reading, 0} = cycle() end)

      assert log =~ "telegram update failed: :exit update_id=77"
      assert log =~ "update_id=78"
      refute log =~ "SECRET-TEXT"
    end

    test "a batch whose offset cannot be taken is not handed on, and is read again later", ctx do
      TelegramClient.set(:updates, [{:ok, [%{"message" => %{"text" => "SECRET-TEXT"}}]}])

      assert {:error, 5_000} = cycle()

      assert Config.telegram_offset(ctx.connection) == nil
      refute_received {:tg, {:send_message, _, _, _}}
    end
  end

  describe "trouble" do
    test "a conflict: 60 seconds, the status, one warning in ten minutes" do
      TelegramClient.set(:updates, [
        {:error, "Conflict: terminated by other getUpdates request"},
        {:error, "Conflict: terminated by other getUpdates request"}
      ])

      log =
        capture_log([level: :warning], fn ->
          assert {:conflict, 60_000} = cycle()
          assert Reader.status() == :conflict
          assert {:conflict, 60_000} = cycle()
        end)

      assert length(String.split(log, "telegram conflict")) == 2
    end

    test "other errors back off from 5 seconds up to 60, and a good poll starts over" do
      TelegramClient.set(
        :updates,
        List.duplicate({:error, :unreachable}, 6) ++ [{:ok, []}, {:error, :unreachable}]
      )

      capture_log(fn ->
        delays = for _ <- 1..6, do: elem(cycle(), 1)
        assert delays == [5_000, 10_000, 20_000, 40_000, 60_000, 60_000]

        assert {:reading, 0} = cycle()
        assert {:error, 5_000} = cycle()
      end)
    end

    test "the log of a failure names the kind and nothing else" do
      TelegramClient.set(:updates, [{:error, "Unauthorized: SECRET-DESCRIPTION"}])

      log = capture_log([level: :warning], fn -> cycle() end)

      assert log =~ "could not be read"
      refute log =~ "SECRET-DESCRIPTION"
    end

    test "an exception inside a step is a pause, logged by its class" do
      defmodule Exploding do
        @behaviour PhoenixKitAgent.Telegram.Client
        def connection_uuid, do: raise("SECRET-REASON")
        def bot_username(_), do: nil
        def webhook_set?(_), do: false
        def get_updates(_, _), do: {:ok, []}
        def send_message(_, _, _, _), do: {:ok, %{}}
        def answer_callback(_, _, _), do: {:ok, true}
        def edit_message(_, _, _, _, _), do: {:ok, true}
        def react(_, _, _, _), do: {:ok, true}
        def typing(_, _), do: {:ok, true}
      end

      Application.put_env(:phoenix_kit_agent, :telegram_client, Exploding)

      log = capture_log([level: :warning], fn -> assert {:error, 5_000} = cycle() end)

      assert log =~ "RuntimeError"
      refute log =~ "SECRET-REASON"
    end

    test "nothing of an update or of the bot is kept in the state of the reader" do
      TelegramClient.set(:updates, [
        {:ok, [TelegramClient.update(777, "SECRET-UPDATE-TEXT", id: 6)]}
      ])

      cycle()

      state = inspect(:sys.get_state(@reader), limit: :infinity)
      refute state =~ "SECRET-UPDATE-TEXT"
      refute state =~ "bot_token"
    end
  end

  # A separate database connection holds the lock core takes for a batch of links.
  defp hold_link_lock(connection) do
    config = Application.fetch_env!(:phoenix_kit_agent, PhoenixKitAgent.Test.Repo)

    {:ok, pid} =
      Postgrex.start_link(Keyword.take(config, [:username, :password, :hostname, :database]))

    Postgrex.query!(pid, "BEGIN", [])

    Postgrex.query!(pid, "SELECT pg_advisory_xact_lock(hashtext($1))", [
      "phoenix_kit_telegram_link:" <> connection
    ])

    pid
  end

  defp release_link_lock(pid) do
    Postgrex.query!(pid, "COMMIT", [])
    GenServer.stop(pid)
  end
end
