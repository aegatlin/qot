defmodule QotWeb.AccountControllerTest do
  use QotWeb.ConnCase, async: true

  alias Qot.Accounts
  alias QotWeb.AuthHelpers

  setup %{conn: conn} do
    auth = AuthHelpers.create_authenticated_user("leaving@example.com")
    %{conn: AuthHelpers.authenticate_conn(conn, auth.access_token), auth: auth}
  end

  test "deletes the account when confirmed with its email", %{conn: conn, auth: auth} do
    note = %{note_id: Ecto.UUID.generate(), data: Base.encode64("x")}
    conn |> post("/api/sync/push", %{changes: [note]}) |> json_response(200)

    assert %{"deleted" => true} =
             conn
             |> delete("/api/account", %{confirm: " Leaving@Example.com "})
             |> json_response(200)

    assert {:error, :not_found} = Accounts.get_user(auth.user_id)
  end

  describe "an account signed in with Apple (#88)" do
    setup %{auth: auth} do
      Qot.Repo.get!(Qot.Accounts.User, auth.user_id)
      |> Ecto.Changeset.change(
        apple_sub: "s1",
        apple_refresh_token: "apple-refresh-r1",
        apple_client_id: "llc.abstractsyntax.qot"
      )
      |> Qot.Repo.update!()

      :ok
    end

    test "has its Apple token revoked when deleted", %{conn: conn, auth: auth} do
      conn |> delete("/api/account", %{confirm: "leaving@example.com"}) |> json_response(200)

      assert_received {:apple_revoke, "llc.abstractsyntax.qot", "apple-refresh-r1"}
      assert {:error, :not_found} = Accounts.get_user(auth.user_id)
    end

    test "is deleted even when Apple can't be reached", %{conn: conn, auth: auth} do
      Process.put(:apple_revoke_result, {:error, :unreachable})

      conn |> delete("/api/account", %{confirm: "leaving@example.com"}) |> json_response(200)
      assert {:error, :not_found} = Accounts.get_user(auth.user_id)
    end
  end

  test "an account without an Apple token revokes nothing", %{conn: conn} do
    conn |> delete("/api/account", %{confirm: "leaving@example.com"}) |> json_response(200)
    refute_received {:apple_revoke, _, _}
  end

  test "a token issued before deletion is refused, so its devices sign out",
       %{conn: conn, auth: auth} do
    note = %{note_id: Ecto.UUID.generate(), data: Base.encode64("x")}
    :ok = Accounts.delete_user(auth.user_id)

    # The JWT is still within its hour, but the account behind it is gone.
    assert conn |> get("/api/sync/pull") |> json_response(401)
    assert conn |> post("/api/sync/push", %{changes: [note]}) |> json_response(401)
    assert conn |> delete("/api/account", %{confirm: "leaving@example.com"}) |> json_response(401)
  end

  test "refuses without the right confirmation", %{conn: conn, auth: auth} do
    assert %{"error" => "confirmation_mismatch"} =
             conn |> delete("/api/account", %{confirm: "other@example.com"}) |> json_response(400)

    assert %{"error" => "confirmation_mismatch"} =
             conn |> delete("/api/account", %{}) |> json_response(400)

    assert {:ok, _} = Accounts.get_user(auth.user_id)
  end

  test "needs a token", %{auth: auth} do
    assert build_conn()
           |> delete("/api/account", %{confirm: "leaving@example.com"})
           |> json_response(401)

    assert {:ok, _} = Accounts.get_user(auth.user_id)
  end
end
