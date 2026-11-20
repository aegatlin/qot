defmodule QotWeb.TranscriptionController do
  @moduledoc """
  `POST /api/transcriptions`: the body is one recording, the answer its
  text. Nothing of either is stored (`Qot.Transcription`).
  """

  use QotWeb, :controller

  alias Qot.Blobs
  alias Qot.Transcription

  def create(conn, params) do
    with {:ok, bytes, conn} <- read(conn),
         {:ok, text} <-
           Transcription.transcribe(
             conn.assigns.user_id,
             bytes,
             filename(conn),
             duration_ms(params)
           ) do
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> json(%{text: text})
    else
      {:error, :too_large, conn} -> refuse(conn, :request_entity_too_large, "too_large")
      {:error, :empty} -> refuse(conn, :bad_request, "The body is empty")
      {:error, :unknown_user} -> refuse(conn, :unauthorized, "Unknown user")
      {:error, :plan_required} -> refuse(conn, :payment_required, "plan_required")
      {:error, :unavailable} -> refuse(conn, :service_unavailable, "transcription_unavailable")
      {:error, :allowance_used} -> refuse(conn, :too_many_requests, "allowance_used")
      {:error, :provider_failed} -> refuse(conn, :bad_gateway, "provider_failed")
      {:error, reason} when is_binary(reason) -> refuse(conn, :bad_request, reason)
    end
  end

  defp duration_ms(%{"duration_ms" => value}) when is_binary(value) do
    case Integer.parse(value) do
      {ms, ""} -> ms
      _ -> nil
    end
  end

  defp duration_ms(_params), do: nil

  # The provider tells the format from the file's name.
  defp filename(conn) do
    type = conn |> get_req_header("content-type") |> List.first() |> to_string()

    extension =
      case type |> String.split(";") |> hd() |> String.trim() |> String.downcase() do
        "audio/mpeg" -> "mp3"
        "audio/wav" -> "wav"
        "audio/x-wav" -> "wav"
        "audio/webm" -> "webm"
        "audio/ogg" -> "ogg"
        "audio/flac" -> "flac"
        _ -> "m4a"
      end

    "memo.#{extension}"
  end

  # The whole body, up to a blob's size limit.
  defp read(conn, acc \\ []) do
    max = Blobs.max_bytes()

    case Plug.Conn.read_body(conn, length: max + 1, read_length: 1_000_000) do
      {status, chunk, conn} when status in [:ok, :more] ->
        acc = [acc | chunk]

        cond do
          IO.iodata_length(acc) > max -> {:error, :too_large, conn}
          status == :more -> read(conn, acc)
          IO.iodata_length(acc) == 0 -> {:error, :empty}
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
