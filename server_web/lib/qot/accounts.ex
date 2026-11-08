defmodule Qot.Accounts do
  @moduledoc """
  The Accounts context - handles user authentication and token management.
  """

  import Ecto.Query, warn: false
  alias Qot.Repo
  alias Qot.Accounts.{DeviceLogin, Mailer, SignInLimit, SignInLimiter, Token, User}

  ## User functions

  @doc """
  Gets a user by ID.
  Returns {:ok, user} or {:error, :not_found}
  """
  def get_user(id) do
    case Repo.get(User, id) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @doc """
  Whether a user with this id still exists. Access tokens outlive a deleted
  account by up to an hour, so authentication checks this too.
  """
  @spec user_exists?(String.t()) :: boolean()
  def user_exists?(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.exists?(from(u in User, where: u.id == ^uuid))
      :error -> false
    end
  end

  @doc """
  Gets a user by email.
  Returns {:ok, user} or {:error, :not_found}
  """
  def get_user_by_email(email) do
    case Repo.get_by(User, email: email) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @doc """
  Creates a new user with the given email.
  Returns {:ok, user} or {:error, changeset}
  """
  def create_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets or creates a user by email.
  Returns {:ok, user}
  """
  def get_or_create_user(email) do
    case get_user_by_email(email) do
      {:ok, user} -> {:ok, user}
      {:error, :not_found} -> create_user(%{email: email})
    end
  end

  @doc """
  Deletes a user and everything the server keeps about them: their refresh
  tokens and change log (by cascade) and their sign-ins (by email). Notes on
  their devices are untouched.
  """
  @spec delete_user(Ecto.UUID.t()) :: :ok | {:error, :not_found}
  def delete_user(user_id) do
    {:ok, result} =
      Repo.transaction(fn ->
        case Repo.one(from(u in User, where: u.id == ^user_id, lock: "FOR UPDATE")) do
          nil ->
            {:error, :not_found}

          user ->
            Repo.delete_all(from(d in DeviceLogin, where: d.email == ^user.email))
            Repo.delete!(user)
            :ok
        end
      end)

    result
  end

  ## Device login

  @device_login_ttl 15 * 60
  @poll_interval 3

  @doc """
  Starts a device sign-in: emails a link to `email` and returns the codes
  the device needs. The user code is shown on the device only.

  Limited per address and per `client_ip` (when given), since each one sends
  an email: `{:error, {:rate_limited, seconds}}` says how long to wait.
  """
  def start_device_login(email, client_ip \\ nil) when is_binary(email) do
    email = String.trim(email)

    device_code = Token.generate_refresh_token()
    link_token = Token.generate_refresh_token()
    user_code = DeviceLogin.user_code_from_bytes(:crypto.strong_rand_bytes(8))

    login = %DeviceLogin{
      email: email,
      device_code: Token.hash_token(device_code),
      link_token: Token.hash_token(link_token),
      user_code: user_code,
      expires_at:
        DateTime.utc_now() |> DateTime.add(@device_login_ttl) |> DateTime.truncate(:second)
    }

    with :ok <- validate_email(email),
         :ok <- SignInLimiter.hit(limit_keys(email, client_ip)),
         {:ok, _} <- Repo.insert(login),
         {:ok, _} <- Mailer.send_device_login(email, link_token) do
      {:ok,
       %{
         device_code: device_code,
         user_code: user_code,
         expires_in: @device_login_ttl,
         interval: @poll_interval
       }}
    end
  end

  defp validate_email(email) do
    if User.changeset(%User{}, %{email: email}).valid?, do: :ok, else: {:error, :invalid_email}
  end

  defp limit_keys(email, nil), do: [email: SignInLimit.email_key(email)]

  defp limit_keys(email, client_ip),
    do: [email: SignInLimit.email_key(email), ip: SignInLimit.ip_key(client_ip)]

  @doc "The login an emailed link refers to, if it can still be approved."
  def get_device_login_by_link(link_token) do
    case Repo.get_by(DeviceLogin, link_token: Token.hash_token(link_token)) do
      nil ->
        {:error, :not_found}

      login ->
        case DeviceLogin.status(login, DateTime.utc_now()) do
          :pending -> {:ok, login}
          other -> {:error, other}
        end
    end
  end

  @doc """
  Approves the login behind `link_token` if `user_code` matches. A wrong code
  is counted (and committed), so guessing runs out after a few tries.
  """
  def approve_device_login(link_token, user_code) do
    approve(link_token, user_code, &{:ok, &1})
  end

  @doc """
  Approves like `approve_device_login/2` and, in the same transaction, issues
  tokens for the browser that approved it (the PWA's sign-in page). Holding
  the link and the code already approves the asking device, which is the
  whole account, so the browser's session gives away nothing more.
  """
  def approve_device_login_and_sign_in(link_token, user_code) do
    approve(link_token, user_code, fn login ->
      {:ok, user} = get_or_create_user(login.email)
      issue_tokens(user)
    end)
  end

  # A failure after approving (issuing tokens) rolls the approval back too.
  defp approve(link_token, user_code, on_approved) do
    Repo.transaction(fn ->
      with {:ok, login} <- lock_device_login(link_token: Token.hash_token(link_token)) do
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        case DeviceLogin.check_code(login, user_code, now) do
          :ok ->
            case on_approved.(Repo.update!(Ecto.Changeset.change(login, approved_at: now))) do
              {:ok, _} = ok -> ok
              {:error, reason} -> Repo.rollback(reason)
            end

          {:error, :mismatch} ->
            Repo.update!(Ecto.Changeset.change(login, attempts: login.attempts + 1))
            {:error, :mismatch}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  What a polling device gets: tokens exactly once after approval, otherwise
  `:authorization_pending` or why it will never succeed.
  """
  def poll_device_login(device_code) do
    Repo.transaction(fn ->
      with {:ok, login} <- lock_device_login(device_code: Token.hash_token(device_code)) do
        case DeviceLogin.status(login, DateTime.utc_now()) do
          :approved ->
            {:ok, user} = get_or_create_user(login.email)
            {:ok, tokens} = issue_tokens(user)
            now = DateTime.utc_now() |> DateTime.truncate(:second)
            Repo.update!(Ecto.Changeset.change(login, consumed_at: now))
            tokens

          :pending ->
            Repo.rollback(:authorization_pending)

          other ->
            Repo.rollback(other)
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp lock_device_login(by) do
    case Repo.one(from(d in DeviceLogin, where: ^by, lock: "FOR UPDATE")) do
      nil -> {:error, :not_found}
      login -> {:ok, login}
    end
  end

  defp issue_tokens(user) do
    {:ok, access_token, _claims} = Token.generate_jwt(user.id)
    refresh_token = Token.generate_refresh_token()

    with {:ok, _} <- create_refresh_token(user.id, refresh_token) do
      {:ok, %{access_token: access_token, refresh_token: refresh_token, user: user}}
    end
  end

  ## Refresh Token functions

  # Creates a refresh token for a user.
  # Returns {:ok, refresh_token} or {:error, reason}
  defp create_refresh_token(user_id, token) do
    hashed_token = Token.hash_token(token)
    expires_at = Token.refresh_token_expires_at()

    query = """
    INSERT INTO refresh_tokens (token, user_id, expires_at, inserted_at)
    VALUES ($1, $2, $3, $4)
    """

    params = [hashed_token, Ecto.UUID.dump!(user_id), expires_at, DateTime.utc_now()]

    case Repo.query(query, params) do
      {:ok, _} -> {:ok, token}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Refreshes an access token using a refresh token.
  Returns {:ok, %{access_token: jwt}} or {:error, reason}
  """
  def refresh_access_token(refresh_token) do
    hashed_token = Token.hash_token(refresh_token)

    # Find valid refresh token and get user_id
    query = """
    SELECT user_id FROM refresh_tokens
    WHERE token = $1 AND expires_at > $2
    """

    case Repo.query(query, [hashed_token, DateTime.utc_now()]) do
      {:ok, %{rows: [[user_id]]}} ->
        {:ok, access_token, _claims} = Token.generate_jwt(Ecto.UUID.load!(user_id))
        {:ok, %{access_token: access_token}}

      {:ok, %{rows: []}} ->
        {:error, :invalid_or_expired_token}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Revokes a refresh token (logout).
  Returns :ok or {:error, reason}
  """
  def revoke_refresh_token(refresh_token) do
    hashed_token = Token.hash_token(refresh_token)

    query = """
    DELETE FROM refresh_tokens WHERE token = $1
    """

    case Repo.query(query, [hashed_token]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Cleans up expired device logins and refresh tokens.
  Should be run periodically.
  """
  def cleanup_expired_tokens do
    now = DateTime.utc_now()

    Repo.query("DELETE FROM device_logins WHERE expires_at < $1", [now])
    Repo.query("DELETE FROM refresh_tokens WHERE expires_at < $1", [now])

    :ok
  end
end
