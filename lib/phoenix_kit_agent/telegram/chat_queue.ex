defmodule PhoenixKitAgent.Telegram.ChatQueue do
  @moduledoc """
  The messages of one chat, answered one at a time and in order: one process
  per active chat (named in `PhoenixKitAgent.Telegram.Registry` by the bot
  and the chat), which runs a message's turn
  (`PhoenixKitAgent.Telegram.Turn`) in a task of its own and keeps up to three
  more waiting. A fourth is `:full`; when the bot already has the most chats
  it serves at once (`PhoenixKitAgent.Telegram.QueueSupervisor`), a message
  from a new chat is `:busy`. A process with nothing to do for a minute ends.

  It holds the text of a waiting message, so it keeps itself out of crash
  reports: the process is `sensitive` and its status shows no jobs.
  """

  use GenServer, restart: :temporary

  alias PhoenixKitAgent.Telegram.Turn

  @registry PhoenixKitAgent.Telegram.Registry
  @supervisor PhoenixKitAgent.Telegram.QueueSupervisor
  @tasks PhoenixKitAgent.Telegram.TaskSupervisor
  @max_waiting 3

  @doc "Queues `job` of the chat `ref` of the bot `connection_uuid`."
  @spec submit(String.t(), PhoenixKitAgent.Telegram.Bridge.ref(), map()) :: :ok | :full | :busy
  def submit(connection_uuid, {:telegram_link, _user, _connection, chat_id} = ref, job) do
    key = {connection_uuid, chat_id}
    enqueue(key, ref, job, 2)
  end

  defp enqueue(_key, _ref, _job, 0), do: :busy

  defp enqueue(key, ref, job, tries) do
    case process(key) do
      {:ok, pid} ->
        try do
          GenServer.call(pid, {:enqueue, ref, job})
        catch
          # It ended just now, with nothing to do.
          :exit, _ -> enqueue(key, ref, job, tries - 1)
        end

      :busy ->
        :busy
    end
  end

  defp process({connection_uuid, _chat_id} = key) do
    case Registry.lookup(@registry, key) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(
               @supervisor,
               {__MODULE__, key: key, connection_uuid: connection_uuid}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, _max_children_or_other} -> :busy
        end
    end
  end

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {@registry, opts[:key]}})
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:sensitive, true)
    {:ok, %{connection_uuid: opts[:connection_uuid], waiting: :queue.new(), task: nil, idle: nil}}
  end

  @impl GenServer
  def handle_call({:enqueue, ref, job}, _from, %{task: nil} = state) do
    {:reply, :ok, start(state, ref, job)}
  end

  def handle_call({:enqueue, ref, job}, _from, state) do
    if :queue.len(state.waiting) < @max_waiting,
      do: {:reply, :ok, %{state | waiting: :queue.in({ref, job}, state.waiting)}},
      else: {:reply, :full, state}
  end

  @impl GenServer
  def handle_info({task_ref, _result}, %{task: %Task{ref: task_ref}} = state) do
    Process.demonitor(task_ref, [:flush])
    {:noreply, next(state)}
  end

  def handle_info(
        {:DOWN, task_ref, :process, _pid, _reason},
        %{task: %Task{ref: task_ref}} = state
      ) do
    {:noreply, next(state)}
  end

  def handle_info(:idle, %{task: nil} = state) do
    if :queue.is_empty(state.waiting), do: {:stop, :normal, state}, else: {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def format_status(status), do: Map.update(status, :state, nil, fn _state -> :redacted end)

  defp start(state, ref, job) do
    if state.idle, do: Process.cancel_timer(state.idle)
    connection_uuid = state.connection_uuid
    task = Task.Supervisor.async_nolink(@tasks, fn -> Turn.run(connection_uuid, ref, job) end)
    %{state | task: task, idle: nil}
  end

  defp next(state) do
    state = %{state | task: nil}

    case :queue.out(state.waiting) do
      {{:value, {ref, job}}, rest} ->
        start(%{state | waiting: rest}, ref, job)

      {:empty, _} ->
        %{state | idle: Process.send_after(self(), :idle, idle_ms())}
    end
  end

  defp idle_ms, do: Application.get_env(:phoenix_kit_agent, :telegram_queue_idle_ms, 60_000)
end
