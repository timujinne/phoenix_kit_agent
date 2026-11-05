defmodule PhoenixKitAgent.Test.TelegramClient do
  @moduledoc """
  A stand-in for `PhoenixKitAgent.Telegram.Client`: every call is reported to
  the test process named in `:telegram_test_listener` as `{:tg, call, …}`,
  and the answers come from a script kept in an `Agent`:

    * `connection_uuid`, `webhook_set?` — `set(:connection, uuid)` and
      `set(:webhook, boolean)`;
    * `get_updates` — the next element of `set(:updates, [answer, …])` (each
      `{:ok, [update]}` or `{:error, reason}`; `{:ok, []}` once it is empty);
    * `send_message` — `set(:send, fun)` with `fun.(chat_id, text)` answering
      `{:ok, %{}}` or `{:error, reason}` (default: ok);
    * `react` — `set(:react, fun)` with `fun.(chat_id, message_id, emoji)`
      (default: ok).
  """

  @behaviour PhoenixKitAgent.Telegram.Client

  def start do
    {:ok, pid} = Agent.start_link(fn -> %{connection: nil, webhook: false, updates: []} end)
    Application.put_env(:phoenix_kit_agent, :telegram_script, pid)
    Application.put_env(:phoenix_kit_agent, :telegram_client, __MODULE__)
    Application.put_env(:phoenix_kit_agent, :telegram_test_listener, self())
    pid
  end

  def stop do
    Application.delete_env(:phoenix_kit_agent, :telegram_script)
    Application.delete_env(:phoenix_kit_agent, :telegram_client)
    Application.delete_env(:phoenix_kit_agent, :telegram_test_listener)
  end

  @doc "A private-chat text message of `chat_id`, as the bot reads it (`opts`: `:date`, `:id`, `:message_id`, extra message fields as `:extra`)."
  def update(chat_id, text, opts \\ []) do
    message =
      %{
        "message_id" => Keyword.get(opts, :message_id, 100),
        "date" => Keyword.get(opts, :date, System.system_time(:second)),
        "chat" => %{"id" => chat_id, "type" => "private"},
        "from" => %{"id" => chat_id, "is_bot" => false}
      }
      |> then(&if(text, do: Map.put(&1, "text", text), else: &1))
      |> Map.merge(Keyword.get(opts, :extra, %{}))

    %{"update_id" => Keyword.get(opts, :id, 1), "message" => message}
  end

  def set(key, value), do: Agent.update(script(), &Map.put(&1, key, value))

  @impl true
  def connection_uuid, do: Agent.get(script(), & &1.connection)

  @impl true
  def webhook_set?(uuid) do
    tell({:webhook_set?, uuid})
    Agent.get(script(), & &1.webhook)
  end

  @impl true
  def get_updates(uuid, opts) do
    tell({:get_updates, uuid, Keyword.take(opts, [:offset, :timeout, :limit])})

    Agent.get_and_update(script(), fn
      %{updates: [next | rest]} = state -> {next, %{state | updates: rest}}
      %{updates: []} = state -> {{:ok, []}, state}
    end)
  end

  @impl true
  def send_message(uuid, chat_id, text) do
    tell({:send_message, uuid, chat_id, text})

    case Agent.get(script(), &Map.get(&1, :send)) do
      fun when is_function(fun, 2) -> fun.(chat_id, text)
      nil -> {:ok, %{}}
    end
  end

  @impl true
  def react(uuid, chat_id, message_id, emoji) do
    tell({:react, uuid, chat_id, message_id, emoji})

    case Agent.get(script(), &Map.get(&1, :react)) do
      fun when is_function(fun, 3) -> fun.(chat_id, message_id, emoji)
      nil -> {:ok, true}
    end
  end

  @impl true
  def typing(uuid, chat_id) do
    tell({:typing, uuid, chat_id})
    {:ok, true}
  end

  defp script, do: Application.fetch_env!(:phoenix_kit_agent, :telegram_script)

  defp tell(event) do
    case Application.get_env(:phoenix_kit_agent, :telegram_test_listener) do
      pid when is_pid(pid) -> send(pid, {:tg, event})
      _none -> :ok
    end
  end
end
