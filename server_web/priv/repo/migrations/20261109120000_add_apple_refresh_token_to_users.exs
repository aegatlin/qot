defmodule Qot.Repo.Migrations.AddAppleRefreshTokenToUsers do
  use Ecto.Migration

  # #88: Apple's refresh token from a sign-in's authorization code, and the
  # client id it was issued to, so deleting the account can revoke it.
  def change do
    alter table(:users) do
      add :apple_refresh_token, :text
      add :apple_client_id, :string
    end
  end
end
