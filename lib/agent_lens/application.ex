defmodule AgentLens.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AgentLensWeb.Telemetry,
      AgentLens.Repo,
      {DNSCluster, query: Application.get_env(:agent_lens, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: AgentLens.PubSub},
      # Start a worker by calling: AgentLens.Worker.start_link(arg)
      # {AgentLens.Worker, arg},
      # Start to serve requests, typically the last entry
      AgentLensWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: AgentLens.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AgentLensWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
