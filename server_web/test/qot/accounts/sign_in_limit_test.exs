defmodule Qot.Accounts.SignInLimitTest do
  use ExUnit.Case, async: true

  alias Qot.Accounts.SignInLimit

  @limits %{email: {3, 60}, ip: {5, 60}}

  defp hits(history, keys, times) do
    Enum.reduce(times, history, fn t, h ->
      {:ok, h} = SignInLimit.hit(h, keys, @limits, t)
      h
    end)
  end

  test "allows up to the limit, then says how long to wait" do
    keys = [email: "a@example.com"]
    history = hits(%{}, keys, [100, 110, 120])

    # The oldest hit (100) leaves the 60 s window at 160.
    assert {:error, 40} = SignInLimit.hit(history, keys, @limits, 120)
    assert {:error, 1} = SignInLimit.hit(history, keys, @limits, 159)
    assert {:ok, _} = SignInLimit.hit(history, keys, @limits, 160)
  end

  test "a refused attempt is not counted, so waiting is enough" do
    keys = [email: "a@example.com"]
    history = hits(%{}, keys, [0, 0, 0])

    assert {:error, 60} = SignInLimit.hit(history, keys, @limits, 0)
    assert {:ok, _} = SignInLimit.hit(history, keys, @limits, 60)
  end

  test "keys are limited independently, and the longest wait wins" do
    history = hits(%{}, [email: "a@example.com"], [0])
    history = hits(history, [email: "a@example.com", ip: "1.2.3.4"], [10, 20])
    history = hits(history, [ip: "1.2.3.4"], [30, 40, 50])

    # email a: 0, 10, 20 (full until 60); ip: 10..50 (full until 70).
    assert {:error, 10} = SignInLimit.hit(history, [email: "a@example.com"], @limits, 50)
    assert {:error, 20} = SignInLimit.hit(history, [ip: "1.2.3.4"], @limits, 50)

    assert {:error, 20} =
             SignInLimit.hit(history, [email: "a@example.com", ip: "1.2.3.4"], @limits, 50)

    assert {:ok, _} = SignInLimit.hit(history, [email: "b@example.com"], @limits, 50)
  end

  test "a refused hit records nothing for the other keys either" do
    history = hits(%{}, [email: "a@example.com"], [0, 0, 0])

    assert {:error, _} =
             SignInLimit.hit(history, [ip: "1.2.3.4", email: "a@example.com"], @limits, 0)

    refute Map.has_key?(history, {:ip, "1.2.3.4"})
  end

  test "prune drops hits outside every window and empty keys" do
    history = hits(%{}, [email: "a@example.com"], [0])
    history = hits(history, [email: "b@example.com"], [50])

    assert SignInLimit.prune(history, @limits, 61) == %{{:email, "b@example.com"} => [50]}
  end

  test "email keys ignore case and surrounding space" do
    assert SignInLimit.email_key(" Me@Example.COM ") == "me@example.com"
  end

  test "IPv4 is limited per address, IPv6 per /64" do
    assert SignInLimit.ip_key({1, 2, 3, 4}) == "1.2.3.4"
    assert SignInLimit.ip_key({0x2001, 0xDB8, 1, 2, 3, 4, 5, 6}) == "2001:db8:1:2::/64"

    assert SignInLimit.ip_key({0x2001, 0xDB8, 1, 2, 9, 9, 9, 9}) ==
             SignInLimit.ip_key({0x2001, 0xDB8, 1, 2, 3, 4, 5, 6})
  end
end
