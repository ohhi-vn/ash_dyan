defmodule AshDynal.MixProject do
  use Mix.Project

  def project do
    [
      app: :ash_dynal,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
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
      {:ash_postgres, "~> 2.0", optional: true},
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
      {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false}
    ]
  end
end
