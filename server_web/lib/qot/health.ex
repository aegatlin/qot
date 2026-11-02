defmodule Qot.Health do
  @moduledoc "Whether this node can serve requests: today, whether the database answers."

  @spec check(module()) :: :ok | {:error, String.t()}
  def check(repo \\ Qot.Repo) do
    case repo.query("SELECT 1") do
      {:ok, _} -> :ok
      {:error, error} -> {:error, Exception.message(error)}
    end
  end
end
