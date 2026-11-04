defmodule Qot.Accounts.SignInLimiter do
  @moduledoc """
  The shell around `Qot.Accounts.SignInLimit`: one process holds the
  history, so parallel requests are checked one at a time and a burst can't
  slip past the limit.

  The history lives in memory: nothing about who tried to sign in (no IPs)
  is stored, and a restart forgets it. That is fine for one server instance.
  With several, each would allow the full limit; move the history to the
  database then.

  Limits come from `config :qot, :sign_in_limits` unless given as the
  `:limits` option.
  """

  use GenServer

  alias Qot.Accounts.SignInLimit

  @sweep_every :timer.minutes(10)

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc """
  Records a sign-in attempt for `keys` (e.g. `[email: "…", ip: "…"]`), or
  refuses it with the seconds to wait.
  """
  @spec hit(GenServer.server(), [SignInLimit.key()]) ::
          :ok | {:error, {:rate_limited, pos_integer()}}
  def hit(server \\ __MODULE__, keys), do: GenServer.call(server, {:hit, keys})

  @impl true
  def init(opts) do
    Process.send_after(self(), :sweep, @sweep_every)
    {:ok, %{history: %{}, limits: Keyword.get(opts, :limits)}}
  end

  @impl true
  def handle_call({:hit, keys}, _from, state) do
    case SignInLimit.hit(state.history, keys, limits(state), now()) do
      {:ok, history} -> {:reply, :ok, %{state | history: history}}
      {:error, wait} -> {:reply, {:error, {:rate_limited, wait}}, state}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    Process.send_after(self(), :sweep, @sweep_every)
    {:noreply, %{state | history: SignInLimit.prune(state.history, limits(state), now())}}
  end

  defp limits(%{limits: nil}), do: Application.fetch_env!(:qot, :sign_in_limits)
  defp limits(%{limits: limits}), do: limits

  defp now, do: System.os_time(:second)
end
