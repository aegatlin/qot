defmodule Qot.Blobs do
  @moduledoc """
  Attachments' bytes: a recording, later an image or a video.

  A blob is opaque. The server stores no media type and never inspects the
  bytes: what a blob is lives in the note, which the server doesn't read, so
  blobs can be encrypted end to end like note changes. Its id is the
  attachment's, made by the client, and is unique per user only.

  Blobs live in Postgres for now; clients reach them only through
  `/api/blobs`, so moving the bytes to a bucket is a change behind this
  module (docs/records/2026-11-19-attachments-and-voice-memos.md).

  Deleting is `mark_deleted/3`, called by `Qot.Sync.push/3` inside the push
  that drops the attachment. The row stays without its bytes, so an upload
  that arrives late, from a device that was offline when another deleted the
  note, is refused instead of storing bytes nothing points to.
  """

  import Ecto.Query

  alias Qot.Repo

  @type put_error :: :empty | :too_large | :quota_exceeded | :deleted | :unknown_user

  @doc "The largest a blob may be, in bytes."
  def max_bytes, do: limits().max_bytes

  @doc "How many bytes of blobs an account may hold."
  def quota_bytes, do: limits().quota_bytes

  defp limits, do: Application.fetch_env!(:qot, :blob_limits)

  @doc """
  Stores a blob. Idempotent: an id already stored is left as it is, whatever
  the bytes, so an upload can simply be retried.
  """
  @spec put(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), binary()) :: :ok | {:error, put_error()}
  def put(_user_id, _id, _note_id, ""), do: {:error, :empty}

  def put(user_id, id, note_id, bytes) when is_binary(bytes) do
    size = byte_size(bytes)

    if size > max_bytes() do
      {:error, :too_large}
    else
      {:ok, result} = Repo.transaction(fn -> store(user_id, id, note_id, bytes, size) end)
      result
    end
  end

  defp store(user_id, id, note_id, bytes, size) do
    # The user row's lock makes the quota check and the insert one step for
    # that account.
    locked =
      from(u in "users", where: u.id == type(^user_id, :binary_id), lock: "FOR UPDATE", select: 1)

    with 1 <- Repo.one(locked),
         nil <- Repo.one(existing(user_id, id)) do
      if used_bytes(user_id) + size > quota_bytes() do
        {:error, :quota_exceeded}
      else
        Repo.insert_all("blobs", [
          %{
            user_id: Ecto.UUID.dump!(user_id),
            id: Ecto.UUID.dump!(id),
            note_id: Ecto.UUID.dump!(note_id),
            byte_size: size,
            data: bytes,
            inserted_at: DateTime.utc_now()
          }
        ])

        :ok
      end
    else
      nil -> {:error, :unknown_user}
      %{deleted: true} -> {:error, :deleted}
      %{deleted: false} -> :ok
    end
  end

  defp existing(user_id, id) do
    from(b in "blobs",
      where: b.user_id == type(^user_id, :binary_id) and b.id == type(^id, :binary_id),
      select: %{deleted: not is_nil(b.deleted_at)}
    )
  end

  @spec get(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, binary()} | {:error, :not_found}
  def get(user_id, id) do
    query =
      from(b in "blobs",
        where:
          b.user_id == type(^user_id, :binary_id) and b.id == type(^id, :binary_id) and
            is_nil(b.deleted_at),
        select: b.data
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      bytes -> {:ok, bytes}
    end
  end

  @doc "The bytes of blobs an account holds, against its quota."
  @spec used_bytes(Ecto.UUID.t()) :: non_neg_integer()
  def used_bytes(user_id) do
    query =
      from(b in "blobs",
        where: b.user_id == type(^user_id, :binary_id) and is_nil(b.deleted_at),
        select: coalesce(sum(b.byte_size), 0)
      )

    query |> Repo.one() |> Decimal.to_integer()
  end

  @doc """
  Deletes blobs: their bytes go and their ids stay, refused from then on.
  An id never uploaded is recorded too. Deleting again changes nothing. Run
  inside the caller's transaction (`Qot.Sync.push/3`).
  """
  @spec mark_deleted(Ecto.UUID.t(), [Ecto.UUID.t()], DateTime.t()) :: :ok
  def mark_deleted(_user_id, [], _now), do: :ok

  def mark_deleted(user_id, ids, now) do
    rows =
      for id <- Enum.uniq(ids) do
        %{
          user_id: Ecto.UUID.dump!(user_id),
          id: Ecto.UUID.dump!(id),
          byte_size: 0,
          deleted_at: now,
          inserted_at: now
        }
      end

    Repo.insert_all("blobs", rows,
      on_conflict:
        from(b in "blobs",
          update: [
            set: [
              data: nil,
              byte_size: 0,
              deleted_at: fragment("COALESCE(?, EXCLUDED.deleted_at)", b.deleted_at)
            ]
          ]
        ),
      conflict_target: [:user_id, :id]
    )

    :ok
  end
end
