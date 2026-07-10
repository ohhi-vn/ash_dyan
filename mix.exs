defmodule AshDyan.MixProject do
  use Mix.Project

  def project do
    [
      app: :ash_dyan,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      test_paths: ["test"],
      test_load_filters: [&String.ends_with?(&1, "_test.exs")],
      test_ignore_filters: [&String.starts_with?(&1, "test/support/")],
      dialyzer: [
        plt_add_apps: [:ex_unit, :mix],
        flags: [:unmatched_returns, :error_handling, :underspecs]
      ],
      name: "AshDyan",
      source_url: "https://github.com/ohhi-vn/ash_dyan",
      homepage_url: "https://ohhi.vn",
      docs: docs(),
      package: package(),
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: [
        tool: Mix.Tasks.Test.Coverage,
        output: "cover",
        summary: [threshold: 85]
      ],
      consolidate_protocols: Mix.env() != :test,
      test_elixirc_options: [debug_info: true]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp package do
    [
      description: "Declarative, DSL-driven analytics for Ash resources (frequency, aggregate, time_bucket, percentile, histogram).",
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => "https://github.com/ohhi-vn/ash_dyan",
        "Documentation" => "https://hexdocs.pm/ash_dyan",
        "Ash Framework" => "https://ash-hq.org/"
      },
      files: ~w(lib .formatter.exs mix.exs README* LICENSE* CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "AshDyan",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "guides/usage.md",
        "guides/design.md"
      ],
      groups_for_extras: [
        Guides: [
          "guides/usage.md",
          "guides/design.md"
        ]
      ],
      groups_for_modules: [
        Core: [
          AshDyan,
          AshDyan.Request,
          AshDyan.Result,
          AshDyan.Info
        ],
        "DSL & Introspection": [
          AshDyan.Domain,
          AshDyan.Domain.Info
        ],
        Engine: [
          AshDyan.Engine,
          AshDyan.Engine.Formatter
        ],
        Charts: [
          AshDyan.Charts
        ],
        Adapters: [
          AshDyan.Adapters.PhoenixController
        ],
        "Error Handling": [
          AshDyan.Error
        ]
      ],
      source_url: "https://github.com/ohhi-vn/ash_dyan",
      homepage_url: "https://ohhi.vn"
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ash, "~> 3.29"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.14", optional: true},
      {:decimal, "~> 3.1", optional: true},
      {:ash_postgres, "~> 2.0", only: [:dev, :test]},

      # Dev / docs
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},

      # Benchmarking
      {:benchee, "~> 1.5", only: [:dev, :test]},
      {:benchee_html, "~> 1.0", only: [:dev, :test]},

      # Test dependencies
      {:excoveralls, "~> 0.18", only: :test},

      # Code quality
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
       {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      "test.ci": ["credo --strict", "test"],
      test: ["test"],
      "test.unit": ["test --exclude postgres"],
      "test.integration": ["test --only postgres"],
      # Testing & Coverage
      coveralls: ["test --cover", "coveralls.html"],
      # Code Quality
      quality: ["format --check-formatted", "credo --strict", "dialyzer"]
    ]
  end
end
