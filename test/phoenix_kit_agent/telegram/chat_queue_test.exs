defmodule PhoenixKitAgent.Telegram.ChatQueueTest do
  @moduledoc """
  What a crash report of a chat's queue shows: the queue holds the text of
  the messages waiting, and the report of a `GenServer` that ended carries its
  state, the message it was handling and the reason. None of those may carry
  a person's words.
  """

  use ExUnit.Case, async: false

  alias PhoenixKitAgent.Telegram.ChatQueue
  alias PhoenixKitAgent.Test.LogProbe

  @secret "SECRET-QUESTION-TEXT"

  test "the status shows no state, no message and no arguments of the failure" do
    ref = {:telegram_link, "user", "bot", 1}
    job = %{kind: :turn, message_id: 1, text: @secret}

    status = %{
      state: %{waiting: :queue.in({ref, job}, :queue.new())},
      message: {:enqueue, ref, job},
      reason:
        {%FunctionClauseError{module: __MODULE__, function: :run, arity: 1},
         [{__MODULE__, :run, [job], []}]},
      log: []
    }

    shown = ChatQueue.format_status(status)

    refute inspect(shown) =~ @secret
    assert shown.state == :redacted
    assert shown.message == :redacted
    assert shown.reason == FunctionClauseError
  end

  test "a status without those keys is left alone" do
    assert ChatQueue.format_status(%{log: []}) |> Map.get(:log) == []
  end

  describe "a real crash of the process" do
    setup do
      Process.flag(:trap_exit, true)

      {:ok, pid} =
        ChatQueue.start_link(key: {"bot", System.unique_integer()}, connection_uuid: "bot")

      %{pid: pid}
    end

    test "ends it with a plain reason, tells the caller 'busy', and logs no word of a job", %{
      pid: pid
    } do
      ref = {:telegram_link, "user", "bot", 1}
      job = %{kind: :turn, message_id: 1, text: @secret}

      # A state no code of the queue would make: a list of waiting jobs where a
      # queue belongs. The next call fails inside the callback.
      :sys.replace_state(pid, fn state -> %{state | task: :running, waiting: [{ref, job}]} end)

      {reply, events} =
        LogProbe.capture(fn ->
          reply = GenServer.call(pid, {:enqueue, ref, %{job | text: @secret <> "-2"}})
          assert_receive {:EXIT, ^pid, :queue_failed}, 5_000
          reply
        end)

      assert reply == :busy
      assert events != []
      refute Enum.any?(events, &String.contains?(&1, @secret))
    end

    test "a call or cast nobody sends is answered, not a crash", %{pid: pid} do
      assert {:error, :unknown} = GenServer.call(pid, {:unknown, @secret})
      assert :ok = GenServer.cast(pid, {:unknown, @secret})
      assert Process.alive?(pid)
    end
  end

  describe "the pictures of one album" do
    setup do
      Process.flag(:trap_exit, true)
      chat = System.unique_integer([:positive])
      {:ok, pid} = ChatQueue.start_link(key: {"bot", chat}, connection_uuid: "bot")
      ref = {:telegram_link, "user", "bot", chat}

      # A job of the album runs.
      :sys.replace_state(pid, fn state -> %{state | task: :running, group: "g1"} end)
      %{pid: pid, chat: chat, ref: ref}
    end

    defp photo(group, id), do: %{kind: :photo, message_id: id, text: nil, group: group}

    test "the others of its group are kept as siblings, past the limit of waiting ones", ctx do
      for id <- 1..9,
          do: assert(:ok = GenServer.call(ctx.pid, {:enqueue, ctx.ref, photo("g1", id)}))

      # The tenth does not fit among the siblings, nor among the waiting ones when those are full.
      for id <- 1..3,
          do:
            assert(
              :ok =
                GenServer.call(
                  ctx.pid,
                  {:enqueue, ctx.ref, %{kind: :turn, message_id: 20 + id, text: "t"}}
                )
            )

      assert :full = GenServer.call(ctx.pid, {:enqueue, ctx.ref, photo("g1", 10)})

      siblings = ChatQueue.take_siblings("bot", ctx.chat, "g1")
      assert Enum.map(siblings, fn {_ref, job} -> job.message_id end) == Enum.to_list(1..9)

      # Taken once: a later one of the group is an ordinary waiting job (here: full).
      assert [] = ChatQueue.take_siblings("bot", ctx.chat, "g1")
      assert :full = GenServer.call(ctx.pid, {:enqueue, ctx.ref, photo("g1", 11)})
    end

    test "another group, or a job with none, waits as usual", ctx do
      assert :ok = GenServer.call(ctx.pid, {:enqueue, ctx.ref, photo("g2", 1)})
      assert :ok = GenServer.call(ctx.pid, {:enqueue, ctx.ref, photo(nil, 2)})

      assert [] = ChatQueue.take_siblings("bot", ctx.chat, "g1")
      assert %{waiting: waiting} = :sys.get_state(ctx.pid)
      assert :queue.len(waiting) == 2
    end

    test "asking for the siblings of a chat with no queue, or of another group, gives none",
         ctx do
      assert [] = ChatQueue.take_siblings("bot", -1, "g1")
      assert [] = ChatQueue.take_siblings("bot", ctx.chat, "other")
    end
  end

  describe "an album that comes while the chat is busy with something else" do
    setup do
      Process.flag(:trap_exit, true)
      chat = System.unique_integer([:positive])
      {:ok, pid} = ChatQueue.start_link(key: {"bot", chat}, connection_uuid: "bot")
      ref = {:telegram_link, "user", "bot", chat}

      # A text turn runs.
      :sys.replace_state(pid, fn state -> %{state | task: :running} end)
      %{pid: pid, ref: ref}
    end

    defp part(group, id), do: %{kind: :photo, message_id: id, text: nil, group: group}

    test "waits as one job: the other parts are kept with it, none is told to wait", ctx do
      for id <- 1..6,
          do: assert(:ok = GenServer.call(ctx.pid, {:enqueue, ctx.ref, part("g", id)}))

      assert %{waiting: waiting, held: held} = :sys.get_state(ctx.pid)
      assert :queue.len(waiting) == 1
      assert [{_ref, %{message_id: 1}}] = :queue.to_list(waiting)
      assert held["g"] |> Enum.map(fn {_ref, job} -> job.message_id end) == [2, 3, 4, 5, 6]
    end

    test "does not take the places of other messages", ctx do
      for id <- 1..5,
          do: assert(:ok = GenServer.call(ctx.pid, {:enqueue, ctx.ref, part("g", id)}))

      for id <- 21..22 do
        assert :ok =
                 GenServer.call(
                   ctx.pid,
                   {:enqueue, ctx.ref, %{kind: :turn, message_id: id, text: "t"}}
                 )
      end

      assert :full =
               GenServer.call(
                 ctx.pid,
                 {:enqueue, ctx.ref, %{kind: :turn, message_id: 23, text: "t"}}
               )

      # Still one of the album's, though the places are all taken.
      assert :ok = GenServer.call(ctx.pid, {:enqueue, ctx.ref, part("g", 6)})
    end

    test "another album is a job of its own", ctx do
      assert :ok = GenServer.call(ctx.pid, {:enqueue, ctx.ref, part("g", 1)})
      assert :ok = GenServer.call(ctx.pid, {:enqueue, ctx.ref, part("h", 2)})

      assert %{waiting: waiting, held: held} = :sys.get_state(ctx.pid)
      assert :queue.len(waiting) == 2
      assert held == %{}
    end
  end
end
