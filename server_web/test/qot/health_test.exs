defmodule Qot.HealthTest do
  use Qot.DataCase, async: true

  alias Qot.Health

  defmodule DownRepo do
    def query(_sql), do: {:error, %DBConnection.ConnectionError{message: "connection refused"}}
  end

  test "ok when the database answers" do
    assert Health.check(Qot.Repo) == :ok
  end

  test "an error, not a crash, when the database doesn't" do
    assert {:error, "connection refused"} = Health.check(DownRepo)
  end
end
