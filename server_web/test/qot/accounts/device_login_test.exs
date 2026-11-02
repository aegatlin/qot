defmodule Qot.Accounts.DeviceLoginTest do
  use ExUnit.Case, async: true

  alias Qot.Accounts.DeviceLogin

  @now ~U[2026-11-02 12:00:00Z]

  defp login(attrs \\ %{}) do
    struct!(
      %DeviceLogin{
        user_code: "BCDF-GHJK",
        attempts: 0,
        approved_at: nil,
        consumed_at: nil,
        expires_at: DateTime.add(@now, 600)
      },
      attrs
    )
  end

  describe "user codes" do
    test "are 8 unambiguous letters in two groups" do
      code = DeviceLogin.user_code_from_bytes(:crypto.strong_rand_bytes(8))
      assert code =~ ~r/^[BCDFGHJKLMNPQRSTVWXZ]{4}-[BCDFGHJKLMNPQRSTVWXZ]{4}$/
    end

    test "are deterministic in the bytes they are built from" do
      bytes = <<0, 1, 2, 3, 4, 5, 6, 7>>
      assert DeviceLogin.user_code_from_bytes(bytes) == DeviceLogin.user_code_from_bytes(bytes)
    end

    test "normalise what a person types" do
      assert DeviceLogin.normalize_user_code(" bcdf ghjk ") == "BCDF-GHJK"
      assert DeviceLogin.normalize_user_code("bcdfghjk") == "BCDF-GHJK"
      assert DeviceLogin.normalize_user_code("BCDF-GHJK") == "BCDF-GHJK"
    end
  end

  describe "status/2" do
    test "walks pending -> approved -> consumed" do
      assert DeviceLogin.status(login(), @now) == :pending
      assert DeviceLogin.status(login(%{approved_at: @now}), @now) == :approved

      assert DeviceLogin.status(login(%{approved_at: @now, consumed_at: @now}), @now) ==
               :consumed
    end

    test "expires, even once approved" do
      later = DateTime.add(@now, 601)
      assert DeviceLogin.status(login(), later) == :expired
      assert DeviceLogin.status(login(%{approved_at: @now}), later) == :expired
    end

    test "is denied after too many wrong codes" do
      assert DeviceLogin.status(login(%{attempts: DeviceLogin.max_attempts()}), @now) == :denied
    end
  end

  describe "check_code/3" do
    test "approves the matching code however it was typed" do
      assert DeviceLogin.check_code(login(), "bcdf ghjk", @now) == :ok
    end

    test "rejects a wrong code" do
      assert DeviceLogin.check_code(login(), "BCDF-GHJX", @now) == {:error, :mismatch}
    end

    test "refuses a login that is no longer pending" do
      assert DeviceLogin.check_code(login(%{approved_at: @now}), "BCDF-GHJK", @now) ==
               {:error, :approved}

      assert DeviceLogin.check_code(login(), "BCDF-GHJK", DateTime.add(@now, 601)) ==
               {:error, :expired}

      denied = login(%{attempts: DeviceLogin.max_attempts()})
      assert DeviceLogin.check_code(denied, "BCDF-GHJK", @now) == {:error, :denied}
    end
  end
end
