defmodule PhoenixKitAgent.Telegram.Limiter do
  @moduledoc """
  What the bridge remembers about chats that are not linked, in a table with
  a time to live (nothing of a message, only the chat id and a time):

    * the chat is known not to be linked (60 s), so a stranger's messages are
      not a database lookup each (`unlinked?/2`, `put_unlinked/2`);
    * the answer "link your chat on the site" goes to a chat once in 10
      minutes and at most 20 times a minute for the whole bot
      (`allow_unlinked_reply?/2`);
    * a linked chat gets an answer that needs no turn (help, a refusal, "wait")
      once in 3 seconds for each kind of answer (`allow_quick_reply?/3`).

    * the presses of buttons: at most 10 a minute for a chat of the bot
      (`allow_press?/2`), counted before anything is read from the database.

  A table is owned by this process (started by `PhoenixKitAgent.Telegram.Supervisor`);
  without it every question is answered as if there was nothing remembered,
  and every answer is allowed.
  """

  use GenServer

  @table __MODULE__
  @unlinked_ttl_ms 60_000
  @reply_every_ms 600_000
  @quick_every_ms 3_000
  @replies_per_minute 20
  @presses_per_minute 10
  @sweep_ms 60_000

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Whether the chat was found not to be linked within the last minute."
  @spec unlinked?(String.t(), integer()) :: boolean()
  def unlinked?(connection_uuid, chat_id) do
    live?(lookup({:unlinked, connection_uuid, chat_id}))
  end

  @doc "Remembers that the chat is not linked."
  @spec put_unlinked(String.t(), integer()) :: :ok
  def put_unlinked(connection_uuid, chat_id) do
    insert({:unlinked, connection_uuid, chat_id}, now() + @unlinked_ttl_ms)
  end

  @doc "Forgets every unlinked chat of the bot (a chat was linked just now)."
  @spec clear_unlinked(String.t()) :: :ok
  def clear_unlinked(connection_uuid) do
    if exists?(), do: :ets.match_delete(@table, {{:unlinked, connection_uuid, :_}, :_})
    :ok
  end

  @doc """
  Whether the bot may answer the unlinked chat now; when it may, the answer
  is counted.
  """
  @spec allow_unlinked_reply?(String.t(), integer()) :: boolean()
  def allow_unlinked_reply?(connection_uuid, chat_id) do
    exists?() == false or
      (chat_allowed?(connection_uuid, chat_id) and bot_allowed?(connection_uuid))
  end

  @doc """
  Whether a linked chat may get an answer of this `kind` that needs no turn
  now; when it may, it is counted. Each kind has its own pace, so a `/help`
  does not silence the "wait" that refuses the next message.
  """
  @spec allow_quick_reply?(String.t(), integer(), atom()) :: boolean()
  def allow_quick_reply?(connection_uuid, chat_id, kind) do
    key = {:quick, connection_uuid, chat_id, kind}

    if live?(lookup(key)) do
      false
    else
      insert(key, now() + quick_every_ms())
      true
    end
  end

  @doc """
  Whether a press of a button in the chat may be looked at now (10 a minute
  for each chat of the bot); a press is counted when asked, whatever the
  answer, so a flood from a stranger's chat costs a counter and no more.
  """
  @spec allow_press?(String.t(), integer()) :: boolean()
  def allow_press?(connection_uuid, chat_id) do
    if exists?() do
      key = {:press, connection_uuid, chat_id, div(now(), 60_000)}
      :ets.update_counter(@table, key, {2, 1}, {key, 0}) <= @presses_per_minute
    else
      true
    end
  end

  # A chat is marked answered before the bot's budget is looked at: a chat the
  # budget refused is not answered later either (a flood from many strangers
  # does not get a second chance each minute).
  defp chat_allowed?(connection_uuid, chat_id) do
    key = {:replied, connection_uuid, chat_id}

    if live?(lookup(key)) do
      false
    else
      insert(key, now() + @reply_every_ms)
      true
    end
  end

  defp bot_allowed?(connection_uuid) do
    minute = div(now(), 60_000)
    key = {:budget, connection_uuid, minute}
    count = :ets.update_counter(@table, key, {2, 1}, {key, 0})
    count <= @replies_per_minute
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, nil}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    horizon = now()
    minute = div(horizon, 60_000)

    :ets.select_delete(@table, [
      {{{:unlinked, :_, :_}, :"$1"}, [{:<, :"$1", horizon}], [true]},
      {{{:replied, :_, :_}, :"$1"}, [{:<, :"$1", horizon}], [true]},
      {{{:quick, :_, :_, :_}, :"$1"}, [{:<, :"$1", horizon}], [true]},
      {{{:budget, :_, :"$2"}, :_}, [{:<, :"$2", minute}], [true]},
      {{{:press, :_, :_, :"$2"}, :_}, [{:<, :"$2", minute}], [true]}
    ])

    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp quick_every_ms,
    do: Application.get_env(:phoenix_kit_agent, :telegram_quick_reply_ms, @quick_every_ms)

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)

  defp live?(expires) when is_integer(expires), do: expires > now()
  defp live?(_none), do: false

  defp exists?, do: :ets.whereis(@table) != :undefined

  defp lookup(key) do
    if exists?() do
      case :ets.lookup(@table, key) do
        [{^key, value}] -> value
        [] -> nil
      end
    end
  end

  defp insert(key, value) do
    if exists?(), do: :ets.insert(@table, {key, value})
    :ok
  end

  # `:telegram_now_ms` stands in for the clock in tests.
  defp now,
    do:
      Application.get_env(:phoenix_kit_agent, :telegram_now_ms) ||
        System.system_time(:millisecond)
end
