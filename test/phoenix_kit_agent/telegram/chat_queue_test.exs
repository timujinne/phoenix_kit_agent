defmodule PhoenixKitAgent.Telegram.ChatQueueTest do
  @moduledoc """
  What a crash report of a chat's queue shows: the queue holds the text of
  the messages waiting, and the report of a `GenServer` that ended carries its
  state, the message it was handling and the reason. None of those may carry
  a person's words.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitAgent.Telegram.ChatQueue

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
end
