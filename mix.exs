defmodule AshDyan.MixProject do
  use Mix.Project

  def project do
    [
      app: :ash_dyan,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ash, "~> 3.29"},
      {:ash_postgres, "~> 2.0", only: [:dev, :test]},
      {:jason, "~> 1.4"},
      {:usage_rules, "~> 1.2", only: [:dev]},
      # Benchmarking
      {:benchee, "~> 1.5", only: [:dev, :test]},
      # optional HTML report
      {:benchee_html, "~> 1.0", only: [:dev, :test]},

      # Test dependencies
      {:excoveralls, "~> 0.18", only: :test},

      # Code quality
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false},

      # Docs
      {:ex_doc, "~> 0.34", only: :docs, runtime: false}
    ]
  end

  # Run "mix docs" (with MIX_ENV=docs) to build the documentation.
  def docs do
    [
      main: "README.md",
      logo: nil,
      extras: [
        "guides/usage.md",
        "guides/design.md"
      ],
      extras_path: "guides",
      groups_for_extras: [
        "Guides": ~r/guides\/.*/
      ],
      source_url: nil,
      homepage_url: nil
    ]
  end

  defp aliases do
    [
      docs: ["docs"]
    ]
  end
end
