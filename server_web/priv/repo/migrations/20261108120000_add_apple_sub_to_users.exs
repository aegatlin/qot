defmodule Qot.Repo.Migrations.AddAppleSubToUsers do
  use Ecto.Migration

  # Sign in with Apple (docs/records/2026-11-08-sign-in-with-apple.md): the
  # Apple account's stable `sub`, once a user has signed in with Apple.
  def change do
    alter table(:users) do
      add :apple_sub, :string
    end

    create unique_index(:users, [:apple_sub])
  end
end
