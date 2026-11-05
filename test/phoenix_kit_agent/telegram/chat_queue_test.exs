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
end
