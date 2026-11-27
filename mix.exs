defmodule IdDidiSh.MixProject do
  use Mix.Project

  def project do
    [
      app: :id_didi_sh,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      test_coverage: test_coverage()
    ]
  end

  # The threshold is the measured floor, rounded down — not an aspiration. A
  # gate set above reality gets disabled the first time it blocks a hotfix.
  # Raise it when coverage rises; never lower it to get a change through.
  # See context-v/plans/Test-Coverage-Push-for-id-didi-sh.md.
  defp test_coverage do
    [
      summary: [threshold: 92],
      ignore_modules: [
        # embed_templates modules: the cover tool attributes HEEx to the
        # template file, so these read 0% even when every page is rendered
        # by a tested controller. Testing them directly would prove nothing.
        ~r/^IdDidiShWeb\..*HTML$/,
        IdDidiShWeb.Layouts,
        # Generator output nobody edits. Comes off this list if we start to.
        IdDidiShWeb.CoreComponents,
        # The `use IdDidiShWeb, :controller` macro module.
        IdDidiShWeb,
        # Supervision and telemetry wiring, exercised by booting at all.
        IdDidiSh.Application,
        IdDidiShWeb.Telemetry,
        # Release-only migration entry point (no Mix in the release).
        IdDidiSh.Release,
        # Test support.
        IdDidiSh.DataCase,
        IdDidiShWeb.ConnCase
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {IdDidiSh.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.8"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:jose, "~> 1.11"},
      # Encryption at rest for lent credentials. Hand-rolling this is the one
      # place thrift is indefensible; Cloak gives a transparent Ecto type and a
      # documented key-rotation path.
      {:cloak_ecto, "~> 1.3"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind id_didi_sh", "esbuild id_didi_sh"],
      "assets.deploy": [
        "tailwind id_didi_sh --minify",
        "esbuild id_didi_sh --minify",
        "phx.digest"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "test --cover"
      ]
    ]
  end
end
