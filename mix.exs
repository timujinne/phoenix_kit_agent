defmodule PhoenixKitAgent.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_agent"

  def project do
    [
      app: :phoenix_kit_agent,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description:
        "AI agent module for PhoenixKit — per-user chats with tool calling over the PhoenixKit API registry",
      package: package(),
      dialyzer: [
        plt_add_apps: [:phoenix_kit, :phoenix_kit_ai],
        ignore_warnings: ".dialyzer_ignore.exs"
      ],
      name: "PhoenixKitAgent",
      source_url: @source_url,
      docs: docs(),
      test_coverage: [
        ignore_modules: [
          ~r/^PhoenixKitAgent\.Test\./,
          PhoenixKitAgent.DataCase
        ]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger, :gettext, :phoenix_kit, :phoenix_kit_ai]]
  end

  def cli do
    [preferred_envs: ["test.setup": :test, "test.reset": :test]]
  end

  # test/support/ is compiled only in :test so DataCase and TestRepo
  # don't leak into the published package.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": ["format --check-formatted", "credo --strict", "dialyzer"],
      precommit: [
        "format",
        "compile --force --warnings-as-errors",
        "gettext.extract --check-up-to-date",
        "deps.unlock --check-unused",
        # Scan for retired Hex deps. Run via `cmd` so Hex bootstraps in a fresh
        # process — the hex.* archive tasks aren't resolvable via Mix.Task.run
        # inside an alias.
        "cmd mix hex.audit",
        "quality.ci"
      ],
      "test.setup": [
        "ecto.create --quiet -r PhoenixKitAgent.Test.Repo"
      ],
      "test.reset": [
        "ecto.drop --quiet -r PhoenixKitAgent.Test.Repo",
        "test.setup"
      ]
    ]
  end

  # phoenix_kit deps resolve from their pin (Hex requirement or git source). For
  # cross-repo work against a local checkout, export <APP>_PATH — e.g.
  # PHOENIX_KIT_PATH=../phoenix_kit or PHOENIX_KIT_AI_PATH=../phoenix_kit_ai.
  # Unset => the pin.
  defp pk_dep(app, requirement_or_source, opts \\ []) do
    env_var = String.upcase(Atom.to_string(app)) <> "_PATH"

    case System.get_env(env_var) do
      nil when is_list(requirement_or_source) -> {app, requirement_or_source ++ opts}
      nil when opts == [] -> {app, requirement_or_source}
      nil -> {app, requirement_or_source, opts}
      path -> {app, [path: path, override: true] ++ opts}
    end
  end

  defp deps do
    [
      # PhoenixKit provides the Module behaviour, the Settings API, the API
      # Executor (execute_as/visible_for), SessionRef and hidden Storage
      # libraries.
      # Pinned to upstream main 435d5b3, which carries #948, #949 and #950
      # (merged). Hex 2.63.0 does not carry these functions; switch back to a
      # Hex requirement once a release ships them.
      pk_dep(:phoenix_kit,
        git: "https://github.com/BeamLabEU/phoenix_kit.git",
        ref: "435d5b3275fe208e5674f337b91479f603e4f0df",
        override: true
      ),

      # Model calls, endpoints, credentials, budget and the request journal
      # come from phoenix_kit_ai; this module only adds the chat layer.
      # Integration pin until release: the fork's integration branch
      # (upstream + #38, tool calling).
      pk_dep(:phoenix_kit_ai,
        git: "https://github.com/timujinne/phoenix_kit_ai.git",
        ref: "06cc9ff9c8030e73bac47748cb07350617aa14f6",
        override: true
      ),

      # LiveView is needed for the admin pages (Phase 1).
      {:phoenix_live_view, "~> 1.1"},

      # Attachments: a sheet (xlsx) becomes CSV text for the model. nimble_csv
      # is already in the tree (phoenix_kit's); it is named here because the
      # module calls it itself.
      {:xlsx_reader, "~> 0.8"},
      {:nimble_csv, "~> 1.2"},

      # The chat panel renders model answers from the markdown tree, so no
      # picture or raw HTML reaches the page. Already in the tree (phoenix_kit's);
      # named here because the module calls it itself.
      {:mdex, "~> 0.13"},

      # The module's own gettext backend for its admin pages.
      {:gettext, "~> 1.0"},

      # Optional rustler pin so the transitive `mdex_native` NIF (via phoenix_kit,
      # a test dependency) can source-build on hosts where its precompiled variant
      # doesn't match the local NIF version.
      {:rustler, ">= 0.0.0", optional: true},

      # Documentation
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},

      # LiveView tests (Phoenix.LiveViewTest parses the rendered HTML with it).
      {:lazy_html, ">= 0.1.0", only: :test},

      # Code quality
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "PhoenixKitAgent",
      source_ref: "v#{@version}"
    ]
  end
end
