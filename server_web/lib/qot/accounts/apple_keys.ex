defmodule Qot.Accounts.AppleKeys do
  @moduledoc """
  Apple's Sign in with Apple public keys, held in memory. A lookup for a
  `kid` not in hand fetches the keys again (Apple rotates them), at most once
  per `min_refetch_ms` so made-up kids can't make us hammer Apple. One
  process does the fetching, so a burst of sign-ins fetches once.

  Where keys come from is a `Qot.Accounts.AppleKeys.Source` (config
  `:qot, :apple_keys_source`; `Qot.Accounts.AppleKeys.Apple` by default), or
  a `:fetch` function given as an option.
  """

  use GenServer

  require Logger

  @default_min_refetch_ms :timer.minutes(1)

  defmodule Source do
    @moduledoc "Where Apple's keys come from: `{:ok, %{kid => jwk}}`."
    @callback fetch() :: {:ok, %{String.t() => JOSE.JWK.t()}} | {:error, term()}
  end

  defmodule Apple do
    @moduledoc "Apple's published keys, over HTTP."
    @behaviour Qot.Accounts.AppleKeys.Source

    @url "https://appleid.apple.com/auth/keys"

    @impl true
    def fetch do
      case Req.get(@url, receive_timeout: 5_000, retry: false) do
        {:ok, %Req.Response{status: 200, body: body}} -> Qot.Accounts.AppleKeys.parse(body)
        {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc """
  The key with this `kid`: `{:error, :unknown_key}` if Apple doesn't publish
  it, `{:error, :keys_unavailable}` if the keys couldn't be fetched.
  """
  @spec get(GenServer.server(), String.t()) ::
          {:ok, JOSE.JWK.t()} | {:error, :unknown_key | :keys_unavailable}
  def get(server \\ __MODULE__, kid), do: GenServer.call(server, {:get, kid}, 15_000)

  @doc "Apple's JWKS (`%{\"keys\" => [...]}`) as keys by `kid`."
  @spec parse(term()) :: {:ok, %{String.t() => JOSE.JWK.t()}} | {:error, :bad_keys}
  def parse(%{"keys" => keys}) when is_list(keys) do
    {:ok,
     for(%{"kid" => kid} = key when is_binary(kid) <- keys, into: %{}, do: {kid, from_map(key)})
     |> Map.reject(fn {_kid, jwk} -> jwk == nil end)}
  end

  def parse(_body), do: {:error, :bad_keys}

  defp from_map(key) do
    JOSE.JWK.from_map(key)
  rescue
    _ -> nil
  end

  @impl true
  def init(opts) do
    fetch =
      Keyword.get_lazy(opts, :fetch, fn ->
        source = Application.get_env(:qot, :apple_keys_source, Apple)
        &source.fetch/0
      end)

    min_refetch_ms =
      Keyword.get_lazy(opts, :min_refetch_ms, fn ->
        Application.get_env(:qot, :apple_keys_min_refetch_ms, @default_min_refetch_ms)
      end)

    {:ok, %{keys: nil, fetched_at: nil, fetch: fetch, min_refetch_ms: min_refetch_ms}}
  end

  @impl true
  def handle_call({:get, kid}, _from, state) do
    case state.keys do
      %{^kid => jwk} ->
        {:reply, {:ok, jwk}, state}

      _ ->
        state = if may_fetch?(state), do: fetch(state), else: state

        reply =
          case state.keys do
            nil -> {:error, :keys_unavailable}
            %{^kid => jwk} -> {:ok, jwk}
            _ -> {:error, :unknown_key}
          end

        {:reply, reply, state}
    end
  end

  defp may_fetch?(%{fetched_at: nil}), do: true

  defp may_fetch?(state),
    do: System.monotonic_time(:millisecond) - state.fetched_at >= state.min_refetch_ms

  # A failed fetch keeps the keys in hand and still counts as an attempt.
  defp fetch(state) do
    now = System.monotonic_time(:millisecond)

    case state.fetch.() do
      {:ok, keys} ->
        %{state | keys: keys, fetched_at: now}

      {:error, reason} ->
        Logger.warning("couldn't fetch Apple's sign-in keys: #{inspect(reason)}")
        %{state | fetched_at: now}
    end
  end
end
