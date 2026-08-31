defmodule AgentLens.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        AgentLensWeb.Telemetry,
        AgentLens.Repo,
        {DNSCluster, query: Application.get_env(:agent_lens, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: AgentLens.PubSub},
        # Ensures partitions and syncs the KPI catalog. Must come after the Repo
        # and before anything that ingests. Refuses the boot on a bad KPI config.
        boot_child(),
        # Registry and DynamicSupervisor for the ingestion pollers. Always
        # started; whether any pollers run is a separate config decision.
        AgentLens.Ingestion.Supervisor,
        {Oban, Application.fetch_env!(:agent_lens, Oban)},
        # Read-path: one ETS cache, and the single process that writes it.
        AgentLens.Cache,
        {AgentLens.Broadcaster, start_timer: AgentLens.Broadcaster.timer_enabled?()},
        # Start to serve requests, typically the last entry
        AgentLensWeb.Endpoint
      ]
      |> Enum.reject(&is_nil/1)

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: AgentLens.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Skipped in test, where the sandbox owns the connection and each test sets up
  # exactly the state it needs.
  defp boot_child do
    if AgentLens.Boot.enabled?(), do: {AgentLens.Boot, []}
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AgentLensWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
