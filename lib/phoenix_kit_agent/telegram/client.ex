defmodule PhoenixKitAgent.Telegram.Client do
  @moduledoc """
  What the Telegram reader and bridge ask of the site bot, in one place: the
  calls to Telegram (`PhoenixKit.Integrations.Telegram`, owner `:system`) and
  the bot's connection (`PhoenixKit.Integrations.Telegram.SiteBot`). A bot is
  always named by its connection uuid: the token is resolved inside core's
  call and never held here, so no process of the module carries it.

  A host or a test may put another module with the same functions in
  `config :phoenix_kit_agent, :telegram_client`.
  """

  alias PhoenixKit.Integrations.Telegram
  alias PhoenixKit.Integrations.Telegram.SiteBot

  @type uuid :: String.t()
  @type chat_id :: integer()

  @callback connection_uuid() :: uuid() | nil
  @callback bot_username(uuid()) :: String.t() | nil
  @callback webhook_set?(uuid()) :: boolean()
  @callback get_updates(uuid(), keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback send_message(uuid(), chat_id(), String.t()) :: {:ok, term()} | {:error, term()}
  @callback react(uuid(), chat_id(), integer(), String.t() | nil) ::
              {:ok, term()} | {:error, term()}
  @callback typing(uuid(), chat_id()) :: {:ok, term()} | {:error, term()}

  @doc "The module that does the calls: the configured one, else this."
  @spec impl() :: module()
  def impl, do: Application.get_env(:phoenix_kit_agent, :telegram_client, __MODULE__)

  @behaviour __MODULE__

  @impl true
  def connection_uuid, do: SiteBot.connection_uuid()

  @impl true
  def bot_username(uuid), do: SiteBot.bot_username(uuid)

  @impl true
  def webhook_set?(uuid), do: SiteBot.webhook_set?(uuid)

  @impl true
  def get_updates(uuid, opts), do: Telegram.get_updates(uuid, [owner: :system] ++ opts)

  @impl true
  def send_message(uuid, chat_id, text),
    do: Telegram.send_message(uuid, chat_id, text, owner: :system)

  @impl true
  def react(uuid, chat_id, message_id, emoji),
    do: Telegram.set_message_reaction(uuid, chat_id, message_id, emoji, owner: :system)

  @impl true
  def typing(uuid, chat_id),
    do: Telegram.send_chat_action(uuid, chat_id, "typing", owner: :system)
end
