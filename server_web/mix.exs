defmodule Qot.MixProject do
  use Mix.Project

  def project do
    [
      app: :qot,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Qot.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.14"},
      {:cors_plug, "~> 3.0"},
      {:ecto_sql, "~> 3.14"},
      {:jason, "~> 1.4"},
      {:joken, "~> 2.7"},
      {:phoenix, "~> 1.8"},
      {:postgrex, "~> 0.22"},
      {:req, "~> 0.5"},
      {:swoosh, "~> 1.29"}
    ]
  end
end
