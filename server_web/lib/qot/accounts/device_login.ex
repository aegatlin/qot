defmodule Qot.Accounts.DeviceLogin do
  @moduledoc """
  A device sign-in in progress, and the pure rules about it.

  The device shows a user code; the emailed link opens a page where the
  person types it. Requiring the code (not just a click) means someone who
  starts a login with your address cannot be signed in by you clicking a link
  you didn't expect, and a mail scanner that prefetches links approves
  nothing.
  """

  use Ecto.Schema

  # No vowels, so a code never spells a word, and nothing to misread as 0 or 1.
  @alphabet ~c"BCDFGHJKLMNPQRSTVWXZ"
  @max_attempts 5

  schema "device_logins" do
    field(:email, :string)
    field(:device_code, :string)
    field(:link_token, :string)
    field(:user_code, :string)
    field(:attempts, :integer, default: 0)
    field(:approved_at, :utc_datetime)
    field(:consumed_at, :utc_datetime)
    field(:expires_at, :utc_datetime)

    timestamps(type: :utc_datetime)
  end

  def max_attempts, do: @max_attempts

  @doc "An `XXXX-XXXX` code from 8 random bytes."
  def user_code_from_bytes(<<_::binary-size(8)>> = bytes) do
    letters =
      for <<byte <- bytes>>, into: "", do: <<Enum.at(@alphabet, rem(byte, length(@alphabet)))>>

    String.slice(letters, 0, 4) <> "-" <> String.slice(letters, 4, 4)
  end

  @doc "Normalises a typed code: case, spaces and the dash don't matter."
  def normalize_user_code(input) when is_binary(input) do
    case input |> String.upcase() |> String.replace(~r/[^A-Z]/, "") do
      <<a::binary-size(4), b::binary-size(4)>> -> a <> "-" <> b
      other -> other
    end
  end

  @type status :: :pending | :approved | :consumed | :expired | :denied

  @spec status(%__MODULE__{}, DateTime.t()) :: status()
  def status(%__MODULE__{} = login, now) do
    cond do
      login.consumed_at -> :consumed
      DateTime.compare(now, login.expires_at) != :lt -> :expired
      login.attempts >= @max_attempts -> :denied
      login.approved_at -> :approved
      true -> :pending
    end
  end

  @doc "Whether `input` approves this login now."
  @spec check_code(%__MODULE__{}, String.t(), DateTime.t()) ::
          :ok | {:error, :mismatch | status()}
  def check_code(%__MODULE__{} = login, input, now) do
    case status(login, now) do
      :pending ->
        if Plug.Crypto.secure_compare(normalize_user_code(input), login.user_code),
          do: :ok,
          else: {:error, :mismatch}

      other ->
        {:error, other}
    end
  end
end
