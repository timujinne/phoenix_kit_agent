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
  reports: the process is `sensitive`, and its status shows neither the state
  nor the message it was handling nor the reason it ended with (a function
  clause error would carry the job as an argument). A turn that cannot be
  started (the task supervisor is full) is answered "busy" and does not end
  the queue.
  """

  use GenServer, restart: :temporary

  alias PhoenixKitAgent.Telegram.{Bridge, Turn}

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

  # Every callback runs under `guarded/2`: whatever goes wrong inside ends the
  # process with an atom for a reason, so no stacktrace (whose first frame
  # carries the arguments, the job's text among them) reaches a crash report.
  # The caller of a call that fails hears `:busy`.
  @impl GenServer
  def handle_call({:enqueue, ref, job}, _from, state) do
    guarded(state, :busy, fn -> enqueue_job(state, ref, job) end)
  end

  def handle_call(_other, _from, state), do: {:reply, {:error, :unknown}, state}

  @impl GenServer
  def handle_cast(_other, state), do: {:noreply, state}

  @impl GenServer
  def handle_info(message, state), do: guarded(state, nil, fn -> info(message, state) end)

  defp enqueue_job(%{task: nil} = state, ref, job) do
    case start(state, ref, job) do
      {:ok, state} -> {:reply, :ok, state}
      :error -> {:reply, :busy, wait_for_idle(state)}
    end
  end

  defp enqueue_job(state, ref, job) do
    if :queue.len(state.waiting) < @max_waiting,
      do: {:reply, :ok, %{state | waiting: :queue.in({ref, job}, state.waiting)}},
      else: {:reply, :full, state}
  end

  defp info({task_ref, _result}, %{task: %Task{ref: task_ref}} = state) do
    Process.demonitor(task_ref, [:flush])
    {:noreply, next(state)}
  end

  defp info({:DOWN, task_ref, :process, _pid, _reason}, %{task: %Task{ref: task_ref}} = state),
    do: {:noreply, next(state)}

  defp info(:idle, %{task: nil} = state) do
    if :queue.is_empty(state.waiting), do: {:stop, :normal, state}, else: {:noreply, state}
  end

  defp info(_other, state), do: {:noreply, state}

  defp guarded(state, reply, fun) do
    fun.()
  rescue
    exception -> failed(exception.__struct__, state, reply)
  catch
    kind, _reason -> failed(kind, state, reply)
  end

  defp failed(kind, state, reply) do
    require Logger
    Logger.warning("[PhoenixKitAgent] telegram chat queue failed: #{inspect(kind)}")
    if reply, do: {:stop, :queue_failed, reply, state}, else: {:stop, :queue_failed, state}
  end

  @impl GenServer
  def format_status(status) do
    status
    |> Map.update(:state, nil, fn _state -> :redacted end)
    |> Map.update(:message, nil, fn _message -> :redacted end)
    |> Map.update(:reason, nil, &reason_kind/1)
  end

  # The kind of the failure, none of its arguments.
  defp reason_kind({%{__struct__: module}, _stacktrace}), do: module
  defp reason_kind({kind, _detail}) when is_atom(kind), do: kind
  defp reason_kind(reason) when is_atom(reason), do: reason
  defp reason_kind(_other), do: :redacted

  # `{:ok, state}`, or `:error` when the task supervisor would not take the
  # turn (the job is answered "busy" by the caller or here).
  defp start(state, ref, job) do
    if state.idle, do: Process.cancel_timer(state.idle)
    connection_uuid = state.connection_uuid

    task = Task.Supervisor.async_nolink(@tasks, fn -> Turn.run(connection_uuid, ref, job) end)
    {:ok, %{state | task: task, idle: nil}}
  rescue
    exception in RuntimeError ->
      # Only the full supervisor; any other RuntimeError is a bug, not "busy".
      if exception.message =~ "maximum number of tasks",
        do: :error,
        else: reraise(exception, __STACKTRACE__)
  catch
    # The supervisor is restarting.
    :exit, _reason -> :error
  end

  defp next(state) do
    state = %{state | task: nil}

    case :queue.out(state.waiting) do
      {{:value, {ref, job}}, rest} ->
        state = %{state | waiting: rest}

        case start(state, ref, job) do
          {:ok, started} ->
            started

          :error ->
            Bridge.busy(state.connection_uuid, ref, job)
            next(state)
        end

      {:empty, _} ->
        wait_for_idle(state)
    end
  end

  defp wait_for_idle(state),
    do: %{state | idle: Process.send_after(self(), :idle, idle_ms())}

  defp idle_ms, do: Application.get_env(:phoenix_kit_agent, :telegram_queue_idle_ms, 60_000)
end
