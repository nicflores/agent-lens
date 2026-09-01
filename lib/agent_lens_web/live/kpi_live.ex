defmodule AgentLensWeb.KpiLive do
  @moduledoc """
  One KPI for one agent: the full chart with its threshold bands, and a
  methodology drawer explaining where the number came from.

  The drawer is not documentation for its own sake. Whether a score was
  computed here or imported from a LangSmith evaluator, which model judged it,
  and what fraction of runs it saw all change what the number *means* — and
  someone looking at a surprising value needs that without leaving the page.
  """

  use AgentLensWeb, :live_view

  alias AgentLens.Broadcaster
  alias AgentLens.Kpi.Registry
  alias AgentLens.Query
  alias AgentLens.Thresholds
  alias AgentLensWeb.ChartConfig
  alias AgentLensWeb.TimeRange

  @impl true
  def mount(%{"agent_id" => agent_id, "slug" => slug}, _session, socket) do
    registry = Registry.load!()

    case Registry.fetch_definition(registry, safe_slug(slug)) do
      {:ok, definition} ->
        if connected?(socket) do
          :ok = Broadcaster.subscribe({:kpi, agent_id, definition.slug})
        end

        {:ok,
         socket
         |> assign(:agent_id, agent_id)
         |> assign(:definition, definition)
         |> assign(:page_title, "#{definition.name} · #{agent_id}")
         |> assign(:reading, Query.latest(agent_id, definition.slug, hysteresis: 3))
         |> assign(:annotations, [])
         |> assign_thresholds(agent_id, definition)
         |> assign(:series, %{points: [], granularity: nil, downsampled?: false})
         |> assign(:loading?, true)
         |> assign(:drawer_open?, false)}

      :error ->
        {:ok,
         socket
         |> put_flash(:error, "No KPI named #{slug}.")
         |> push_navigate(to: ~p"/agents/#{agent_id}")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    range = TimeRange.parse(params["range"])

    {:noreply,
     socket
     |> assign(:range, range)
     |> assign(:drawer_open?, params["methodology"] == "open")
     |> load_series(range)}
  end

  @impl true
  def handle_event("save_thresholds", %{"thresholds" => params}, socket) do
    definition = socket.assigns.definition

    case Thresholds.put(socket.assigns.agent_id, definition, parse_thresholds(definition, params),
           updated_by: "dashboard"
         ) do
      {:ok, _record} ->
        {:noreply,
         socket
         |> put_flash(:info, "Thresholds updated for this agent.")
         |> reload_thresholds()}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Could not save those thresholds.")}

      {:error, reason} when is_binary(reason) ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  def handle_event("reset_thresholds", _params, socket) do
    :ok = Thresholds.delete(socket.assigns.agent_id, socket.assigns.definition.slug)

    {:noreply,
     socket
     |> put_flash(:info, "Restored the shipped defaults.")
     |> reload_thresholds()}
  end

  @impl true
  def handle_event("range", %{"range" => range}, socket) do
    {:noreply, push_patch(socket, to: kpi_path(socket, range: range))}
  end

  def handle_event("toggle_methodology", _params, socket) do
    methodology = if socket.assigns.drawer_open?, do: nil, else: "open"
    {:noreply, push_patch(socket, to: kpi_path(socket, methodology: methodology))}
  end

  # A closed bucket arrives as one point, not a fresh series. The client holds
  # everything before it already.
  @impl true
  def handle_info({:kpi_point, _agent_id, _slug, point}, socket) do
    {:noreply,
     socket
     |> assign(
       :reading,
       Query.latest(socket.assigns.agent_id, socket.assigns.definition.slug, hysteresis: 3)
     )
     |> push_event("chart:kpi-chart:point", %{
       t: DateTime.to_unix(point.at),
       v: point.value
     })}
  end

  @impl true
  def handle_async(:series, {:ok, %{series: series, annotations: annotations}}, socket) do
    {:noreply,
     socket
     |> assign(:series, series)
     |> assign(:annotations, annotations)
     |> assign(:loading?, false)}
  end

  def handle_async(:series, {:exit, _reason}, socket) do
    {:noreply,
     socket |> assign(:loading?, false) |> put_flash(:error, "Could not load this range.")}
  end

  # The definition held in socket state carries the *effective* thresholds, so
  # the chart bands, the bullet chart and the status badge all move together
  # the moment an override is saved.
  defp assign_thresholds(socket, agent_id, definition) do
    overrides = Thresholds.for_agent(agent_id)
    effective = Thresholds.apply_override(definition, overrides)

    socket
    |> assign(:definition, effective)
    |> assign(:overridden?, Map.has_key?(overrides, definition.slug))
    |> assign(:threshold_form, to_form(threshold_params(effective), as: :thresholds))
  end

  defp reload_thresholds(socket) do
    {:ok, shipped} =
      Registry.fetch_definition(Registry.load!(), socket.assigns.definition.slug)

    socket
    |> assign_thresholds(socket.assigns.agent_id, shipped)
    |> then(fn updated ->
      assign(
        updated,
        :reading,
        Query.latest(updated.assigns.agent_id, updated.assigns.definition.slug, hysteresis: 3)
      )
    end)
  end

  defp threshold_params(%{direction: :target_band, thresholds: t}) do
    %{good: {good_low, good_high}, warning: {warn_low, warn_high}} = t

    %{
      "good_low" => good_low,
      "good_high" => good_high,
      "warning_low" => warn_low,
      "warning_high" => warn_high
    }
  end

  defp threshold_params(%{thresholds: t}),
    do: %{"warning" => t.warning, "critical" => t.critical}

  defp parse_thresholds(%{direction: :target_band}, params) do
    %{
      good: {number(params["good_low"]), number(params["good_high"])},
      warning: {number(params["warning_low"]), number(params["warning_high"])}
    }
  end

  defp parse_thresholds(_definition, params),
    do: %{warning: number(params["warning"]), critical: number(params["critical"])}

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _rest} -> number
      :error -> 0.0
    end
  end

  defp number(value) when is_number(value), do: value * 1.0
  defp number(_other), do: 0.0

  defp load_series(socket, range) do
    agent_id = socket.assigns.agent_id
    slug = socket.assigns.definition.slug
    {from, to} = TimeRange.bounds(range)

    socket
    |> assign(:loading?, true)
    |> start_async(:series, fn ->
      %{
        series: Query.series(agent_id, slug, from, to),
        annotations: Query.annotations(agent_id, slug, from, to)
      }
    end)
  end

  # State lives in the URL, so every view of this page is a shareable link and
  # the back button behaves.
  defp kpi_path(socket, overrides) do
    params =
      %{range: socket.assigns.range}
      |> Map.merge(if(socket.assigns.drawer_open?, do: %{methodology: "open"}, else: %{}))
      |> Map.merge(Map.new(overrides))
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    ~p"/agents/#{socket.assigns.agent_id}/kpis/#{socket.assigns.definition.slug}?#{params}"
  end

  # Slugs arrive from the URL. `to_existing_atom` keeps a hand-typed path from
  # growing the atom table; an unknown one simply fails the registry lookup.
  defp safe_slug(slug) do
    String.to_existing_atom(slug)
  rescue
    ArgumentError -> :__unknown_kpi__
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      breadcrumbs={[
        %{label: @agent_id, navigate: ~p"/agents/#{@agent_id}"},
        %{label: @definition.name}
      ]}
    >
      <div class="flex flex-col gap-6">
        <div class="flex flex-wrap items-end justify-between gap-4">
          <div>
            <div class="flex items-center gap-3">
              <h1 class="text-xl font-semibold tracking-tight text-al-ink">{@definition.name}</h1>
              <.status_badge status={@reading.status} />
            </div>
            <p class="mt-1 max-w-2xl text-sm text-al-ink-soft">{@definition.short_description}</p>
          </div>

          <div class="flex items-center gap-2">
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

            <button
              id="methodology-toggle"
              phx-click="toggle_methodology"
              aria-expanded={to_string(@drawer_open?)}
              aria-controls="methodology-drawer"
              class="inline-flex items-center gap-1.5 rounded-lg border border-al-line bg-al-panel px-3 py-1.5 text-xs font-medium text-al-ink-soft transition hover:text-al-ink"
            >
              <span class="hero-information-circle size-4" aria-hidden="true" /> Methodology
            </button>
          </div>
        </div>

        <div class="grid gap-4 lg:grid-cols-[1fr_20rem]">
          <div class="flex flex-col gap-4">
            <div class="rounded-xl border border-al-line bg-al-panel p-4">
              <div class="mb-3 flex items-baseline justify-between gap-3">
                <div class="flex items-baseline gap-2">
                  <span class="al-num text-3xl font-semibold tracking-tight text-al-ink">
                    {format_value(@reading.value, @definition)}
                  </span>
                  <span class="text-xs text-al-ink-soft">{unit_label(@definition.unit)}</span>
                </div>
                <.sample_meter
                  sample_n={@reading.sample_n}
                  population_n={@reading.population_n}
                  definition={@definition}
                />
              </div>

              <div
                :if={@loading?}
                id="chart-skeleton"
                class="h-[260px] animate-pulse rounded bg-al-grid"
              />

              <div
                :if={!@loading? && @series.points != []}
                id="kpi-chart"
                phx-hook="ChartHook"
                phx-update="ignore"
                data-chart={
                  ChartConfig.to_json(@definition, @series,
                    status: @reading.status,
                    annotations: @annotations
                  )
                }
                class="w-full"
              />

              <div
                :if={!@loading? && @series.points == []}
                id="chart-empty"
                class="flex h-[260px] flex-col items-center justify-center gap-2 rounded-lg border border-dashed border-al-line"
              >
                <span class="hero-chart-bar size-6 text-al-ink-soft" aria-hidden="true" />
                <p class="text-sm text-al-ink-soft">No data in this range</p>
                <p class="max-w-xs text-center text-xs text-al-ink-soft/70">
                  Nothing is plotted where nothing was measured, rather than drawing a zero.
                </p>
              </div>

              <p
                :if={@reading.raw_status != @reading.status}
                id="hysteresis-note"
                class="mt-2 flex items-center gap-1.5 text-xs text-al-ink-soft"
              >
                <span class="hero-clock size-3.5" aria-hidden="true" />
                Latest bucket reads {String.downcase(status_label(@reading.raw_status))}. Held at {String.downcase(
                  status_label(@reading.status)
                )} until the change is sustained.
              </p>

              <p
                :if={@series.downsampled?}
                class="mt-2 flex items-center gap-1.5 text-xs text-al-ink-soft"
              >
                <span class="hero-arrows-pointing-in size-3.5" aria-hidden="true" />
                Buckets combined to fit the range. Percentile series read as an envelope here.
              </p>
            </div>

            <div class="rounded-xl border border-al-line bg-al-panel p-4">
              <h2 class="text-sm font-semibold text-al-ink">Against its thresholds</h2>
              <p class="mt-1 text-xs text-al-ink-soft">{direction_explanation(@definition)}</p>
              <.bullet_chart
                definition={@definition}
                value={@reading.value}
                status={@reading.status}
                height={40}
                class="mt-3"
              />
              <dl class="mt-3 grid grid-cols-2 gap-3 text-xs sm:grid-cols-4">
                <div :for={{label, value} <- threshold_rows(@definition)}>
                  <dt class="text-al-ink-soft">{label}</dt>
                  <dd class="al-num mt-0.5 font-medium text-al-ink">{value}</dd>
                </div>
              </dl>
            </div>
          </div>

          <div class="flex flex-col gap-4">
            <.methodology_drawer
              definition={@definition}
              reading={@reading}
              series={@series}
              open?={@drawer_open?}
            />

            <.threshold_editor
              definition={@definition}
              form={@threshold_form}
              overridden?={@overridden?}
            />
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :definition, :map, required: true
  attr :reading, :map, required: true
  attr :series, :map, required: true
  attr :open?, :boolean, required: true

  defp methodology_drawer(assigns) do
    ~H"""
    <aside
      id="methodology-drawer"
      class={[
        "flex flex-col gap-4 rounded-xl border p-4 transition",
        @open? && "border-al-accent/40 bg-al-panel",
        !@open? && "border-al-line bg-al-panel/60"
      ]}
    >
      <h2 class="text-sm font-semibold text-al-ink">How this is measured</h2>

      <dl class="flex flex-col gap-3 text-xs">
        <div>
          <dt class="text-al-ink-soft">Source</dt>
          <dd class="mt-0.5 font-medium text-al-ink">{source_label(@definition)}</dd>
        </div>
        <div>
          <dt class="text-al-ink-soft">Aggregation</dt>
          <dd class="mt-0.5 font-medium text-al-ink">{aggregation_label(@definition.aggregation)}</dd>
        </div>
        <div>
          <dt class="text-al-ink-soft">Sampling</dt>
          <dd class="mt-0.5 font-medium text-al-ink">{sampling_label(@definition)}</dd>
        </div>
        <div>
          <dt class="text-al-ink-soft">Minimum sample</dt>
          <dd class="al-num mt-0.5 font-medium text-al-ink">
            {@definition.min_sample_n} observations
          </dd>
        </div>
        <div>
          <dt class="text-al-ink-soft">Version</dt>
          <dd class="al-num mt-0.5 font-medium text-al-ink">v{@definition.version}</dd>
        </div>
        <div>
          <dt class="text-al-ink-soft">Contributes to agent health</dt>
          <dd class="mt-0.5 font-medium text-al-ink">
            {health_label(@definition.health_contribution)}
          </dd>
        </div>
        <div :if={@series.granularity}>
          <dt class="text-al-ink-soft">Bucket size</dt>
          <dd class="mt-0.5 font-medium text-al-ink">{@series.granularity}</dd>
        </div>
      </dl>

      <div :if={@open? && @definition.methodology} class="border-t border-al-line pt-3">
        <p class="text-xs leading-relaxed whitespace-pre-line text-al-ink-soft">
          {@definition.methodology}
        </p>
      </div>

      <p :if={!@open?} class="border-t border-al-line pt-3 text-xs text-al-ink-soft/70">
        Open the methodology panel for the full definition.
      </p>
    </aside>
    """
  end

  attr :definition, :map, required: true
  attr :form, :map, required: true
  attr :overridden?, :boolean, required: true

  defp threshold_editor(assigns) do
    ~H"""
    <section id="threshold-editor" class="rounded-xl border border-al-line bg-al-panel p-4">
      <div class="flex items-start justify-between gap-2">
        <div>
          <h2 class="text-sm font-semibold text-al-ink">Thresholds for this agent</h2>
          <p class="mt-1 text-xs text-al-ink-soft">
            The right limit for a customer-facing agent is wrong for an internal one. Tuning here
            takes effect immediately, with no deploy.
          </p>
        </div>
        <span
          :if={@overridden?}
          id="override-badge"
          class="shrink-0 rounded-full border border-al-accent/30 px-2 py-0.5 text-xs font-medium text-al-accent"
        >
          Overridden
        </span>
      </div>

      <.form
        for={@form}
        id="threshold-form"
        phx-submit="save_thresholds"
        class="mt-3 flex flex-col gap-3"
      >
        <div :if={@definition.direction != :target_band} class="grid grid-cols-2 gap-3">
          <.input field={@form[:warning]} type="number" step="any" label="Warning" />
          <.input field={@form[:critical]} type="number" step="any" label="Critical" />
        </div>

        <div :if={@definition.direction == :target_band} class="grid grid-cols-2 gap-3">
          <.input field={@form[:warning_low]} type="number" step="any" label="Critical below" />
          <.input field={@form[:good_low]} type="number" step="any" label="Healthy from" />
          <.input field={@form[:good_high]} type="number" step="any" label="Healthy to" />
          <.input field={@form[:warning_high]} type="number" step="any" label="Critical above" />
        </div>

        <div class="flex items-center gap-2">
          <button
            type="submit"
            id="save-thresholds"
            class="rounded-lg bg-al-accent px-3 py-1.5 text-xs font-medium text-white transition hover:opacity-90"
          >
            Save
          </button>
          <button
            :if={@overridden?}
            type="button"
            id="reset-thresholds"
            phx-click="reset_thresholds"
            class="rounded-lg border border-al-line px-3 py-1.5 text-xs font-medium text-al-ink-soft transition hover:text-al-ink"
          >
            Restore defaults
          </button>
        </div>
      </.form>
    </section>
    """
  end

  defp threshold_rows(%{direction: :target_band, thresholds: t}) do
    %{good: {good_low, good_high}, warning: {warn_low, warn_high}} = t

    [
      {"Critical below", to_string(warn_low)},
      {"Healthy from", to_string(good_low)},
      {"Healthy to", to_string(good_high)},
      {"Critical above", to_string(warn_high)}
    ]
  end

  defp threshold_rows(%{thresholds: t} = definition) do
    [
      {"Warning", format_value(t.warning * 1.0, definition)},
      {"Critical", format_value(t.critical * 1.0, definition)}
    ]
  end

  defp direction_explanation(%{direction: :higher_is_better}), do: "Higher is better."
  defp direction_explanation(%{direction: :lower_is_better}), do: "Lower is better."

  defp direction_explanation(%{direction: :target_band}),
    do: "Healthy within a band — both extremes are a problem, not just one."

  defp source_label(%{kind: :extracted}), do: "Computed here, from the run payload"
  defp source_label(%{kind: :judged}), do: "Scored by a LangSmith evaluator, imported"
  defp source_label(%{kind: :derived}), do: "Derived from other KPIs' rollups"

  defp aggregation_label(:mean), do: "Mean over the bucket"
  defp aggregation_label(:rate), do: "Rate over the bucket"
  defp aggregation_label(:p50), do: "50th percentile"
  defp aggregation_label(:p95), do: "95th percentile"
  defp aggregation_label(:p99), do: "99th percentile"
  defp aggregation_label(:count), do: "Count"
  defp aggregation_label(:count_distinct), do: "Distinct count"

  defp sampling_label(%{kind: :judged, sample_rate: rate}),
    do: "#{round(rate * 100)}% of runs — judging costs money"

  defp sampling_label(_definition), do: "Every run"

  defp health_label(:critical), do: "Yes — can turn the agent red"
  defp health_label(:normal), do: "Yes"
  defp health_label(:none), do: "No — informational only"
end
