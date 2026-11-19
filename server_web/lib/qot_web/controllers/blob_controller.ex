defmodule QotWeb.BlobController do
  @moduledoc """
  Attachments' bytes, in and out. The body is the blob, whatever its
  `content-type`; the server stores no type and always answers
  `application/octet-stream`.
  """

  use QotWeb, :controller

  alias Qot.Blobs

  def put(conn, %{"id" => id} = params) do
    with {:ok, id} <- uuid(id, "id"),
         {:ok, note_id} <- uuid(params["note_id"], "note_id"),
         {:ok, bytes, conn} <- read(conn),
         :ok <- Blobs.put(conn.assigns.user_id, id, note_id, bytes) do
      send_resp(conn, :no_content, "")
    else
      {:error, :too_large, conn} -> refuse(conn, :request_entity_too_large, "too_large")
      {:error, :too_large} -> refuse(conn, :request_entity_too_large, "too_large")
      {:error, :quota_exceeded} -> refuse(conn, :forbidden, "quota_exceeded")
      {:error, :deleted} -> refuse(conn, :gone, "deleted")
      {:error, :empty} -> refuse(conn, :bad_request, "The body is empty")
      {:error, :unknown_user} -> refuse(conn, :unauthorized, "Unknown user")
      {:error, reason} when is_binary(reason) -> refuse(conn, :bad_request, reason)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, id} <- uuid(id, "id"),
         {:ok, bytes} <- Blobs.get(conn.assigns.user_id, id) do
      conn
      |> put_resp_header("content-type", "application/octet-stream")
      |> put_resp_header("cache-control", "private, no-store")
      |> send_resp(:ok, bytes)
    else
      {:error, :not_found} -> refuse(conn, :not_found, "Not found")
      {:error, reason} when is_binary(reason) -> refuse(conn, :bad_request, reason)
    end
  end

  defp uuid(value, name) do
    case is_binary(value) && Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, String.downcase(uuid)}
      _ -> {:error, "#{name} is not a UUID"}
    end
  end

  # The whole body, unless it is over the limit: then stop reading.
  defp read(conn, acc \\ []) do
    max = Blobs.max_bytes()

    case Plug.Conn.read_body(conn, length: max + 1, read_length: 1_000_000) do
      {status, chunk, conn} when status in [:ok, :more] ->
        acc = [acc | chunk]

        cond do
          IO.iodata_length(acc) > max -> {:error, :too_large, conn}
          status == :more -> read(conn, acc)
          true -> {:ok, IO.iodata_to_binary(acc), conn}
        end

      {:error, reason} ->
        {:error, "The body couldn't be read: #{inspect(reason)}"}
    end
  end

  defp refuse(conn, status, error) do
    conn |> put_status(status) |> json(%{error: error})
  end
end
