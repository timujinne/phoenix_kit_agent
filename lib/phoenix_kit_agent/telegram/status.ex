defmodule PhoenixKitAgent.Telegram.Status do
  @moduledoc """
  What the Settings page tells about the assistant in Telegram, as one of:

    * `:off` — the switch is off;
    * `:no_bot` — no website bot is chosen for notifications;
    * `:webhook` — the bot has a webhook, so its updates cannot be read;
    * `:conflict` — someone else reads the bot;
    * `:no_model` — nobody can be answered: no default model is chosen;
    * `:reading` — the bot is being read (on this node or another);
    * `:starting` — switched on, not reading yet.

  The first three and the conflict are this node's reader's own word
  (`PhoenixKitAgent.Telegram.Reader.status/0`); whether the bot is being read
  at all is asked of the cluster (`Reader.holds?/1`).
  """

  alias PhoenixKitAgent.Config
  alias PhoenixKitAgent.Telegram.{Client, Reader}

  @type t :: :off | :no_bot | :webhook | :conflict | :no_model | :reading | :starting

  @doc "The `@username` of the bot (without the `@`), or `nil` when no bot is chosen or it cannot be told."
  @spec bot() :: String.t() | nil
  def bot do
    with connection when is_binary(connection) <- Client.impl().connection_uuid() do
      Client.impl().bot_username(connection)
    end
  rescue
    _ -> nil
  end

  @doc "The state now."
  @spec current() :: t()
  def current do
    connection = Client.impl().connection_uuid()

    cond do
      not Config.telegram_enabled?() -> :off
      is_nil(connection) -> :no_bot
      Reader.status() == :webhook -> :webhook
      Reader.status() == :conflict -> :conflict
      is_nil(Config.default_endpoint_uuid()) -> :no_model
      Reader.holds?(connection) -> :reading
      true -> :starting
    end
  end
end
