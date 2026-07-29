defmodule LS.MixProject do
  use Mix.Project

  def project do
    [
      app: :ls,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      listeners: [Phoenix.CodeReloader],
      # `mix docs` → doc/index.html (ExDoc)
      name: "ListSignal",
      docs: &docs/0
    ]
  end

  # Documentation site layout. Modules are grouped by subsystem so the
  # distributed pipeline reads as a system, not an alphabetical list.
  defp docs do
    [
      main: "architecture",
      extras: [
        "docs/architecture.md",
        "docs/pipelines.md": [title: "The two pipelines"],
        "docs/recovery-h1-resolver-2026-07.md": [title: "Case study: h1 resolver incident"]
      ],
      groups_for_modules: [
        "Cluster (master↔workers)": [LS.Cluster.WorkQueue, LS.Cluster.WorkerAgent,
                                     LS.Cluster.Inserter, LS.Cluster.Monitor, LS.Cluster.Optimizer],
        "Discovery (CT logs)": ~r/^LS\.CTL/,
        "Enrichment stages": [LS.Pipeline, LS.DNS.Resolver, LS.DNS.Scorer, LS.DNS.SPF,
                              LS.BGP.Resolver, LS.RDAP.Client, LS.CountryInferrer],
        "HTTP crawling": ~r/^LS\.HTTP/,
        "Classification & ML": [LS.ML.Classifier, LS.Revenue.Estimator],
        "Reputation": ~r/^LS\.Reputation/,
        Recrawl: ~r/^LS\.Recrawl/,
        "Storage & queries": [LS.Clickhouse, LS.Cache, LS.Repo, LS.Explorer, LS.LandingCache],
        "Accounts & billing": [LS.Accounts, LS.Accounts.User, LS.Accounts.UserToken,
                               LS.Accounts.UserNotifier, LS.StripeClient, LS.StripeClientBehaviour, LS.Mailer],
        Web: ~r/^LSWeb/
      ],
      source_url: "https://github.com/giushansen/list_signal",
      formatters: ["html"]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger, :runtime_tools, :crypto, :public_key],
      mod: {LS.Application, []}
    ]
  end

  defp deps do
    [
      {:bcrypt_elixir, "~> 3.0"},
      {:phoenix, "~> 1.7"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:phoenix_live_dashboard, "~> 0.8"},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 0.26"},
      # Database
      {:ecto_sql, "~> 3.10"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:phoenix_ecto, "~> 4.6"},
      # Email
      {:swoosh, "~> 1.5"},
      {:finch, "~> 0.13"},
      # Billing
      {:stripity_stripe, "~> 3.0"},
      # Pipeline
      {:req, "~> 0.5"},
      {:paasaa, "~> 1.0"},
      {:x509, "~> 0.9"},
      # ML — sentence embeddings for Tier 2 classification
      {:bumblebee, "~> 0.6"},
      {:nx, "~> 0.9"},
      {:exla, "~> 0.9"},
      # Docs — `mix docs` generates the HTML documentation site
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      # Test
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind ls", "esbuild ls"],
      "assets.deploy": ["tailwind ls --minify", "esbuild ls --minify", "phx.digest"],
      precommit: ["compile --warnings-as-errors", "test"]
    ]
  end
end
