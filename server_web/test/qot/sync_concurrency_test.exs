defmodule Qot.SyncConcurrencyTest do
  # Not async: concurrent pushes share the sandbox connection owner.
  use Qot.DataCase, async: false

  alias Qot.Sync
  alias QotWeb.AuthHelpers

  test "concurrent pushes still produce one gap-free sequence" do
    %{user_id: user_id} = AuthHelpers.create_authenticated_user()

    1..20
    |> Task.async_stream(
      fn i -> Sync.push(user_id, [%{note_id: Ecto.UUID.generate(), data: "#{i}"}]) end,
      max_concurrency: 10
    )
    |> Enum.each(fn {:ok, result} -> assert {:ok, _} = result end)

    {:ok, %{changes: changes, cursor: 20}} = Sync.pull(user_id, 0, 100)
    assert Enum.map(changes, & &1.seq) == Enum.to_list(1..20)
  end
end
