defmodule QotWeb.NotesChannel do
  @moduledoc """
  Tells a user's connected clients that new changes exist. It carries only
  the new cursor; clients fetch the changes with `GET /api/sync/pull`, so
  there is one way data moves.
  """

  use Phoenix.Channel

  alias Qot.Sync

  @impl true
  def join("notes:user:" <> user_id, _params, socket) do
    if socket.assigns.user_id == user_id do
      Phoenix.PubSub.subscribe(Qot.PubSub, Sync.topic(user_id))
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info({:changes, cursor}, socket) do
    push(socket, "changed", %{cursor: cursor})
    {:noreply, socket}
  end
end
