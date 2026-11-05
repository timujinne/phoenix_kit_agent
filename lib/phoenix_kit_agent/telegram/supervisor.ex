defmodule PhoenixKitAgent.Telegram.Supervisor do
  @moduledoc """
  The processes of the Telegram bridge, started by the host through
  `PhoenixKitAgent.children/0`:

    * `PhoenixKitAgent.Telegram.Limiter` — what is remembered about chats that
      are not linked;
    * `PhoenixKitAgent.Telegram.Registry` and
      `PhoenixKitAgent.Telegram.QueueSupervisor` — the queue of each active
      chat, at most 20 at a time;
    * `PhoenixKitAgent.Telegram.TaskSupervisor` — the turns of the queues and
      the replies that need no turn;
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
        PhoenixKitAgent.Telegram.Limiter,
        {Registry, keys: :unique, name: PhoenixKitAgent.Telegram.Registry},
        {DynamicSupervisor,
         name: PhoenixKitAgent.Telegram.QueueSupervisor, strategy: :one_for_one, max_children: 20},
        {Task.Supervisor, name: PhoenixKitAgent.Telegram.TaskSupervisor, max_children: 100},
        PhoenixKitAgent.Telegram.Reader
      ],
      strategy: :one_for_one
    )
  end
end
