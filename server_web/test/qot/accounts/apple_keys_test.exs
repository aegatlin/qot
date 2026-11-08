defmodule Qot.Accounts.AppleKeysTest do
  use ExUnit.Case, async: true

  alias Qot.Accounts.AppleKeys
  alias Qot.AppleTestKeys, as: Keys

  # A key source that counts its calls and answers from `responses` in turn.
  defp source(responses) do
    {:ok, agent} = Agent.start_link(fn -> {0, responses} end)

    fetch = fn ->
      Agent.get_and_update(agent, fn {n, [r | rest]} -> {r, {n + 1, rest ++ [r]}} end)
    end

    calls = fn -> Agent.get(agent, fn {n, _} -> n end) end
    {fetch, calls}
  end

  defp start(fetch, opts \\ []) do
    start_supervised!({AppleKeys, opts ++ [name: nil, fetch: fetch, min_refetch_ms: 0]})
  end

  describe "parse/1" do
    test "reads Apple's JWKS into keys by kid" do
      assert {:ok, %{"test-kid" => %JOSE.JWK{}}} =
               AppleKeys.parse(%{"keys" => [Keys.public_map()]})
    end

    test "skips keys without a kid and refuses anything else" do
      assert {:ok, keys} = AppleKeys.parse(%{"keys" => [Map.delete(Keys.public_map(), "kid")]})
      assert keys == %{}
      assert {:error, :bad_keys} = AppleKeys.parse(%{"nope" => 1})
      assert {:error, :bad_keys} = AppleKeys.parse("<html>")
    end
  end

  test "fetches once and serves later lookups from memory" do
    {fetch, calls} = source([Keys.fetch()])
    keys = start(fetch)

    assert {:ok, %JOSE.JWK{}} = AppleKeys.get(keys, "test-kid")
    assert {:ok, %JOSE.JWK{}} = AppleKeys.get(keys, "test-kid")
    assert calls.() == 1
  end

  test "refetches when a kid is unknown (Apple rotated its keys)" do
    {fetch, calls} = source([{:ok, %{}}, Keys.fetch()])
    keys = start(fetch)

    assert {:error, :unknown_key} = AppleKeys.get(keys, "test-kid")
    assert {:ok, _} = AppleKeys.get(keys, "test-kid")
    assert calls.() == 2
  end

  test "doesn't refetch for unknown kids more often than allowed" do
    {fetch, calls} = source([Keys.fetch()])
    keys = start(fetch, min_refetch_ms: 60_000)

    assert {:ok, _} = AppleKeys.get(keys, "test-kid")
    assert {:error, :unknown_key} = AppleKeys.get(keys, "made-up")
    assert {:error, :unknown_key} = AppleKeys.get(keys, "made-up")
    assert calls.() == 1
  end

  test "says when the keys can't be fetched" do
    {fetch, _calls} = source([{:error, :timeout}])
    keys = start(fetch)

    assert {:error, :keys_unavailable} = AppleKeys.get(keys, "test-kid")
  end
end
