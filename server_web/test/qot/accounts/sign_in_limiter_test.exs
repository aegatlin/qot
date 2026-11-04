defmodule Qot.Accounts.SignInLimiterTest do
  use ExUnit.Case, async: true

  alias Qot.Accounts.SignInLimiter

  setup do
    limiter =
      start_supervised!({SignInLimiter, name: nil, limits: %{email: {2, 3600}, ip: {3, 3600}}})

    %{limiter: limiter}
  end

  test "allows hits up to the limit, then refuses with a wait", %{limiter: limiter} do
    keys = [email: "a@example.com"]
    assert :ok = SignInLimiter.hit(limiter, keys)
    assert :ok = SignInLimiter.hit(limiter, keys)
    assert {:error, {:rate_limited, wait}} = SignInLimiter.hit(limiter, keys)
    assert wait > 3500 and wait <= 3600
  end

  test "parallel hits never get past the limit", %{limiter: limiter} do
    results =
      1..20
      |> Task.async_stream(fn _ -> SignInLimiter.hit(limiter, ip: "1.2.3.4") end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == :ok)) == 3
  end
end
