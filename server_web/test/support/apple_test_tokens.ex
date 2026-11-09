defmodule Qot.AppleTestTokens do
  @moduledoc """
  A stand-in for Apple's token endpoints (`/auth/token`, `/auth/revoke`),
  the `Qot.Accounts.AppleTokens.API` the test config gives the server. Each
  call is sent to the calling process (requests in ConnTest run in the test
  process), and answers come from the process dictionary:

      Process.put(:apple_exchange_result, {:error, :unreachable})
      Process.put(:apple_revoke_result, {:error, :unreachable})

  By default an exchange returns the refresh token `"apple-refresh-<code>"`
  and a revoke succeeds.
  """

  @behaviour Qot.Accounts.AppleTokens.API

  @impl true
  def exchange(client_id, code) do
    send(self(), {:apple_exchange, client_id, code})
    Process.get(:apple_exchange_result, {:ok, "apple-refresh-" <> code})
  end

  @impl true
  def revoke(client_id, refresh_token) do
    send(self(), {:apple_revoke, client_id, refresh_token})
    Process.get(:apple_revoke_result, :ok)
  end
end
