defmodule PhoenixKitAgent.Test.TelegramClient do
  @moduledoc """
  A stand-in for `PhoenixKitAgent.Telegram.Client`: every call is reported to
  the test process named in `:telegram_test_listener` as `{:tg, call, …}`,
  and the answers come from a script kept in an `Agent`:

    * `connection_uuid`, `bot_username`, `webhook_set?` — `set(:connection, uuid)`,
      `set(:bot_username, name)` and `set(:webhook, boolean)`;
    * `get_updates` — the next element of `set(:updates, [answer, …])` (each
      `{:ok, [update]}` or `{:error, reason}`, or a function of no arguments that
      runs while "Telegram" is being asked and answers so; `{:ok, []}` once it
      is empty);
    * `send_message` — `set(:send, fun)` with `fun.(chat_id, text)` (or `fun.(chat_id, text, opts)`) answering
      `{:ok, message}` or `{:error, reason}` (default: ok, with the next
      `"message_id"`, 5000, 5001, …). A call with options (`reply_markup:`)
      comes to the test as `{:tg, {:send_message, uuid, chat_id, text, opts}}`;
    * `answer_callback` — `set(:answer, fun)` with `fun.(callback_id, text)`
      (default: ok); comes as `{:tg, {:answer_callback, uuid, callback_id, text}}`;
    * `edit_message` — `set(:edit, fun)` with `fun.(message_id, text, markup)`
      (default: ok); comes as `{:tg, {:edit_message, uuid, chat_id, message_id,
      text, markup}}`;
    * `react` — `set(:react, fun)` with `fun.(chat_id, message_id, emoji)`
      (default: ok);
    * `can_download?` — `set(:can_download, boolean)` (default: true);
    * `download_file` — `set(:download, fun)` with `fun.(file_id, opts)` answering
      `{:ok, bytes}` or `{:error, reason}` (default: ok, `"OggS-voice-bytes"`);
      comes as `{:tg, {:download_file, uuid, file_id, opts}}`.
  """

  @behaviour PhoenixKitAgent.Telegram.Client

  def start do
    # Not linked to the test: a bot's job still running as the test ends must
    # find the script, not an exit (`stop/0`, in `on_exit`, ends it).
    {:ok, pid} =
      Agent.start(fn -> %{connection: nil, webhook: false, updates: [], next_id: 5000} end)

    Application.put_env(:phoenix_kit_agent, :telegram_script, pid)
    Application.put_env(:phoenix_kit_agent, :telegram_client, __MODULE__)
    Application.put_env(:phoenix_kit_agent, :telegram_test_listener, self())
    pid
  end

  def stop do
    with pid when is_pid(pid) <- Application.get_env(:phoenix_kit_agent, :telegram_script),
         do: if(Process.alive?(pid), do: Agent.stop(pid))

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

  @doc "A press of the button with `data` under message `message_id` of the private chat `chat_id` (`opts`: `:id`, `:callback_id`, `:from`, `:chat_type`)."
  def callback_update(chat_id, data, opts \\ []) do
    %{
      "update_id" => Keyword.get(opts, :id, 1),
      "callback_query" => %{
        "id" => Keyword.get(opts, :callback_id, "cb-1"),
        "from" => %{"id" => Keyword.get(opts, :from, chat_id), "is_bot" => false},
        "message" => %{
          "message_id" => Keyword.get(opts, :message_id, 700),
          "date" => System.system_time(:second),
          "chat" => %{"id" => chat_id, "type" => Keyword.get(opts, :chat_type, "private")}
        },
        "data" => data
      }
    }
  end

  @doc """
  A private-chat voice message (`kind`: "voice" or "audio"; `opts`: as `update/3`,
  plus `:duration`, `:file_size`, `:file_id`, `:mime_type`).
  """
  def voice_update(chat_id, kind \\ "voice", opts \\ []) do
    media =
      %{"file_id" => Keyword.get(opts, :file_id, "voice-file-1"), "file_unique_id" => "u1"}
      |> then(&if(d = Keyword.get(opts, :duration, 5), do: Map.put(&1, "duration", d), else: &1))
      |> then(
        &if(z = Keyword.get(opts, :file_size, 20_000), do: Map.put(&1, "file_size", z), else: &1)
      )
      |> then(&if(m = Keyword.get(opts, :mime_type), do: Map.put(&1, "mime_type", m), else: &1))

    update(
      chat_id,
      nil,
      Keyword.update(opts, :extra, %{kind => media}, &Map.put(&1, kind, media))
    )
  end

  def set(key, value), do: Agent.update(script(), &Map.put(&1, key, value))

  @impl true
  def connection_uuid, do: Agent.get(script(), & &1.connection)

  @impl true
  def bot_username(_uuid) do
    case Agent.get(script(), &Map.get(&1, :bot_username)) do
      fun when is_function(fun, 0) -> fun.()
      name -> name
    end
  end

  @impl true
  def webhook_set?(uuid) do
    tell({:webhook_set?, uuid})
    Agent.get(script(), & &1.webhook)
  end

  @impl true
  def get_updates(uuid, opts) do
    tell({:get_updates, uuid, Keyword.take(opts, [:offset, :timeout, :limit, :allowed_updates])})

    Agent.get_and_update(script(), fn
      %{updates: [next | rest]} = state -> {next, %{state | updates: rest}}
      %{updates: []} = state -> {{:ok, []}, state}
    end)
    |> case do
      fun when is_function(fun, 0) -> fun.()
      answer -> answer
    end
  end

  @impl true
  def send_message(uuid, chat_id, text, opts) do
    tell(
      if(opts == [],
        do: {:send_message, uuid, chat_id, text},
        else: {:send_message, uuid, chat_id, text, opts}
      )
    )

    case Agent.get(script(), &Map.get(&1, :send)) do
      fun when is_function(fun, 2) -> fun.(chat_id, text)
      fun when is_function(fun, 3) -> fun.(chat_id, text, opts)
      nil -> {:ok, %{"message_id" => next_id()}}
    end
  end

  @impl true
  def answer_callback(uuid, callback_id, text) do
    tell({:answer_callback, uuid, callback_id, text})

    case Agent.get(script(), &Map.get(&1, :answer)) do
      fun when is_function(fun, 2) -> fun.(callback_id, text)
      nil -> {:ok, true}
    end
  end

  @impl true
  def edit_message(uuid, chat_id, message_id, text, markup) do
    tell({:edit_message, uuid, chat_id, message_id, text, markup})

    case Agent.get(script(), &Map.get(&1, :edit)) do
      fun when is_function(fun, 3) -> fun.(message_id, text, markup)
      nil -> {:ok, true}
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

  @impl true
  def can_download?, do: Agent.get(script(), &Map.get(&1, :can_download, true))

  @impl true
  def download_file(uuid, file_id, opts) do
    tell({:download_file, uuid, file_id, opts})

    case Agent.get(script(), &Map.get(&1, :download)) do
      fun when is_function(fun, 2) -> fun.(file_id, opts)
      nil -> {:ok, "OggS-voice-bytes"}
    end
  end

  defp next_id, do: Agent.get_and_update(script(), &{&1.next_id, %{&1 | next_id: &1.next_id + 1}})

  defp script, do: Application.fetch_env!(:phoenix_kit_agent, :telegram_script)

  defp tell(event) do
    case Application.get_env(:phoenix_kit_agent, :telegram_test_listener) do
      pid when is_pid(pid) -> send(pid, {:tg, event})
      _none -> :ok
    end
  end
end
