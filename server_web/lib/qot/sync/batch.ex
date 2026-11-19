defmodule Qot.Sync.Batch do
  @moduledoc """
  Pure validation and numbering for sync requests. No I/O.

  A change is opaque bytes for one note. The server never parses them, so a
  client may encrypt them end to end without the server noticing.
  """

  @max_changes 500
  @max_change_bytes 1_000_000
  @default_limit 500
  @max_limit 1000

  @type entry :: %{note_id: Ecto.UUID.t(), data: binary()}

  def max_changes, do: @max_changes
  def max_change_bytes, do: @max_change_bytes
  def default_limit, do: @default_limit
  def max_limit, do: @max_limit

  @doc "Parses a push body. One bad change rejects the batch."
  @spec parse_push(map()) :: {:ok, [entry()]} | {:error, String.t()}
  def parse_push(%{"changes" => changes}) when is_list(changes) and changes != [] do
    if length(changes) > @max_changes do
      {:error, "a push may hold at most #{@max_changes} changes"}
    else
      changes
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {change, i}, {:ok, acc} ->
        case parse_change(change) do
          {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
          {:error, reason} -> {:halt, {:error, "change #{i}: #{reason}"}}
        end
      end)
      |> case do
        {:ok, entries} -> {:ok, Enum.reverse(entries)}
        error -> error
      end
    end
  end

  def parse_push(_), do: {:error, "expected a non-empty \"changes\" list"}

  defp parse_change(%{"note_id" => note_id, "data" => data})
       when is_binary(note_id) and is_binary(data) do
    with {:ok, note_id} <- cast_uuid(note_id),
         {:ok, bytes} <- decode(data) do
      {:ok, %{note_id: note_id, data: bytes}}
    end
  end

  defp parse_change(_), do: {:error, "expected \"note_id\" and \"data\" strings"}

  defp cast_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, String.downcase(uuid)}
      :error -> {:error, "note_id is not a UUID"}
    end
  end

  defp decode(data) do
    case Base.decode64(data) do
      {:ok, ""} -> {:error, "data is empty"}
      {:ok, bytes} when byte_size(bytes) > @max_change_bytes -> {:error, "data is too large"}
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, "data is not base64"}
    end
  end

  @doc """
  Parses a push body's optional `deleted_blobs`: the ids of blobs to delete
  with the push. Repeats are dropped; one bad id rejects the push.
  """
  @spec parse_deleted_blobs(map()) :: {:ok, [Ecto.UUID.t()]} | {:error, String.t()}
  def parse_deleted_blobs(%{"deleted_blobs" => ids}) when is_list(ids) do
    if length(ids) > @max_changes do
      {:error, "a push may delete at most #{@max_changes} blobs"}
    else
      ids
      |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
        case is_binary(id) && Ecto.UUID.cast(id) do
          {:ok, uuid} -> {:cont, {:ok, [String.downcase(uuid) | acc]}}
          _ -> {:halt, {:error, "deleted_blobs must be UUIDs"}}
        end
      end)
      |> case do
        {:ok, ids} -> {:ok, ids |> Enum.reverse() |> Enum.uniq()}
        error -> error
      end
    end
  end

  def parse_deleted_blobs(%{"deleted_blobs" => _}), do: {:error, "deleted_blobs must be a list"}
  def parse_deleted_blobs(_), do: {:ok, []}

  @doc "Parses pull params: `since` (default 0) and `limit` (clamped)."
  @spec parse_pull(map()) ::
          {:ok, %{since: non_neg_integer(), limit: pos_integer()}} | {:error, String.t()}
  def parse_pull(params) do
    with {:ok, since} <- int(params, "since", 0),
         {:ok, limit} <- int(params, "limit", @default_limit) do
      if since < 0,
        do: {:error, "since must not be negative"},
        else: {:ok, %{since: since, limit: limit |> max(1) |> min(@max_limit)}}
    end
  end

  defp int(params, key, default) do
    case Map.get(params, key) do
      nil ->
        {:ok, default}

      n when is_integer(n) ->
        {:ok, n}

      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, ""} -> {:ok, n}
          _ -> {:error, "#{key} must be an integer"}
        end

      _ ->
        {:error, "#{key} must be an integer"}
    end
  end

  @doc "Numbers entries so the last one gets `last_seq`."
  @spec number([entry()], pos_integer()) :: [map()]
  def number(entries, last_seq) do
    first = last_seq - length(entries) + 1

    entries
    |> Enum.with_index(first)
    |> Enum.map(fn {entry, seq} -> Map.put(entry, :seq, seq) end)
  end
end
