defmodule Qot.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "users" do
    field(:email, :string)
    # The Apple account's `sub`, once the user has signed in with Apple.
    field(:apple_sub, :string)
    # Apple's refresh token and the client id it was issued to, kept only to
    # revoke Sign in with Apple when the account is deleted (#88).
    field(:apple_refresh_token, :string, redact: true)
    field(:apple_client_id, :string)

    timestamps(type: :utc_datetime)
  end

  @doc "A new user from Sign in with Apple, or an existing one linked to it."
  def apple_changeset(user, attrs) do
    user
    |> changeset(attrs)
    |> cast(attrs, [:apple_sub])
    |> validate_required([:apple_sub])
    |> unique_constraint(:apple_sub)
  end

  @doc "Keeps Apple's refresh token from a sign-in, for revoking it later."
  def apple_token_changeset(user, attrs) do
    user
    |> cast(attrs, [:apple_refresh_token, :apple_client_id])
    |> validate_required([:apple_refresh_token, :apple_client_id])
  end

  @doc false
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email])
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must have the @ sign and no spaces")
    |> validate_length(:email, max: 160)
    |> unique_constraint(:email)
  end
end
