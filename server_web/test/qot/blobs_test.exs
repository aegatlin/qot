defmodule Qot.BlobsTest do
  # The test config's limits: 1000 bytes a blob, 2500 an account.
  use Qot.DataCase, async: true

  alias Qot.{Blobs, Sync}
  alias QotWeb.AuthHelpers

  @note "0199a7e2-5c3b-7c4e-9a1d-2f6b8e4d3c21"
  @blob "0199a7e2-5c3b-7c4e-9a1d-2f6b8e4d3c31"
  @other_blob "0199a7e2-5c3b-7c4e-9a1d-2f6b8e4d3c32"

  setup do
    %{user_id: user_id} = AuthHelpers.create_authenticated_user()
    %{user_id: user_id}
  end

  test "stores bytes exactly as given", %{user_id: user_id} do
    opaque = :crypto.strong_rand_bytes(512)
    assert :ok = Blobs.put(user_id, @blob, @note, opaque)
    assert {:ok, ^opaque} = Blobs.get(user_id, @blob)
  end

  test "a blob that isn't there is not found", %{user_id: user_id} do
    assert {:error, :not_found} = Blobs.get(user_id, @blob)
  end

  test "uploading the same id again changes nothing", %{user_id: user_id} do
    assert :ok = Blobs.put(user_id, @blob, @note, "first")
    assert :ok = Blobs.put(user_id, @blob, @note, "second")
    assert {:ok, "first"} = Blobs.get(user_id, @blob)
    assert Blobs.used_bytes(user_id) == 5
  end

  test "users never see each other's blobs, even under the same id", %{user_id: user_id} do
    %{user_id: other} = AuthHelpers.create_authenticated_user("other@example.com")
    assert :ok = Blobs.put(user_id, @blob, @note, "mine")
    assert {:error, :not_found} = Blobs.get(other, @blob)
    assert :ok = Blobs.put(other, @blob, @note, "theirs")
    assert {:ok, "mine"} = Blobs.get(user_id, @blob)
    assert {:ok, "theirs"} = Blobs.get(other, @blob)
  end

  test "an empty blob, or one over the size limit, is refused", %{user_id: user_id} do
    assert {:error, :empty} = Blobs.put(user_id, @blob, @note, "")
    assert :ok = Blobs.put(user_id, @blob, @note, String.duplicate("x", 1000))

    assert {:error, :too_large} =
             Blobs.put(user_id, @other_blob, @note, String.duplicate("x", 1001))
  end

  test "an account's blobs can't pass its quota", %{user_id: user_id} do
    for n <- 1..2 do
      id = "0199a7e2-5c3b-7c4e-9a1d-2f6b8e4d3c4#{n}"
      assert :ok = Blobs.put(user_id, id, @note, String.duplicate("x", 1000))
    end

    assert {:error, :quota_exceeded} =
             Blobs.put(user_id, @blob, @note, String.duplicate("x", 501))

    assert :ok = Blobs.put(user_id, @blob, @note, String.duplicate("x", 500))
    assert Blobs.used_bytes(user_id) == 2500

    # Another account has its own quota.
    %{user_id: other} = AuthHelpers.create_authenticated_user("other@example.com")
    assert :ok = Blobs.put(other, @blob, @note, String.duplicate("x", 1000))
  end

  test "an unknown user can't store a blob" do
    assert {:error, :unknown_user} = Blobs.put(Ecto.UUID.generate(), @blob, @note, "x")
  end

  describe "deleted with a push" do
    test "the bytes go, and the space comes back", %{user_id: user_id} do
      :ok = Blobs.put(user_id, @blob, @note, "recording")
      :ok = Blobs.put(user_id, @other_blob, @note, "kept")

      assert {:ok, 1} = Sync.push(user_id, [%{note_id: @note, data: "tombstone"}], [@blob])

      assert {:error, :not_found} = Blobs.get(user_id, @blob)
      assert {:ok, "kept"} = Blobs.get(user_id, @other_blob)
      assert Blobs.used_bytes(user_id) == 4
    end

    test "a deleted id is refused if it is uploaded later", %{user_id: user_id} do
      :ok = Blobs.put(user_id, @blob, @note, "recording")
      {:ok, _} = Sync.push(user_id, [%{note_id: @note, data: "x"}], [@blob])
      assert {:error, :deleted} = Blobs.put(user_id, @blob, @note, "recording")
      assert {:error, :not_found} = Blobs.get(user_id, @blob)
    end

    test "an id deleted before it was ever uploaded is refused too", %{user_id: user_id} do
      # The recording phone was offline while another device deleted the note.
      {:ok, _} = Sync.push(user_id, [%{note_id: @note, data: "x"}], [@blob])
      assert {:error, :deleted} = Blobs.put(user_id, @blob, @note, "late")
    end

    test "deleting twice is harmless", %{user_id: user_id} do
      :ok = Blobs.put(user_id, @blob, @note, "recording")
      {:ok, 1} = Sync.push(user_id, [%{note_id: @note, data: "x"}], [@blob])
      assert {:ok, 2} = Sync.push(user_id, [%{note_id: @note, data: "y"}], [@blob, @blob])
    end

    test "one user's push can't delete another's blob", %{user_id: user_id} do
      %{user_id: other} = AuthHelpers.create_authenticated_user("other@example.com")
      :ok = Blobs.put(other, @blob, @note, "theirs")
      {:ok, _} = Sync.push(user_id, [%{note_id: @note, data: "x"}], [@blob])
      assert {:ok, "theirs"} = Blobs.get(other, @blob)
    end

    test "a push that fails deletes nothing" do
      %{user_id: user_id} = AuthHelpers.create_authenticated_user("gone@example.com")
      :ok = Blobs.put(user_id, @blob, @note, "recording")
      stranger = Ecto.UUID.generate()

      assert {:error, :unknown_user} =
               Sync.push(stranger, [%{note_id: @note, data: "x"}], [@blob])

      assert {:ok, "recording"} = Blobs.get(user_id, @blob)
    end
  end

  test "deleting the account deletes its blobs", %{user_id: user_id} do
    %{user_id: other} = AuthHelpers.create_authenticated_user("other@example.com")
    :ok = Blobs.put(user_id, @blob, @note, "mine")
    :ok = Blobs.put(other, @blob, @note, "theirs")
    {:ok, _} = Sync.push(user_id, [%{note_id: @note, data: "x"}], [@other_blob])

    assert :ok = Qot.Accounts.delete_user(user_id)

    assert Repo.aggregate(
             from(b in "blobs", where: b.user_id == type(^user_id, :binary_id)),
             :count
           ) == 0

    assert {:ok, "theirs"} = Blobs.get(other, @blob)
  end
end
