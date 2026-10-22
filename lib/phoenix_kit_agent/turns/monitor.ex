defmodule PhoenixKitAgent.Turns.Monitor do
  @moduledoc """
  Starts the task of each turn under `PhoenixKitAgent.Turns.TaskSupervisor`,
  watches it, and ends the turn whatever way the task ends (spec §6.1 step 5):

    * the task returns — the turn wrote its own answer or notice;
    * the deadline passes (`agent_turn_deadline_s`, counted from the
      go-ahead) — the task is asked to stop (below) and a `deadline` notice
      is written;
    * the user stops it (`PhoenixKitAgent.Turns.stop/4`, `request_stop/2`) —
      nothing is written, a partial answer is not kept;
    * its chat was deleted (`{:shutdown, :chat_gone}`) — nothing is written;
    * it ends in any way before its go-ahead (see below) — nothing is
      written: the turn wrote nothing yet;
    * anything else (a crash, a message the database refused, a kill) — an
      `interrupted` notice.

  Then both locks of the turn are released and the chat's topic hears
  `{:agent_turn_finished, conversation_uuid, turn_ref}` (also for a turn that
  never started — a listener matches the `turn_ref` it got from
  `PhoenixKitAgent.Turns.start/6`). Those writes run in a short-lived process
  of their own, so a slow database delays no other start and no deadline; if
  that process cannot be started (the task supervisor is restarting), they
  run here.

  ## Stopping: a request first, a kill after the grace period

  Neither "Stop" nor the deadline kills the task outright: a model call under
  way would die before `phoenix_kit_ai` writes its journal row, and what it
  cost would be lost to the limits. The monitor sends the task a stop request,
  which the task honours between its steps (`check_stop/0`, see
  `PhoenixKitAgent.Turns.Runner`), and kills it only if it is still there
  after the grace period (`:turn_stop_grace_ms`, default 30 s — within the 60
  s a lock outlives its deadline). However the task then ends, the turn ends
  as stopped or past its deadline. A second request, or a deadline after a
  stop, changes nothing.

  ## Stopping a turn of another node

  A "Stop" that reaches a node where the turn does not run (its task is not in
  this node's `PhoenixKitAgent.Turns.Registry`) is passed on over PubSub
  (`broadcast_stop/1`): the topic `agent:turn:<turn_ref>` (`topic/1`) hears
  `{:agent_stop_turn, turn_ref}` — the turn ref and nothing else. The monitor
  listens to the topic of every turn it runs, from its start to its end, and
  takes such a request as it takes a local "Stop" (`request_stop/2`); a request
  for a turn ref it does not run is ignored. Who may stop the turn is checked
  where the request is made (`PhoenixKitAgent.Turns.stop/4`).

  ## Nothing of a turn in the log

  A turn carries the user's text, the history, the system prompt and the
  session reference. None of it may reach the log, so: the task runs the turn
  inside a guard and ends with `{:shutdown, _}` whatever happens (no crash
  report; a crash is logged as the exception's module and where it happened,
  without arguments); a refusal returns only the class of an exit
  (`t:exit_class/0`), never the exit term; and `format_status/1` keeps the
  turn out of this process's own crash report.

  ## The start handshake

  The task is monitored before it does anything. It registers in
  `PhoenixKitAgent.Turns.Registry` under its `turn_ref`, tells the process
  that starts the turn so, and waits for that process's go-ahead — not this
  one's. So a turn runs only once `start_turn/3` has returned `{:ok, pid}` to
  its caller, and is then already reachable for "Stop". A caller that gave up
  (this process was too busy to take the start in time, or the task did not
  report ready) sends no go-ahead, and the task ends on its own without
  touching the chat or the locks its caller has already released.

  The deadline is armed only when the task reports that it got the
  go-ahead, so a task whose caller gave up can never be killed as `:deadline`
  and write a notice under a turn ref nobody saw.

  If this process goes down, the supervisor (`:rest_for_one`) takes the
  running turns down with it; their locks then expire by their TTL.
  """

  use GenServer

  require Logger

  alias PhoenixKit.PubSub.Manager, as: PubSub
  alias PhoenixKitAgent.Conversations
  alias PhoenixKitAgent.Turns.{Locks, Runner}

  @registry PhoenixKitAgent.Turns.Registry
  @task_supervisor PhoenixKitAgent.Turns.TaskSupervisor

  # The handshake's unit, in ms: the caller waits up to twice this for this
  # process to take the start and once this for the task to be ready; the
  # task waits up to twice this for the go-ahead.
  @handshake_ms 5_000

  # How long a task asked to stop may take to get there before it is killed.
  @stop_grace_ms 30_000

  @stop {__MODULE__, :stop}

  @typedoc """
  What kind of exit made a start fail — never the exit term itself, which can
  hold the whole turn.
  """
  @type exit_class :: :timeout | :noproc | :shutdown | :killed | :unavailable | :crash

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Starts `turn` (see `PhoenixKitAgent.Turns.Runner`) in a task with
  `deadline_ms` to live, and lets it run once it is registered (see "The start
  handshake"). `callers` become the task's `$callers`, so the process that
  started the turn is its caller, as for a `Task` it starts.
  """
  @spec start_turn(Runner.turn(), pos_integer(), [pid()]) ::
          {:ok, pid()}
          | {:error, {:monitor_unavailable, exit_class()} | {:not_started, exit_class()}}
  def start_turn(turn, deadline_ms, callers) do
    token = Process.alias()

    try do
      with {:ok, pid} <- request_start(turn, deadline_ms, callers, token),
           :ok <- await_ready(pid, token) do
        send(pid, {:turn_go, token})
        {:ok, pid}
      end
    after
      Process.unalias(token)
      flush_ready(token)
    end
  end

  # The exit of the call holds the call's arguments — the whole turn.
  defp request_start(turn, deadline_ms, callers, token) do
    GenServer.call(__MODULE__, {:start, turn, deadline_ms, callers, token}, handshake_ms() * 2)
  catch
    :exit, reason -> {:error, {:monitor_unavailable, exit_class(reason)}}
  end

  defp await_ready(pid, token) do
    ref = Process.monitor(pid)

    receive do
      {:turn_ready, ^token} ->
        Process.demonitor(ref, [:flush])
        :ok

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, {:not_started, exit_class(reason)}}
    after
      handshake_ms() ->
        Process.demonitor(ref, [:flush])
        Process.exit(pid, {:shutdown, :not_started})
        {:error, {:not_started, :timeout}}
    end
  end

  @doc false
  # The class of an exit reason, for a refusal or a log line.
  @spec exit_class(term()) :: exit_class()
  def exit_class({reason, {GenServer, :call, _call}}), do: exit_class(reason)
  def exit_class(:timeout), do: :timeout
  def exit_class(:noproc), do: :noproc
  def exit_class(reason) when reason in [:normal, :shutdown], do: :shutdown
  def exit_class({:shutdown, _}), do: :shutdown
  def exit_class(reason) when reason in [:killed, :kill], do: :killed
  def exit_class(_crash), do: :crash

  # A ready message that came in as the wait gave up; nothing else is sent to
  # the alias, and after `unalias/1` nothing more arrives.
  defp flush_ready(token) do
    receive do
      {:turn_ready, ^token} -> :ok
    after
      0 -> :ok
    end
  end

  defp handshake_ms,
    do: Application.get_env(:phoenix_kit_agent, :turn_handshake_ms, @handshake_ms)

  @doc """
  The grace period, in ms, a task asked to stop has before it is killed
  (`:turn_stop_grace_ms`, default 30 s).
  """
  @spec stop_grace_ms() :: non_neg_integer()
  def stop_grace_ms,
    do: Application.get_env(:phoenix_kit_agent, :turn_stop_grace_ms, @stop_grace_ms)

  @doc """
  Asks the turn whose task is `pid` to stop (`reason` `:stopped`); it is
  killed if it has not stopped within the grace period. Asynchronous.
  `{:error, :not_running}` while the monitor is not up (it restarts, and its
  tasks go with it).
  """
  @spec request_stop(pid(), :stopped) :: :ok | {:error, :not_running}
  def request_stop(pid, :stopped = reason) when is_pid(pid) do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :not_running}

      monitor ->
        send(monitor, {:request_stop, pid, reason})
        :ok
    end
  end

  @doc "The PubSub topic of the turn `turn_ref`: `agent:turn:<turn_ref>`."
  @spec topic(String.t()) :: String.t()
  def topic(turn_ref) when is_binary(turn_ref), do: "agent:turn:" <> turn_ref

  @doc """
  Asks the monitor of whichever node runs `turn_ref` to stop it (see "Stopping
  a turn of another node"); the message is the turn ref only. Asynchronous: a
  turn that no node runs is not told. `{:error, :not_running}` when PubSub
  refuses the message or is not there (it restarts).
  """
  @spec broadcast_stop(String.t()) :: :ok | {:error, :not_running}
  def broadcast_stop(turn_ref) when is_binary(turn_ref) do
    case PubSub.broadcast(topic(turn_ref), {:agent_stop_turn, turn_ref}) do
      :ok -> :ok
      {:error, _reason} -> {:error, :not_running}
    end
  rescue
    _no_pubsub -> {:error, :not_running}
  catch
    _kind, _reason -> {:error, :not_running}
  end

  @doc """
  In a turn's task: ends it as `{:shutdown, reason}` if it was asked to stop,
  else `:ok`. The turn calls it between its steps.
  """
  @spec check_stop() :: :ok
  def check_stop do
    receive do
      {@stop, reason} -> exit({:shutdown, reason})
    after
      0 -> :ok
    end
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{}}

  @impl GenServer
  def handle_call({:start, turn, deadline_ms, callers, token}, _from, turns) do
    go_wait = handshake_ms() * 2

    case start_task(fn -> task(turn, callers, token, go_wait) end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        listen(turn.turn_ref, :subscribe)

        entry = %{
          turn: Map.take(turn, [:turn_ref, :user_uuid, :conversation_uuid]),
          pid: pid,
          deadline_ms: deadline_ms,
          timer: nil,
          kill_timer: nil,
          running?: false,
          stop: nil
        }

        {:reply, {:ok, pid}, Map.put(turns, ref, entry)}

      {:error, class} ->
        {:reply, {:error, {:not_started, class}}, turns}
    end
  end

  @impl GenServer
  # The task got its go-ahead: its deadline runs from now.
  def handle_info({:turn_running, pid}, turns) do
    case Enum.find(turns, fn {_ref, entry} -> entry.pid == pid end) do
      {ref, %{running?: false} = entry} ->
        timer = Process.send_after(self(), {:deadline, ref}, entry.deadline_ms)
        {:noreply, Map.put(turns, ref, %{entry | running?: true, timer: timer})}

      _unknown_or_running ->
        {:noreply, turns}
    end
  end

  def handle_info({:deadline, ref}, turns), do: {:noreply, ask_to_stop(turns, ref, :deadline)}

  def handle_info({:request_stop, pid, reason}, turns) do
    case Enum.find(turns, fn {_ref, entry} -> entry.pid == pid end) do
      {ref, _entry} -> {:noreply, ask_to_stop(turns, ref, reason)}
      nil -> {:noreply, turns}
    end
  end

  # A "Stop" made on another node (`broadcast_stop/1`).
  def handle_info({:agent_stop_turn, turn_ref}, turns) when is_binary(turn_ref) do
    case Enum.find(turns, fn {_ref, entry} -> entry.turn.turn_ref == turn_ref end) do
      {ref, _entry} -> {:noreply, ask_to_stop(turns, ref, :stopped)}
      nil -> {:noreply, turns}
    end
  end

  # The grace period is over and the task is still there.
  def handle_info({:kill, ref}, turns) do
    case Map.fetch(turns, ref) do
      {:ok, entry} -> Process.exit(entry.pid, :kill)
      :error -> :ok
    end

    {:noreply, turns}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, turns) do
    case Map.pop(turns, ref) do
      {nil, turns} ->
        {:noreply, turns}

      {entry, turns} ->
        if entry.timer, do: Process.cancel_timer(entry.timer)
        if entry.kill_timer, do: Process.cancel_timer(entry.kill_timer)
        turn = entry.turn
        listen(turn.turn_ref, :unsubscribe)
        ending = ending(entry, reason)

        case start_task(fn -> finish(turn, ending) end) do
          {:ok, _pid} -> :ok
          {:error, _class} -> finish(turn, ending)
        end

        {:noreply, turns}
    end
  end

  def handle_info(_other, turns), do: {:noreply, turns}

  # A PubSub that is not there makes the turn unstoppable from another node,
  # but must not take this process down, and every running turn with it.
  defp listen(turn_ref, action) do
    apply(PubSub, action, [topic(turn_ref)])
  rescue
    error ->
      Logger.warning("[PhoenixKitAgent] turn topic #{action}: #{inspect(error.__struct__)}")
  catch
    kind, reason ->
      Logger.warning("[PhoenixKitAgent] turn topic #{action}: #{kind} #{exit_class(reason)}")
  end

  # The first request wins: a deadline after "Stop" does not make the turn a
  # deadline, and the grace period is not restarted.
  defp ask_to_stop(turns, ref, reason) do
    case Map.fetch(turns, ref) do
      {:ok, %{stop: nil} = entry} ->
        send(entry.pid, {@stop, reason})
        kill_timer = Process.send_after(self(), {:kill, ref}, stop_grace_ms())
        Map.put(turns, ref, %{entry | stop: reason, kill_timer: kill_timer})

      _gone_or_stopping ->
        turns
    end
  end

  # A task supervisor that is restarting is not there for a moment:
  # `start_child` then exits (`:noproc`) instead of answering.
  defp start_task(fun) do
    case Task.Supervisor.start_child(@task_supervisor, fun) do
      {:ok, pid} -> {:ok, pid}
      {:error, _reason} -> {:error, :unavailable}
    end
  catch
    :exit, reason -> {:error, exit_class(reason)}
  end

  @impl GenServer
  # The last message of a crash can be `{:start, turn, ...}`, and its reason
  # can carry the turn in an exception or a stack frame's arguments.
  def format_status(status) do
    status
    |> Map.replace_lazy(:message, &redact_message/1)
    |> Map.replace(:log, [])
    |> Map.replace_lazy(:reason, &redact_reason/1)
  end

  defp redact_message({:"$gen_call", from, {:start, turn, _deadline, _callers, _token}}),
    do: {:"$gen_call", from, {:start, Map.take(turn, [:turn_ref])}}

  defp redact_message(message), do: message

  defp redact_reason({exception, stacktrace})
       when is_exception(exception) and is_list(stacktrace),
       do: {exception.__struct__, without_arguments(stacktrace)}

  defp redact_reason(reason) when is_atom(reason), do: reason
  defp redact_reason(reason), do: exit_class(reason)

  # ── the task ────────────────────────────────────────────────────

  defp task(turn, callers, token, go_wait) do
    guarded(fn ->
      Process.put(:"$callers", callers)
      {:ok, _} = Registry.register(@registry, turn.turn_ref, turn.conversation_uuid)
      send(token, {:turn_ready, token})

      receive do
        {:turn_go, ^token} ->
          send(__MODULE__, {:turn_running, self()})
          Runner.run(turn)
      after
        go_wait -> exit({:shutdown, :not_started})
      end
    end)
  end

  # Runs the turn so that it ends normally or with `{:shutdown, _}`: an
  # exception or an exit whose term may hold the turn's data is logged as its
  # class and location only, and ends the task as `{:shutdown, :crashed}`.
  defp guarded(fun) do
    fun.()
  rescue
    exception ->
      log_crash(inspect(exception.__struct__), __STACKTRACE__)
      exit({:shutdown, :crashed})
  catch
    :exit, {:shutdown, _} = reason ->
      exit(reason)

    kind, reason ->
      log_crash("#{kind} #{exit_class(reason)}", __STACKTRACE__)
      exit({:shutdown, :crashed})
  end

  defp log_crash(what, stacktrace) do
    where =
      case without_arguments(stacktrace) do
        [frame | _] -> " at " <> Exception.format_stacktrace_entry(frame)
        [] -> ""
      end

    Logger.error("[PhoenixKitAgent] a turn crashed: #{what}#{where}")
  end

  defp without_arguments(stacktrace) do
    Enum.map(stacktrace, fn
      {module, fun, args, location} when is_list(args) -> {module, fun, length(args), location}
      {fun, args, location} when is_list(args) -> {fun, length(args), location}
      frame -> frame
    end)
  end

  # ── the end of a turn ───────────────────────────────────────────

  defp finish(turn, ending) do
    safely(fn -> write_end(turn, ending) end)
    safely(fn -> Locks.release(turn.user_uuid, turn.conversation_uuid, turn.turn_ref) end)

    # A PubSub that is not there raises; when this runs in the monitor itself
    # (no task could be started) that would take every running turn down.
    safely(fn ->
      PubSub.broadcast(
        Conversations.topic(turn.conversation_uuid),
        {:agent_turn_finished, turn.conversation_uuid, turn.turn_ref}
      )
    end)
  end

  # A task that returned is done, even when its deadline fired a moment late;
  # one that never got its go-ahead wrote nothing, however it ended.
  defp ending(_entry, :normal), do: :done
  defp ending(%{running?: false}, _reason), do: :not_started
  defp ending(%{stop: :deadline}, _reason), do: :deadline
  defp ending(%{stop: :stopped}, _reason), do: :stopped
  defp ending(_entry, {:shutdown, :chat_gone}), do: :chat_gone
  defp ending(_entry, _reason), do: :interrupted

  defp write_end(_turn, ending) when ending in [:done, :stopped, :not_started, :chat_gone],
    do: :ok

  defp write_end(turn, :deadline) do
    add_notice(
      turn,
      "deadline",
      "The answer took longer than allowed and was stopped. Try again, or ask for less at once."
    )
  end

  defp write_end(turn, :interrupted),
    do: add_notice(turn, "interrupted", "The answer was interrupted. Try again.")

  defp add_notice(turn, error, content) do
    Conversations.add_turn_message(turn.user_uuid, turn.conversation_uuid, %{
      turn_ref: turn.turn_ref,
      role: "notice",
      content: content,
      error: error
    })
  end

  defp safely(fun) do
    fun.()
  rescue
    error -> Logger.warning("[PhoenixKitAgent] ending a turn: #{inspect(error.__struct__)}")
  catch
    kind, reason ->
      Logger.warning("[PhoenixKitAgent] ending a turn: #{kind} #{exit_class(reason)}")
  end
end
