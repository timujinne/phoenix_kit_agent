# Test helper for PhoenixKitAgent.
#
# Level 1: Unit tests (pure functions, callbacks) always run.
# Level 2: Integration tests (tagged `:integration` via PhoenixKitAgent.DataCase)
#          need a real PostgreSQL database. `mix test` creates it through the
#          `test.setup` alias contract below; if it is unusable the run ABORTS —
#          it must not downgrade to "excluding :integration" and report green.
#
# First-time setup:
#
#   createdb phoenix_kit_agent_test      # or: mix test.setup
#
# The schema is built from core's versioned migrations via
# `PhoenixKit.Migration.ensure_current/2`, the same call a host app makes, and
# then from this module's own chain (`PhoenixKitAgent.Migrations`) through
# `Ecto.Migrator`, as the host's generated migration runs it.
#
# The ONLY sanctioned way to run without a database is the explicit opt-in
#
#   PK_AGENT_SKIP_DB=1 mix test
#
# which excludes `:integration` and says so loudly.

# Elixir 1.19 does not auto-load modules from test support paths at
# test-helper time, so load them explicitly.
support_dir = Path.expand("support", __DIR__)

[
  {PhoenixKitAgent.Test.Repo, "test_repo.ex"},
  {PhoenixKitAgent.Test.SchemaMigration, "schema_migration.ex"},
  {PhoenixKitAgent.Test.AISchemaMigration, "ai_schema_migration.ex"},
  {PhoenixKitAgent.Test.Layouts, "test_layouts.ex"},
  {PhoenixKitAgent.Test.Hooks, "hooks.ex"},
  {PhoenixKitAgent.Test.DockHostLive, "dock_host_live.ex"},
  {PhoenixKitAgent.Test.Router, "test_router.ex"},
  {PhoenixKitAgent.Test.Endpoint, "test_endpoint.ex"},
  {PhoenixKitAgent.Fixtures, "fixtures.ex"},
  {PhoenixKitAgent.Test.Tools, "agent_test_tools.ex"},
  {PhoenixKitAgent.Test.LogProbe, "log_probe.ex"},
  {PhoenixKitAgent.Test.Addenda, "prompt_addenda.ex"},
  {PhoenixKitAgent.Test.Files, "files.ex"},
  {PhoenixKitAgent.DataCase, "data_case.ex"},
  {PhoenixKitAgent.LiveCase, "live_case.ex"}
]
|> Enum.each(fn {mod, file} ->
  Code.ensure_loaded?(mod) || Code.require_file(file, support_dir)
end)

alias PhoenixKitAgent.Test.Repo, as: TestRepo

db_config = Application.get_env(:phoenix_kit_agent, TestRepo, [])
db_name = db_config[:database] || "phoenix_kit_agent_test"
skip_db? = System.get_env("PK_AGENT_SKIP_DB") in ["1", "true"]

repo_available =
  if skip_db? do
    IO.puts("""

    PK_AGENT_SKIP_DB=1 — skipping database "#{db_name}", excluding :integration tests.
    This is a manual opt-out for a machine with no Postgres; do NOT set it in CI.
    """)

    false
  else
    # One classified connection attempt with the repo's OWN credentials, before
    # the pool starts (ships in core; a failure here is a real infrastructure
    # problem, not something to route around).
    case PhoenixKit.TestSupport.PostgresPreflight.check(db_config) do
      :ok ->
        :ok

      {:error, _reason, message} ->
        IO.puts(:stderr, "\n" <> message)

        raise """
        Cannot reach test database "#{db_name}" — see the preflight diagnostic above.
        Run: createdb #{db_name}, or set PK_AGENT_SKIP_DB=1 to run unit tests only.
        """
    end

    {:ok, _} = TestRepo.start_link()
    PhoenixKit.Migration.ensure_current(TestRepo, log: false)

    # Keyed on the chain version, so a bump re-applies; the chain is
    # idempotent, so a re-run against an up-to-date database is a no-op.
    Ecto.Migrator.run(
      TestRepo,
      [{PhoenixKitAgent.Migrations.current_version(), PhoenixKitAgent.Test.SchemaMigration}],
      :up,
      all: true,
      log: false
    )

    # The chain of phoenix_kit_ai (the AI task guard's tables), the way the
    # host's migration runs it; its key is offset from this module's own.
    Ecto.Migrator.run(
      TestRepo,
      [
        {1_000 + PhoenixKitAI.Migrations.current_version(),
         PhoenixKitAgent.Test.AISchemaMigration}
      ],
      :up,
      all: true,
      log: false
    )

    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)
    true
  end

Application.put_env(:phoenix_kit_agent, :test_repo_available, repo_available)

# Minimal PhoenixKit services needed by the Settings API.
{:ok, _pid} = PhoenixKit.PubSub.Manager.start_link([])

# phoenix_kit_ai's request cache owns the table the AI guard keeps its
# admissions and its copy of the blocks in. Its capability cache is not
# started: it would read the providers' model lists; a test declares what a
# model can do on its endpoint instead.
{:ok, _pid} = PhoenixKitAI.RequestCache.start_link([])

# Module discovery: permission keys, sub-keys and `Scope.can?/2` read the
# registry (this module is found by its `@phoenix_kit_module` attribute).
{:ok, _pid} = PhoenixKit.ModuleRegistry.start_link([])

# `PhoenixKit.Users.Auth.register_user/2` goes through the Hammer-backed rate
# limiter, which needs its ETS table.
{:ok, _pid} = PhoenixKit.Users.RateLimiter.Backend.start_link([])

# Admin paths are written with the default locale (`/en/admin/...`), which is
# what the test router mounts.
:persistent_term.put({PhoenixKit.Config, :url_prefix}, "/")

if repo_available do
  # The module's own children (`PhoenixKitAgent.children/0`): the turn
  # registry, monitor and task supervisor, as the host's PhoenixKit.Supervisor
  # starts them.
  {:ok, _} = Supervisor.start_link(PhoenixKitAgent.children(), strategy: :one_for_one)

  {:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: PhoenixKitAgent.Test.PubSub)
  {:ok, _} = PhoenixKitAgent.Test.Endpoint.start_link()
end

exclude = if skip_db?, do: [:integration], else: []

# Attachment tests that need an external program carry its tag; without the
# program they are excluded, loudly, never passed.
missing_tools =
  [poppler: ["pdftotext", "pdftoppm", "pdfinfo"], imagemagick: ["convert", "identify"]]
  |> Enum.reject(fn {_tag, tools} -> Enum.all?(tools, &System.find_executable/1) end)
  |> Keyword.keys()

if missing_tools != [] do
  IO.puts("""

  Excluding tests tagged #{inspect(missing_tools)}: the program is not installed here.
  They did NOT run.
  """)
end

# `render_async/2` waits for `assert_receive_timeout` (100 ms by default): too
# short for a task that reads the database on a loaded machine.
ExUnit.start(exclude: exclude ++ missing_tools, assert_receive_timeout: 2_000)
