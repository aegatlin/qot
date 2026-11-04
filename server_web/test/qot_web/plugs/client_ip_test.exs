defmodule QotWeb.Plugs.ClientIPTest do
  use ExUnit.Case, async: true

  alias QotWeb.Plugs.ClientIP

  @remote {10, 0, 0, 1}

  test "without a configured header, the peer address is the client" do
    assert ClientIP.from(@remote, [{"x-real-ip", "1.2.3.4"}], nil) == @remote
  end

  test "with a configured header, its address is the client" do
    assert ClientIP.from(@remote, [{"x-real-ip", "1.2.3.4"}], "x-real-ip") == {1, 2, 3, 4}

    assert ClientIP.from(@remote, [{"x-real-ip", " 2001:db8::1 "}], "x-real-ip") ==
             {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}
  end

  test "a missing or unparsable header falls back to the peer address" do
    assert ClientIP.from(@remote, [], "x-real-ip") == @remote
    assert ClientIP.from(@remote, [{"x-real-ip", "nonsense"}], "x-real-ip") == @remote
    assert ClientIP.from(@remote, [{"x-real-ip", "1.2.3.4, 5.6.7.8"}], "x-real-ip") == @remote
  end
end
