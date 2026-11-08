defmodule Qot.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Qot.Repo,
      {Phoenix.PubSub, name: Qot.PubSub},
      Qot.Accounts.SignInLimiter,
      Qot.Accounts.AppleKeys,
      QotWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Qot.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    QotWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
