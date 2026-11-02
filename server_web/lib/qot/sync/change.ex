defmodule Qot.Sync.Change do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "note_changes" do
    field(:user_id, :binary_id)
    field(:seq, :integer)
    field(:note_id, Ecto.UUID)
    field(:data, :binary)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
