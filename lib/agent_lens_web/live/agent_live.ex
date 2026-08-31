defmodule AgentLensWeb.AgentLive do
  @moduledoc """
  One agent's drilldown: every KPI as a card, over a chosen time range.

  Mount renders immediately from the cached summary and only then loads the
  series behind it, so the page is useful before the queries finish rather than
  showing a spinner over an empty screen.
  """

  use AgentLensWeb, :live_view

  alias AgentLens.Broadcaster
  alias AgentLens.Query
  alias AgentLensWeb.TimeRange

  @impl true
  def mount(%{"agent_id" => agent_id}, _session, socket) do
    _subscription = if connected?(socket), do: Broadcaster.subscribe({:agent, agent_id})

    summary = Broadcaster.agent_summary(agent_id)

    {:ok,
     socket
     |> assign(:agent_id, agent_id)
     |> assign(:page_title, agent_id)
     |> assign(:summary, summary)
     |> assign(:age_seconds, Broadcaster.age_seconds())
     |> assign(:series, %{})
     |> assign(:loading?, true)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    range = TimeRange.parse(params["range"])

    {:noreply,
     socket
     |> assign(:range, range)
     |> load_series(range)}
  end

  @impl true
  def handle_event("range", %{"range" => range}, socket) do
    {:noreply, push_patch(socket, to: ~p"/agents/#{socket.assigns.agent_id}?#{%{range: range}}")}
  end

  @impl true
  def handle_info({:agent_updated, summary}, socket) do
    {:noreply,
     socket
     |> assign(:summary, summary)
     |> assign(:age_seconds, Broadcaster.age_seconds())}
  end

  @impl true
  def handle_async(:series, {:ok, series}, socket) do
    {:noreply, socket |> assign(:series, series) |> assign(:loading?, false)}
  end

  def handle_async(:series, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:loading?, false)
     |> put_flash(:error, "Could not load chart data for this range.")}
  end

  # The cards are already on screen from cache; this fills in their charts.
  defp load_series(socket, range) do
    agent_id = socket.assigns.agent_id
    slugs = Enum.map(socket.assigns.summary.kpis, & &1.slug)
    {from, to} = TimeRange.bounds(range)

    socket
    |> assign(:loading?, true)
    |> start_async(:series, fn ->
      Map.new(slugs, fn slug -> {slug, Query.series(agent_id, slug, from, to)} end)
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} breadcrumbs={[%{label: @agent_id}]}>
      <:actions>
        <.freshness age_seconds={@age_seconds} />
      </:actions>

      <div class="flex flex-col gap-6">
        <div class="flex flex-wrap items-end justify-between gap-4">
          <div class="flex items-center gap-3">
            <div>
              <h1 class="text-xl font-semibold tracking-tight text-al-ink">{@agent_id}</h1>
              <p class="mt-1 text-sm text-al-ink-soft">
                {length(@summary.kpis)} KPIs over the last {TimeRange.label(@range)}
              </p>
            </div>
            <.status_badge status={@summary.status} />
          </div>

          <.range_picker range={@range} />
        </div>

        <div id="kpi-grid" class="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
          <div :for={kpi <- @summary.kpis} class="flex flex-col gap-2">
            <.kpi_card
              id={"kpi-#{kpi.slug}"}
              kpi={kpi}
              navigate={~p"/agents/#{@agent_id}/kpis/#{kpi.slug}?#{%{range: @range}}"}
            />
            <div class="rounded-lg border border-al-line bg-al-panel px-3 py-2">
              <.sparkline
                :if={!@loading?}
                points={points_for(@series, kpi.slug)}
                status={kpi.status}
              />
              <div :if={@loading?} class="h-8 animate-pulse rounded bg-al-grid" aria-hidden="true" />
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :range, :string, required: true

  defp range_picker(assigns) do
    ~H"""
    <div
      id="range-picker"
      class="flex items-center gap-1 rounded-lg border border-al-line bg-al-panel p-1"
      role="group"
      aria-label="Time range"
    >
      <button
        :for={{key, label} <- TimeRange.options()}
        id={"range-#{key}"}
        phx-click="range"
        phx-value-range={key}
        aria-pressed={to_string(@range == key)}
        class={[
          "rounded-md px-2.5 py-1 text-xs font-medium transition",
          @range == key && "bg-al-accent text-white",
          @range != key && "text-al-ink-soft hover:text-al-ink"
        ]}
      >
        {label}
      </button>
    </div>
    """
  end

  defp points_for(series, slug) do
    case Map.fetch(series, slug) do
      {:ok, %{points: points}} -> points
      :error -> []
    end
  end
end
