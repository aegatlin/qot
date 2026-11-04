defmodule QotWeb.SignInRateLimitTest do
  # Changes app config, so not async: ExUnit runs this after the async tests.
  use QotWeb.ConnCase, async: false

  setup do
    limits = Application.fetch_env!(:qot, :sign_in_limits)
    header = Application.get_env(:qot, :client_ip_header)
    Application.put_env(:qot, :sign_in_limits, %{email: {2, 3600}, ip: {3, 3600}})
    Application.put_env(:qot, :client_ip_header, "x-real-ip")

    on_exit(fn ->
      Application.put_env(:qot, :sign_in_limits, limits)
      Application.put_env(:qot, :client_ip_header, header)
    end)

    # The limiter outlives a test, so each run uses keys of its own.
    %{tag: System.unique_integer([:positive])}
  end

  defp start(conn, email, ip) do
    conn
    |> put_req_header("x-real-ip", ip)
    |> post("/api/auth/device", %{email: email})
  end

  test "too many sign-ins for one address get a 429 with Retry-After", %{conn: conn, tag: tag} do
    email = "flood-#{tag}@example.com"
    assert start(conn, email, "10.1.0.1").status == 200
    # Case doesn't make it a different inbox; another IP doesn't help either.
    assert start(conn, String.upcase(email), "10.1.0.2").status == 200

    conn = start(conn, email, "10.1.0.3")
    assert %{"error" => "rate_limited", "retry_after" => wait} = json_response(conn, 429)
    assert get_resp_header(conn, "retry-after") == [Integer.to_string(wait)]
    assert wait > 3500
  end

  test "too many sign-ins from one client IP get a 429", %{conn: conn, tag: tag} do
    ip = "10.2.#{rem(tag, 250)}.#{rem(div(tag, 250), 250)}"

    for n <- 1..3 do
      assert start(conn, "spray-#{tag}-#{n}@example.com", ip).status == 200
    end

    assert %{"error" => "rate_limited"} =
             conn |> start("spray-#{tag}-4@example.com", ip) |> json_response(429)

    assert start(conn, "spray-#{tag}-4@example.com", "10.3.0.1").status == 200
  end

  test "a refused sign-in sends no email", %{conn: conn, tag: tag} do
    import Swoosh.TestAssertions
    email = "quiet-#{tag}@example.com"

    for ip <- ["10.4.0.1", "10.4.0.2"], do: start(conn, email, ip)
    assert_email_sent(to: email)
    assert_email_sent(to: email)

    assert start(conn, email, "10.4.0.3").status == 429
    refute_email_sent()
  end
end
