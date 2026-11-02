defmodule Qot.MixProject do
  use Mix.Project

  def project do
    [
      app: :qot,
      version: "0.1.0",
      elixir: "~> 1.14",
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
      {:bandit, "~> 1.0"},
      {:cors_plug, "~> 3.0"},
      {:ecto_sql, "~> 3.10"},
      {:gen_smtp, "~> 1.2"},
      {:hackney, "~> 1.18"},
      {:jason, "~> 1.2"},
      {:joken, "~> 2.6"},
      {:phoenix, "~> 1.7.0"},
      {:postgrex, "~> 0.17"},
      {:resend, "~> 0.4.0"},
      {:swoosh, "~> 1.14"}
    ]
  end
end
