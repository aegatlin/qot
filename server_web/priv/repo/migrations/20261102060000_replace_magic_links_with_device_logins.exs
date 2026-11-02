defmodule Qot.Repo.Migrations.ReplaceMagicLinksWithDeviceLogins do
  use Ecto.Migration

  def change do
    drop table(:magic_link_tokens)

    # A device (CLI, later iOS or the PWA) asks to sign in; the emailed link
    # opens a page where the person types the code shown on that device.
    # Tokens are stored hashed; the user code is short-lived and shown only on
    # the device.
    create table(:device_logins) do
      add :email, :string, null: false
      add :device_code, :string, null: false
      add :link_token, :string, null: false
      add :user_code, :string, null: false
      add :attempts, :integer, null: false, default: 0
      add :approved_at, :utc_datetime
      add :consumed_at, :utc_datetime
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:device_logins, [:device_code])
    create unique_index(:device_logins, [:link_token])
    create index(:device_logins, [:expires_at])
  end
end
