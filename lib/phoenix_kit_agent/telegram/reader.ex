defmodule PhoenixKitAgent.Telegram.Reader do
  @moduledoc """
  The one reader of the site bot's updates (`getUpdates`, a long poll of 25
  seconds). Core lets a feature module be the bot's resident reader: the host
  declares

      config :phoenix_kit, :telegram_updates_reader, {PhoenixKitAgent.Telegram.Reader, :holds?, []}

  and while `holds?/1` answers `true`, `Linking.poll/1` reads nothing.

  ## When it reads

  Idle, it looks every 30 seconds at the switch `agent_telegram_enabled` (off
  by default), the site bot's connection and whether the bot has a webhook
  (at the start and every 10 minutes). Only when the switch is on, there is a
  bot and no webhook does it **register the global name** `{Reader,
  connection_uuid}` and read; `holds?/1` is just that name being registered
  anywhere in the cluster, so it never calls a process (a reader busy in its
  long poll cannot make a caller wait). A second node that does not get the
  name does not read and tries again in 30 seconds. So does a reader that
  lost the name when a netsplit healed (`:global` tells it, and it checks the
  name before each poll). Switching off waits for the long poll in progress
  to end, then releases the name. Another bot starts from its own offset.

  ## The offset

  The offset is kept in the setting `agent_telegram_offset` (the last update
  id taken, with the bot it belongs to), written **before** the batch is
  handed on, so an update is answered at most once: a crash in between loses
  a message, never answers it twice. A batch goes to `Linking.handle_updates/3`
  first (links by `/start <token>`); `:busy` leaves the offset alone and the
  batch is read again after 2 seconds.

  ## Trouble

  A `Conflict` (409: a webhook or another reader) pauses 60 seconds and shows
  in the status, with a warning in the log at most every 10 minutes; any other
  error pauses 5 seconds, doubling up to 60. The state of the process holds
  no text of an update and no token: the bot is named by its connection uuid,
  and the exception of a failed update is logged by its class and the
  `update_id` only.
  """

  use GenServer

  require Logger

  alias PhoenixKit.Integrations.Telegram.Linking
  alias PhoenixKitAgent.Config
  alias PhoenixKitAgent.Telegram.{Bridge, Client, Limiter}

  @poll_timeout_s 25
  @idle_ms 30_000
  @first_tick_ms 5_000
  @webhook_every_ms 600_000
  @busy_pause_ms 2_000
  @conflict_pause_ms 60_000
  @warn_every_ms 600_000
  @min_backoff_s 5
  @max_backoff_s 60

  @type status :: :off | :no_bot | :webhook | :standby | :reading | :conflict | :error

  @doc """
  Options: `:name` (default this module), `:autostart` (whether it starts
  looking by itself, default `config :phoenix_kit_agent,
  :telegram_reader_autostart`, true; the tests turn it off and call
  `cycle/2`).
  """
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  Whether a reader is reading the bot `connection_uuid` now, on any node: the
  global name is taken. The answer for core's `:telegram_updates_reader`.
  """
  @spec holds?(term()) :: boolean()
  def holds?(connection_uuid) when is_binary(connection_uuid),
    do: :global.whereis_name(name_of(connection_uuid)) != :undefined

  def holds?(_other), do: false

  @doc "What this node's reader is doing (see `t:status/0`); `:off` when it never ran."
  @spec status() :: status()
  def status, do: :persistent_term.get({__MODULE__, :status}, :off)

  @doc false
  # One look and, if it reads, one poll, now: for tests, and the way a
  # caller can see what the reader would do next.
  @spec cycle(GenServer.server(), timeout()) :: {status(), non_neg_integer()}
  def cycle(server \\ __MODULE__, timeout \\ 30_000), do: GenServer.call(server, :cycle, timeout)

  @doc false
  def name_of(connection_uuid), do: {__MODULE__, connection_uuid}

  @impl GenServer
  def init(opts) do
    Process.flag(:sensitive, true)

    autostart? =
      Keyword.get(
        opts,
        :autostart,
        Application.get_env(:phoenix_kit_agent, :telegram_reader_autostart, true)
      )

    if autostart?, do: Process.send_after(self(), :tick, @first_tick_ms)

    {:ok,
     %{
       connection: nil,
       registered?: false,
       webhook?: false,
       webhook_checked_at: nil,
       backoff_s: @min_backoff_s,
       warned_at: %{}
     }}
  end

  @impl GenServer
  def handle_call(:cycle, _from, state) do
    {state, delay} = step(state)
    {:reply, {status(), delay}, state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    {state, delay} = step(state)
    Process.send_after(self(), :tick, delay)
    {:noreply, state}
  end

  # After a netsplit heals, `:global` keeps one holder of the name and tells
  # the other: that one stops reading (it is `standby` at its next step).
  def handle_info({:global_name_conflict, name}, %{connection: connection} = state)
      when is_binary(connection) do
    if name == name_of(connection),
      do: {:noreply, %{state | registered?: false}},
      else: {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def format_status(status), do: Map.update(status, :state, nil, fn _state -> :redacted end)

  # ── one step ──────────────────────────────────────────────────────

  # Returns the new state and how long to wait before the next step.
  defp step(state) do
    state |> refresh() |> decide()
  rescue
    exception -> failed(state, exception.__struct__)
  catch
    kind, _reason -> failed(state, kind)
  end

  defp failed(state, kind) do
    warn(state, :crash, "[PhoenixKitAgent] telegram reader failed: #{inspect(kind)}")
    pause_backoff(mark_warned(state, :crash), :error)
  end

  defp refresh(state) do
    connection = Client.impl().connection_uuid()
    state = if connection != state.connection, do: release(state, connection), else: state
    state = %{state | connection: connection}

    if Config.telegram_enabled?() and is_binary(connection),
      do: check_webhook(state),
      else: state
  end

  defp release(%{registered?: true, connection: old} = state, _new) when is_binary(old) do
    :global.unregister_name(name_of(old))
    %{state | registered?: false, webhook?: false, webhook_checked_at: nil}
  end

  defp release(state, _new), do: %{state | webhook?: false, webhook_checked_at: nil}

  defp check_webhook(state) do
    now = System.monotonic_time(:millisecond)

    if is_nil(state.webhook_checked_at) or now - state.webhook_checked_at >= @webhook_every_ms do
      %{state | webhook?: Client.impl().webhook_set?(state.connection), webhook_checked_at: now}
    else
      state
    end
  end

  defp decide(state) do
    cond do
      not Config.telegram_enabled?() -> idle(state, :off)
      is_nil(state.connection) -> idle(state, :no_bot)
      state.webhook? -> idle(state, :webhook)
      true -> acquire_and_poll(state)
    end
  end

  # Not reading: the name is released.
  defp idle(state, status) do
    put_status(status)
    {unregister(state), @idle_ms}
  end

  defp unregister(%{registered?: true, connection: connection} = state)
       when is_binary(connection) do
    :global.unregister_name(name_of(connection))
    %{state | registered?: false}
  end

  defp unregister(state), do: state

  # Before each poll the name is checked to be this process's still.
  defp acquire_and_poll(%{registered?: true} = state) do
    if :global.whereis_name(name_of(state.connection)) == self() do
      poll(state)
    else
      put_status(:standby)
      {%{state | registered?: false}, @idle_ms}
    end
  end

  defp acquire_and_poll(state) do
    name = name_of(state.connection)

    case :global.register_name(name, self(), &:global.random_notify_name/3) do
      :yes ->
        poll(%{state | registered?: true})

      :no ->
        put_status(:standby)
        {state, @idle_ms}
    end
  end

  # ── reading ───────────────────────────────────────────────────────

  defp poll(state) do
    offset = Config.telegram_offset(state.connection)

    options =
      [timeout: @poll_timeout_s, limit: 100] ++ if(offset, do: [offset: offset + 1], else: [])

    case Client.impl().get_updates(state.connection, options) do
      {:ok, []} -> ok(state)
      {:ok, updates} when is_list(updates) -> handle_batch(state, updates)
      {:error, reason} -> handle_error(state, reason)
    end
  end

  defp ok(state) do
    put_status(:reading)
    {%{state | backoff_s: @min_backoff_s}, 0}
  end

  defp handle_batch(state, updates) do
    # Core confirms the batch (stores our offset) before it tells anyone of a link.
    confirm = fn _updates -> store_offset(state.connection, updates) end

    case Linking.handle_updates(state.connection, updates, confirm: confirm) do
      :busy ->
        put_status(:reading)
        {state, @busy_pause_ms}

      {:ok, %{linked: linked}} ->
        if linked > 0, do: Limiter.clear_unlinked(state.connection)
        take(state, updates)
    end
  end

  # The offset first, then the updates: at most once.
  defp take(state, updates) do
    if store_offset(state.connection, updates) == :ok do
      Enum.each(updates, &dispatch(state.connection, &1))
      ok(state)
    else
      pause_backoff(state, :error)
    end
  end

  # Idempotent: the same batch stored by `Linking`'s confirmation is not written twice.
  defp store_offset(connection, updates) do
    case for(%{"update_id" => id} <- updates, is_integer(id), do: id) do
      [] ->
        :error

      ids ->
        last = Enum.max(ids)

        cond do
          Config.telegram_offset(connection) == last -> :ok
          match?({:ok, _}, Config.put_telegram_offset(connection, last)) -> :ok
          true -> :error
        end
    end
  end

  defp dispatch(connection, update) do
    Bridge.dispatch(connection, update)
  rescue
    exception -> log_update_failure(update, exception.__struct__)
  catch
    kind, _reason -> log_update_failure(update, kind)
  end

  defp log_update_failure(update, kind) do
    id = if is_map(update) and is_integer(update["update_id"]), do: update["update_id"]
    Logger.warning("[PhoenixKitAgent] telegram update failed: #{inspect(kind)} update_id=#{id}")
  end

  defp handle_error(state, "Conflict" <> _) do
    put_status(:conflict)

    warn(
      state,
      :conflict,
      "[PhoenixKitAgent] telegram conflict: the bot is read by someone else (a webhook or another reader)"
    )

    {mark_warned(state, :conflict), @conflict_pause_ms}
  end

  defp handle_error(state, reason) do
    kind = if reason == :unreachable, do: :unreachable, else: :refused
    warn(state, :error, "[PhoenixKitAgent] telegram updates could not be read: #{kind}")
    pause_backoff(mark_warned(state, :error), :error)
  end

  defp pause_backoff(state, status) do
    put_status(status)
    {%{state | backoff_s: min(state.backoff_s * 2, @max_backoff_s)}, state.backoff_s * 1_000}
  end

  # ── small things ──────────────────────────────────────────────────

  defp put_status(status) do
    if status() != status, do: :persistent_term.put({__MODULE__, :status}, status)
  end

  defp warn(state, key, message) do
    last = Map.get(state.warned_at, key)

    if is_nil(last) or System.monotonic_time(:millisecond) - last >= @warn_every_ms,
      do: Logger.warning(message)
  end

  defp mark_warned(state, key) do
    last = Map.get(state.warned_at, key)
    now = System.monotonic_time(:millisecond)

    if is_nil(last) or now - last >= @warn_every_ms,
      do: %{state | warned_at: Map.put(state.warned_at, key, now)},
      else: state
  end
end
