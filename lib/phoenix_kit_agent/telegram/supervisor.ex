defmodule PhoenixKitAgent.Telegram.Supervisor do
  @moduledoc """
  The processes of the Telegram bridge, started by the host through
  `PhoenixKitAgent.children/0`:

    * `PhoenixKitAgent.Telegram.Registry` and
      `PhoenixKitAgent.Telegram.QueueSupervisor` — the queue of each active
      chat, at most 20 at a time;
    * `PhoenixKitAgent.Telegram.TaskSupervisor` — the turns of the queues;
    * `PhoenixKitAgent.Telegram.ReplySupervisor` — the replies that need no
      turn, apart from the turns so that they cannot take their place;
    * `PhoenixKitAgent.Telegram.Limiter` — what is remembered about chats that
      are not linked and the pace of the replies that need no turn; only the
      reader's bridge uses it, so it comes late and its restart does not touch
      the queues;
    * `PhoenixKitAgent.Telegram.Reader` — the reader of the bot, last, so
      everything it hands work to is there.
  """

  use Supervisor

  @doc false
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Supervisor
  def init(_opts) do
    Supervisor.init(
      [
        {Registry, keys: :unique, name: PhoenixKitAgent.Telegram.Registry},
        {DynamicSupervisor,
         name: PhoenixKitAgent.Telegram.QueueSupervisor, strategy: :one_for_one, max_children: 20},
        Supervisor.child_spec(
          {Task.Supervisor, name: PhoenixKitAgent.Telegram.TaskSupervisor, max_children: 100},
          id: :turn_supervisor
        ),
        Supervisor.child_spec(
          {Task.Supervisor, name: PhoenixKitAgent.Telegram.ReplySupervisor, max_children: 50},
          id: :reply_supervisor
        ),
        PhoenixKitAgent.Telegram.Limiter,
        PhoenixKitAgent.Telegram.Reader
      ],
      # The registry names the queues, and the queues start the turns: what
      # follows a restarted child is restarted with it.
      strategy: :rest_for_one
    )
  end
end
