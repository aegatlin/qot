defmodule QotWeb.NotesChannelTest do
  use QotWeb.ChannelCase, async: true

  alias Qot.Sync
  alias QotWeb.AuthHelpers

  setup do
    auth = AuthHelpers.create_authenticated_user()
    {:ok, socket} = connect(QotWeb.UserSocket, %{"token" => auth.access_token})
    %{socket: socket, auth: auth}
  end

  test "a socket without a valid token is refused" do
    assert :error = connect(QotWeb.UserSocket, %{"token" => "bad"})
    assert :error = connect(QotWeb.UserSocket, %{})
  end

  test "a user cannot join another user's topic", %{socket: socket} do
    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(socket, "notes:user:#{Ecto.UUID.generate()}", %{})
  end

  test "a push from any client nudges joined clients with the new cursor",
       %{socket: socket, auth: auth} do
    {:ok, _, _} = subscribe_and_join(socket, "notes:user:#{auth.user_id}", %{})

    {:ok, 1} = Sync.push(auth.user_id, [%{note_id: Ecto.UUID.generate(), data: "x"}])

    assert_push "changed", %{cursor: 1}
  end
end
