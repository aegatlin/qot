defmodule Qot.Accounts.SignInLimit do
  @moduledoc """
  The pure rules for how often sign-ins may start: a sliding window per key
  (an email address, a client IP), over an immutable history of hits.

  Starting a sign-in sends an email, so without a limit anyone could flood an
  inbox, burn the mail quota and the sending domain's reputation. The
  per-email limit protects the inbox; the per-IP limit stops one client
  spraying many addresses.

  A refused attempt is not recorded, so waiting out `retry_after` is always
  enough.
  """

  @typedoc "`{kind, value}`, e.g. `{:email, \"me@example.com\"}`."
  @type key :: {atom(), String.t()}
  @typedoc "Per kind: at most `max` hits in any `window` seconds."
  @type limits :: %{atom() => {pos_integer(), pos_integer()}}
  @typedoc "Per key, the times (unix seconds) of its recent hits, newest first."
  @type history :: %{key() => [integer()]}

  @doc """
  Records a hit for every key, or none if any key is over its limit, in
  which case it says how many seconds until all of them would allow one.
  A key whose kind has no limit is ignored.
  """
  @spec hit(history(), [key()], limits(), integer()) ::
          {:ok, history()} | {:error, pos_integer()}
  def hit(history, keys, limits, now) do
    limited = Enum.filter(keys, fn {kind, _} -> Map.has_key?(limits, kind) end)

    waits =
      for {kind, _} = key <- limited,
          wait = wait(Map.get(history, key, []), limits[kind], now),
          wait > 0,
          do: wait

    case waits do
      [] ->
        {:ok,
         Enum.reduce(limited, history, fn {kind, _} = key, acc ->
           Map.put(acc, key, [now | recent(Map.get(acc, key, []), limits[kind], now)])
         end)}

      waits ->
        {:error, Enum.max(waits)}
    end
  end

  # Seconds until one more hit fits in the window: once the `max`-th newest
  # hit has left it, at most `max - 1` remain.
  defp wait(times, {max, window} = limit, now) do
    case Enum.at(recent(times, limit, now), max - 1) do
      nil -> 0
      t -> t + window - now
    end
  end

  defp recent(times, {_max, window}, now), do: Enum.take_while(times, &(&1 > now - window))

  @doc "Drops hits that have left their window, and keys with none left."
  @spec prune(history(), limits(), integer()) :: history()
  def prune(history, limits, now) do
    for {{kind, _} = key, times} <- history,
        limit = Map.get(limits, kind),
        limit != nil,
        times = recent(times, limit, now),
        times != [],
        into: %{},
        do: {key, times}
  end

  @doc "Addresses that differ only in case or surrounding space are one inbox."
  @spec email_key(String.t()) :: String.t()
  def email_key(email), do: email |> String.trim() |> String.downcase()

  @doc """
  IPv4 is limited per address. IPv6 per /64: one host usually has a whole
  /64, so limiting single addresses would limit nothing.
  """
  @spec ip_key(:inet.ip_address()) :: String.t()
  def ip_key({_, _, _, _} = ip), do: ip |> :inet.ntoa() |> to_string()

  def ip_key({a, b, c, d, _, _, _, _}),
    do: ({a, b, c, d, 0, 0, 0, 0} |> :inet.ntoa() |> to_string()) <> "/64"
end
