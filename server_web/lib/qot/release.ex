defmodule Qot.Release do
  @moduledoc """
  Tasks run from a release, where Mix isn't available:

      bin/qot eval "Qot.Release.migrate()"

  `rel/overlays/bin/migrate` wraps that, for a platform's pre-deploy step.
  """
  @app :qot

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  # SSL is needed to reach a database over TLS before the app starts.
  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
