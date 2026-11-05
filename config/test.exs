import Config

# Integration tests need a real PostgreSQL database. Create it with:
#   createdb phoenix_kit_agent_test
config :phoenix_kit_agent, ecto_repos: [PhoenixKitAgent.Test.Repo]

# A turn asked to stop that is stuck in a stubbed model call is killed after
# this; the tests of the grace period itself set a longer one.
config :phoenix_kit_agent, turn_stop_grace_ms: 200

# The Telegram reader does not look at the bot by itself in tests; they call
# `Reader.cycle/2`. The pauses between a long answer's parts and before a
# retry are short.
config :phoenix_kit_agent,
  telegram_reader_autostart: false,
  telegram_part_pause_ms: 0,
  telegram_quick_reply_ms: 0,
  telegram_max_retry_ms: 50

# `PGDATABASE` lets this suite point at a database the test role isn't
# allowed to CREATE (e.g. a shared instance) instead of the name Hex CI
# provisions for itself. Same mechanism as core phoenix_kit's
# config/test.exs. Left unset (CI's case), this falls back to the default
# name, so publishing and CI are unaffected.
pg_test_db =
  case System.get_env("PGDATABASE") do
    value when is_binary(value) and value != "" -> String.trim(value)
    _ -> "phoenix_kit_agent_test#{System.get_env("MIX_TEST_PARTITION")}"
  end

# `PGPOOL` bounds the connection pool the same way core does — the default
# (`schedulers_online() * 2`) opens dozens of connections on a many-core
# box, which is not welcome against a shared instance.
pg_test_pool =
  case System.get_env("PGPOOL") do
    value when is_binary(value) and value != "" ->
      case Integer.parse(String.trim(value)) do
        {size, ""} when size > 0 -> size
        _ -> raise "PGPOOL must be a positive integer, got: #{inspect(value)}"
      end

    _ ->
      System.schedulers_online() * 2
  end

config :phoenix_kit_agent, PhoenixKitAgent.Test.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  database: pg_test_db,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: pg_test_pool

# Wire repo for PhoenixKit.RepoHelper — without this, all DB calls crash.
config :phoenix_kit, repo: PhoenixKitAgent.Test.Repo

config :phoenix, :json_library, Jason

# Keys the time-window tokens of private (hidden-library) file URLs; without it
# core mints a token that nothing accepts.
config :phoenix_kit, secret_key_base: String.duplicate("t", 64)

config :logger, level: :warning

config :phoenix_kit_agent, PhoenixKitAgent.Test.Endpoint,
  secret_key_base: String.duplicate("t", 64),
  live_view: [signing_salt: "agent-test-salt"],
  pubsub_server: PhoenixKitAgent.Test.PubSub,
  server: false,
  url: [host: "localhost"],
  render_errors: [formats: [html: PhoenixKitAgent.Test.Layouts]]
