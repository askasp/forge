defmodule Forge.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Forge.Repo,
      ForgeWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:forge, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Forge.PubSub},
      {Registry, keys: :unique, name: Forge.SessionRegistry},
      {DynamicSupervisor, name: Forge.SessionSupervisor, strategy: :one_for_one},
      # Start to serve requests, typically the last entry
      ForgeWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Forge.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Restore sessions from snapshots after supervisor tree is up
    case result do
      {:ok, _pid} -> Task.start(fn -> Forge.Session.restore_sessions() end)
      _ -> :ok
    end

    result
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ForgeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
