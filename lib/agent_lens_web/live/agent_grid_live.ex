defmodule AgentLensWeb.AgentGridLive do
  @moduledoc """
  The agent grid: every agent, its rolled-up status, and what drove it.

  Mount is a cache read, not a query. The broadcaster has already computed this
  and pushes updates over PubSub, so opening a twentieth dashboard costs the
  database nothing.
  """

  use AgentLensWeb, :live_view

  alias AgentLens.Broadcaster

  @impl true
  def mount(_params, _session, socket) do
    _subscription = if connected?(socket), do: Broadcaster.subscribe(:overview)

    overview = Broadcaster.overview()

    {:ok,
     socket
     |> assign(:page_title, "Agents")
     |> assign(:age_seconds, Broadcaster.age_seconds())
     |> assign_overview(overview)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :filter, parse_filter(params["status"]))}
  end

  @impl true
  def handle_info({:overview_updated, overview}, socket) do
    {:noreply,
     socket
     |> assign(:age_seconds, Broadcaster.age_seconds())
     |> assign_overview(overview)}
  end

  @impl true
  def handle_event("filter", %{"status" => status}, socket) do
    {:noreply, push_patch(socket, to: ~p"/?#{filter_params(status)}")}
  end

  defp assign_overview(socket, overview) do
    socket
    |> assign(:agents, overview.agents)
    |> assign(:computed_at, overview.computed_at)
    |> assign(:totals, totals(overview.agents))
  end

  defp totals(agents) do
    Enum.reduce(agents, %{good: 0, warning: 0, critical: 0, unknown: 0}, fn agent, acc ->
      Map.update!(acc, agent.status, &(&1 + 1))
    end)
  end

  defp parse_filter(status) when status in ~w(good warning critical unknown),
    do: String.to_existing_atom(status)

  defp parse_filter(_other), do: :all

  defp filter_params("all"), do: %{}
  defp filter_params(status), do: %{status: status}

  defp visible(agents, :all), do: agents
  defp visible(agents, status), do: Enum.filter(agents, &(&1.status == status))

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :visible_agents, visible(assigns.agents, assigns.filter))

    ~H"""
    <Layouts.app flash={@flash}>
      <:actions>
        <.freshness age_seconds={@age_seconds} />
      </:actions>

      <div class="flex flex-col gap-6">
        <div class="flex flex-wrap items-end justify-between gap-4">
          <div>
            <h1 class="text-xl font-semibold tracking-tight text-al-ink">Agents</h1>
            <p class="mt-1 text-sm text-al-ink-soft">
              {length(@agents)} agents reporting. Status is the worst contributing KPI on each.
            </p>
          </div>

          <div
            id="status-filter"
            class="flex items-center gap-1 rounded-lg border border-al-line bg-al-panel p-1"
          >
            <button
              :for={{value, label, count} <- filter_buttons(@totals, length(@agents))}
              id={"filter-#{value}"}
              phx-click="filter"
              phx-value-status={value}
              class={[
                "rounded-md px-2.5 py-1 text-xs font-medium transition",
                to_string(@filter) == value && "bg-al-accent text-white",
                to_string(@filter) != value && "text-al-ink-soft hover:text-al-ink"
              ]}
              aria-pressed={to_string(to_string(@filter) == value)}
            >
              {label} <span class="al-num opacity-70">{count}</span>
            </button>
          </div>
        </div>

        <div
          :if={@visible_agents != []}
          id="agent-grid"
          class="grid gap-4 sm:grid-cols-2 xl:grid-cols-3"
        >
          <.agent_tile :for={agent <- @visible_agents} id={"agent-#{agent.agent_id}"} summary={agent} />
        </div>

        <div
          :if={@visible_agents == []}
          id="empty-state"
          class="rounded-xl border border-dashed border-al-line p-12 text-center"
        >
          <span class="hero-inbox mx-auto size-8 text-al-ink-soft" aria-hidden="true" />
          <p class="mt-3 text-sm font-medium text-al-ink">{empty_title(@agents, @filter)}</p>
          <p class="mt-1 text-sm text-al-ink-soft">{empty_hint(@agents)}</p>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp filter_buttons(totals, total) do
    [
      {"all", "All", total},
      {"critical", "Critical", totals.critical},
      {"warning", "Warning", totals.warning},
      {"unknown", "Unknown", totals.unknown},
      {"good", "Good", totals.good}
    ]
  end

  defp empty_title([], _filter), do: "No agents reporting yet"
  defp empty_title(_agents, filter), do: "No agents are #{filter}"

  defp empty_hint([]),
    do: "Run `mix agent_lens.seed` to populate the dashboard with ninety days of mock history."

  defp empty_hint(_agents), do: "Try a different filter."
end
