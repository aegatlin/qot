defmodule QotWeb.AppOriginTest do
  use ExUnit.Case, async: true

  alias QotWeb.AppOrigin

  test "an origin is scheme, host and any non-default port" do
    assert AppOrigin.origin("https://app.quantumofthought.com/") ==
             "https://app.quantumofthought.com"

    assert AppOrigin.origin("http://localhost:5173/x?y") == "http://localhost:5173"
    assert AppOrigin.origin("https://app.example:443") == "https://app.example"
  end

  test "only the app's origin may open a socket from a browser" do
    allowed = ["https://app.quantumofthought.com"]
    assert AppOrigin.allowed?(URI.parse("https://app.quantumofthought.com"), allowed)
    refute AppOrigin.allowed?(URI.parse("https://evil.example"), allowed)
    refute AppOrigin.allowed?(URI.parse("http://app.quantumofthought.com"), allowed)
    refute AppOrigin.allowed?(URI.parse("https://app.quantumofthought.com"), [])
  end

  test "the sign-in link goes to the app when there is one" do
    assert AppOrigin.sign_in_url("https://app.example", "https://api.example", "t0k") ==
             "https://app.example/auth/device?token=t0k"

    assert AppOrigin.sign_in_url(nil, "https://api.example", "t0k") ==
             "https://api.example/auth/device?token=t0k"
  end
end
