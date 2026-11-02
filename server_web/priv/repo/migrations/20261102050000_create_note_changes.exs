defmodule Qot.Repo.Migrations.CreateNoteChanges do
  use Ecto.Migration

  def change do
    # Per-user counter: a push increments it under the user row's lock, so a
    # user's seqs are assigned one push at a time and never leave gaps a
    # concurrent reader could skip past.
    alter table(:users) do
      add :change_seq, :bigint, null: false, default: 0
    end

    # Opaque Automerge change blobs (end-to-end encryptable): the server
    # stores and relays them, and never parses them.
    create table(:note_changes) do
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :seq, :bigint, null: false
      add :note_id, :uuid, null: false
      add :data, :binary, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:note_changes, [:user_id, :seq])
  end
end
