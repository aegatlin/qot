defmodule Qot.Repo.Migrations.AddPlanAndTranscriptionUsage do
  use Ecto.Migration

  def change do
    # What the account pays for: "free", or "plus" (cloud transcription).
    alter table(:users) do
      add :plan, :string, null: false, default: "free"
    end

    # Seconds of audio sent for transcription, per account and calendar
    # month (UTC), for the monthly allowance. Nothing about the audio or
    # its text is kept.
    create table(:transcription_usage, primary_key: false) do
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all),
        primary_key: true,
        null: false

      add :month, :date, primary_key: true, null: false
      add :seconds, :bigint, null: false, default: 0
    end
  end
end
