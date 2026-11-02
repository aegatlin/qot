defmodule Qot.Sync do
  @moduledoc """
  Note sync as a per-user, append-only log of opaque change blobs.

  Clients push the Automerge changes they made and pull everything after the
  last `cursor` they saw; they do all merging themselves. The server never
  reads a change, which keeps end-to-end encryption a client-only addition.

  Seqs are per user and gap-free: a push takes the user row's lock to reserve
  its range, so a reader holding cursor N can never miss a change committed
  later with a seq below N.
  """

  import Ecto.Query

  alias Qot.Repo
  alias Qot.Sync.{Batch, Change}

  @pubsub Qot.PubSub

  def topic(user_id), do: "notes:user:#{user_id}"

  @spec push(Ecto.UUID.t(), [Batch.entry(), ...]) ::
          {:ok, pos_integer()} | {:error, :unknown_user}
  def push(user_id, [_ | _] = entries) do
    now = DateTime.utc_now()

    result =
      Repo.transaction(fn ->
        case reserve(user_id, length(entries)) do
          {:ok, last_seq} ->
            rows =
              entries
              |> Batch.number(last_seq)
              |> Enum.map(&Map.merge(&1, %{user_id: user_id, inserted_at: now}))

            Repo.insert_all(Change, rows)
            last_seq

          :error ->
            Repo.rollback(:unknown_user)
        end
      end)

    with {:ok, cursor} <- result do
      Phoenix.PubSub.broadcast(@pubsub, topic(user_id), {:changes, cursor})
      {:ok, cursor}
    end
  end

  defp reserve(user_id, count) do
    query =
      from(u in "users",
        where: u.id == type(^user_id, :binary_id),
        update: [inc: [change_seq: ^count]],
        select: u.change_seq
      )

    case Repo.update_all(query, []) do
      {1, [last_seq]} -> {:ok, last_seq}
      {0, _} -> :error
    end
  end

  @spec pull(Ecto.UUID.t(), non_neg_integer(), pos_integer()) ::
          {:ok, %{changes: [map()], cursor: non_neg_integer(), more: boolean()}}
  def pull(user_id, since, limit) do
    rows =
      Repo.all(
        from(c in Change,
          where: c.user_id == ^user_id and c.seq > ^since,
          order_by: c.seq,
          limit: ^(limit + 1),
          select: %{seq: c.seq, note_id: c.note_id, data: c.data}
        )
      )

    {changes, rest} = Enum.split(rows, limit)
    cursor = if changes == [], do: since, else: List.last(changes).seq
    {:ok, %{changes: changes, cursor: cursor, more: rest != []}}
  end
end
