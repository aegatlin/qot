defmodule Qot.Repo.Migrations.CreateBlobs do
  use Ecto.Migration

  def change do
    # Attachments' bytes (a recording; later images): opaque to the server,
    # like note changes. The id is the attachment's, made by a client, so it
    # is unique per user only.
    create table(:blobs, primary_key: false) do
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all),
        primary_key: true,
        null: false

      add :id, :uuid, primary_key: true, null: false
      # Null for an id deleted before it was ever uploaded.
      add :note_id, :uuid
      add :byte_size, :bigint, null: false, default: 0
      # Null once deleted: the row stays, so a late upload is refused.
      add :data, :binary
      add :deleted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
  end
end
