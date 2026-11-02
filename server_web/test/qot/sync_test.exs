defmodule Qot.SyncTest do
  use Qot.DataCase, async: true

  alias Qot.Sync
  alias QotWeb.AuthHelpers

  @a "0199a7e2-5c3b-7c4e-9a1d-2f6b8e4d3c21"
  @b "0199a7e2-5c3b-7c4e-9a1d-2f6b8e4d3c22"

  setup do
    %{user_id: user_id} = AuthHelpers.create_authenticated_user()
    %{user_id: user_id}
  end

  test "a new user has nothing to pull", %{user_id: user_id} do
    assert {:ok, %{changes: [], cursor: 0, more: false}} = Sync.pull(user_id, 0, 100)
  end

  test "pushed changes come back in order with gap-free seqs", %{user_id: user_id} do
    assert {:ok, 2} = Sync.push(user_id, [%{note_id: @a, data: "a1"}, %{note_id: @b, data: "b1"}])
    assert {:ok, 3} = Sync.push(user_id, [%{note_id: @a, data: "a2"}])

    assert {:ok, %{changes: changes, cursor: 3, more: false}} = Sync.pull(user_id, 0, 100)

    assert [
             %{seq: 1, note_id: @a, data: "a1"},
             %{seq: 2, note_id: @b, data: "b1"},
             %{seq: 3, note_id: @a, data: "a2"}
           ] = changes
  end

  test "pull pages from a cursor", %{user_id: user_id} do
    {:ok, 3} =
      Sync.push(user_id, for(d <- ~w(1 2 3), do: %{note_id: @a, data: d}))

    assert {:ok, %{changes: [%{seq: 1}, %{seq: 2}], cursor: 2, more: true}} =
             Sync.pull(user_id, 0, 2)

    assert {:ok, %{changes: [%{seq: 3}], cursor: 3, more: false}} = Sync.pull(user_id, 2, 2)
    assert {:ok, %{changes: [], cursor: 3, more: false}} = Sync.pull(user_id, 3, 2)
  end

  test "users never see each other's changes", %{user_id: user_id} do
    %{user_id: other} = AuthHelpers.create_authenticated_user("other@example.com")

    {:ok, 1} = Sync.push(user_id, [%{note_id: @a, data: "mine"}])
    {:ok, 1} = Sync.push(other, [%{note_id: @a, data: "theirs"}])

    assert {:ok, %{changes: [%{data: "mine"}]}} = Sync.pull(user_id, 0, 100)
    assert {:ok, %{changes: [%{data: "theirs"}]}} = Sync.pull(other, 0, 100)
  end

  test "the server stores bytes exactly as given", %{user_id: user_id} do
    opaque = :crypto.strong_rand_bytes(256)
    {:ok, _} = Sync.push(user_id, [%{note_id: @a, data: opaque}])
    assert {:ok, %{changes: [%{data: ^opaque}]}} = Sync.pull(user_id, 0, 100)
  end

  test "a push notifies the user's topic with the new cursor", %{user_id: user_id} do
    Phoenix.PubSub.subscribe(Qot.PubSub, Sync.topic(user_id))
    {:ok, 1} = Sync.push(user_id, [%{note_id: @a, data: "x"}])
    assert_receive {:changes, 1}
  end

  test "pushing for an unknown user is an error" do
    assert {:error, :unknown_user} =
             Sync.push(Ecto.UUID.generate(), [%{note_id: @a, data: "x"}])
  end
end
