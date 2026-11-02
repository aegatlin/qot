defmodule QotWeb.SyncController do
  use QotWeb, :controller

  alias Qot.Sync
  alias Qot.Sync.Batch

  def push(conn, params) do
    with {:ok, entries} <- Batch.parse_push(params),
         {:ok, cursor} <- Sync.push(conn.assigns.user_id, entries) do
      json(conn, %{cursor: cursor})
    else
      {:error, :unknown_user} ->
        conn |> put_status(:unauthorized) |> json(%{error: "Unknown user"})

      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: reason})
    end
  end

  def pull(conn, params) do
    case Batch.parse_pull(params) do
      {:ok, %{since: since, limit: limit}} ->
        {:ok, page} = Sync.pull(conn.assigns.user_id, since, limit)

        json(conn, %{
          changes: Enum.map(page.changes, &%{&1 | data: Base.encode64(&1.data)}),
          cursor: page.cursor,
          more: page.more
        })

      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: reason})
    end
  end
end
