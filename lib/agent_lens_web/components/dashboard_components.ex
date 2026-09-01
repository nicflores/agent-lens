defmodule AgentLensWeb.DashboardComponents do
  @moduledoc """
  The dashboard's visual vocabulary.

  ## The card is the extension unit

  `kpi_card/1` takes a `%Definition{}` and a reading, and nothing else. Because
  the definition already carries the name, description, unit, direction and
  thresholds, a newly added KPI renders correctly here with **no UI code at
  all**. `component/0` on the KPI module is the escape hatch for a bespoke
  visual; everything else falls through to this.

  ## Encoding good and bad

  A red dot tells you which side of a line you are on. It does not tell you how
  close you are to the next one, and it silently lies about KPIs that have a
  healthy *band* rather than a healthy direction. So the encoding is layered:

    * a **bullet chart** shows the value against its threshold zones, so a
      value drifting toward a boundary is visible several buckets before it
      crosses;
    * a **trend arrow** whose geometry is the delta and whose colour is the
      meaning — toxicity rising is a red up-arrow;
    * **sample adequacy** shown explicitly, because a score from three runs and
      a score from four hundred must not look alike;
    * and always icon + colour + text, never colour alone.
  """

  use Phoenix.Component

  alias AgentLens.Kpi.Definition

  @status_labels %{
    good: "Good",
    warning: "Warning",
    critical: "Critical",
    unknown: "Unknown"
  }

  # Icons carry the signal for anyone who cannot rely on the colour.
  @status_icons %{
    good: "hero-check-circle",
    warning: "hero-exclamation-triangle",
    critical: "hero-exclamation-circle",
    unknown: "hero-question-mark-circle"
  }

  @doc """
  A status pill: icon, colour and word together.

  Never colour alone. Someone who cannot distinguish the red from the green
  still reads "Critical" and sees a different glyph.
  """
  attr :status, :atom, required: true
  attr :size, :atom, default: :md, values: [:sm, :md]
  attr :class, :string, default: nil

  def status_badge(assigns) do
    ~H"""
    <span
      class={[
        "inline-flex items-center gap-1.5 rounded-full border font-medium whitespace-nowrap",
        @size == :sm && "px-2 py-0.5 text-xs",
        @size == :md && "px-2.5 py-1 text-sm",
        status_classes(@status),
        @class
      ]}
      title={status_explanation(@status)}
    >
      <span class={[status_icon(@status), "size-3.5 shrink-0"]} aria-hidden="true" />
      {status_label(@status)}
    </span>
    """
  end

  @doc """
  A Tufte bullet chart: the value against its own threshold zones.

  Shows *how close* to a boundary a KPI is, not merely which side of it — which
  is the whole difference between a dashboard you can act on and one that only
  tells you after the fact.

  Banded KPIs get a genuine band: the healthy zone sits in the middle, and both
  extremes shade toward critical. A two-direction encoding would paint the
  wrong end green.
  """
  attr :definition, Definition, required: true
  attr :value, :float, default: nil
  attr :status, :atom, default: :unknown
  attr :baseline, :float, default: nil
  attr :height, :integer, default: 28
  attr :class, :string, default: nil

  def bullet_chart(assigns) do
    {low, high} = bullet_domain(assigns.definition, assigns.value)

    assigns =
      assigns
      |> assign(:low, low)
      |> assign(:high, high)
      |> assign(:zones, bullet_zones(assigns.definition, low, high))
      |> assign(:fill, fraction(assigns.value, low, high))
      |> assign(:baseline_fraction, fraction(assigns.baseline, low, high))

    ~H"""
    <div class={["w-full", @class]}>
      <svg
        viewBox="0 0 100 12"
        preserveAspectRatio="none"
        class="w-full"
        style={"height: #{@height}px"}
        role="img"
        aria-label={bullet_label(@definition, @value, @status)}
      >
        <rect x="0" y="0" width="100" height="12" rx="1.5" class="fill-al-grid" />

        <rect
          :for={zone <- @zones}
          x={zone.from}
          y="0"
          width={max(zone.to - zone.from, 0)}
          height="12"
          class={zone_class(zone.status)}
        />

        <rect
          :if={@fill}
          x="0"
          y="4"
          width={@fill * 100}
          height="4"
          rx="1"
          class={bar_class(@status)}
        />

        <line
          :if={@baseline_fraction}
          x1={@baseline_fraction * 100}
          x2={@baseline_fraction * 100}
          y1="1"
          y2="11"
          stroke-width="1"
          class="stroke-al-ink"
          vector-effect="non-scaling-stroke"
        />

        <line
          :if={@fill}
          x1={@fill * 100}
          x2={@fill * 100}
          y1="0"
          y2="12"
          stroke-width="2"
          class={tick_class(@status)}
          vector-effect="non-scaling-stroke"
        />
      </svg>
    </div>
    """
  end

  @doc """
  A compact sparkline. Deliberately unlabelled — it is a shape, not a reading.

  Draws nothing at all when there is no data. An empty chart says "no data";
  a flat line at zero says "measured, and it was zero", which would be a lie.
  """
  attr :points, :list, default: []
  attr :status, :atom, default: :unknown
  attr :height, :integer, default: 32
  attr :class, :string, default: nil

  def sparkline(assigns) do
    assigns = assign(assigns, :path, sparkline_path(assigns.points))

    ~H"""
    <div class={["w-full", @class]} style={"height: #{@height}px"}>
      <svg
        :if={@path}
        viewBox="0 0 100 30"
        preserveAspectRatio="none"
        class="h-full w-full overflow-visible"
        aria-hidden="true"
      >
        <path
          d={@path}
          fill="none"
          stroke-width="1.5"
          class={stroke_class(@status)}
          vector-effect="non-scaling-stroke"
        />
      </svg>
      <div :if={!@path} class="flex h-full items-center text-xs text-al-ink-soft">
        No data in this range
      </div>
    </div>
    """
  end

  @doc """
  A trend arrow whose geometry is the change and whose colour is its meaning.

  Toxicity rising is a **red up-arrow**: the arrow points up because the number
  went up, and it is red because for that KPI up is bad. Encoding the direction
  in the colour instead would make every chart need a legend.

  Compares against the same window a week earlier rather than the window
  immediately before, so ordinary weekly rhythm does not read as a regression.
  """
  attr :delta, :float, default: nil
  attr :definition, Definition, required: true
  attr :class, :string, default: nil

  def trend_arrow(assigns) do
    assigns = assign(assigns, :meaning, delta_meaning(assigns.definition, assigns.delta))

    ~H"""
    <span
      :if={@delta}
      class={[
        "inline-flex items-center gap-1 text-xs font-medium al-num",
        trend_class(@meaning),
        @class
      ]}
      title={"#{format_delta(@delta)} versus the same window last week"}
    >
      <span class={[trend_icon(@delta), "size-3.5"]} aria-hidden="true" />
      {format_delta(@delta)}
      <span class="sr-only">{trend_description(@meaning)} versus the same window last week</span>
    </span>
    """
  end

  @doc """
  How much of the population this reading actually rests on.

  A sampled KPI that saw 3 of 400 runs is a fundamentally weaker claim than one
  that saw all 400, and the card has to say so rather than presenting both as
  the same number.
  """
  attr :sample_n, :integer, default: 0
  attr :population_n, :integer, default: 0
  attr :definition, Definition, required: true
  attr :class, :string, default: nil

  def sample_meter(assigns) do
    assigns = assign(assigns, :adequate?, assigns.sample_n >= assigns.definition.min_sample_n)

    ~H"""
    <span
      class={[
        "inline-flex items-center gap-1 text-xs al-num",
        @adequate? && "text-al-ink-soft",
        !@adequate? && "text-status-unknown",
        @class
      ]}
      title={sample_explanation(@sample_n, @population_n, @definition)}
    >
      <span :if={!@adequate?} class="hero-beaker size-3.5" aria-hidden="true" />
      n={@sample_n}<span :if={@population_n > 0} class="opacity-60">/{@population_n}</span>
    </span>
    """
  end

  @doc """
  A KPI card, rendered entirely from its definition and one reading.

  Adding a KPI to the registry is enough to make a correct card appear here:
  the name, the one-line description, the unit, the direction, the thresholds
  and the sampling minimum all travel with the definition.
  """
  attr :kpi, :map, required: true
  attr :points, :list, default: []
  attr :navigate, :string, default: nil
  attr :id, :string, required: true

  def kpi_card(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "group relative flex flex-col gap-3 rounded-xl border bg-al-panel p-4 transition",
        "border-al-line hover:border-al-ink-soft/40"
      ]}
    >
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <.link
            :if={@navigate}
            navigate={@navigate}
            class="text-sm font-semibold text-al-ink hover:text-al-accent focus:outline-none"
          >
            <span class="absolute inset-0" aria-hidden="true"></span>
            {@kpi.definition.name}
          </.link>
          <span :if={!@navigate} class="text-sm font-semibold text-al-ink">
            {@kpi.definition.name}
          </span>
          <p
            class="mt-0.5 line-clamp-2 text-xs text-al-ink-soft"
            title={@kpi.definition.short_description}
          >
            {@kpi.definition.short_description}
          </p>
        </div>
        <.status_badge status={@kpi.status} size={:sm} />
      </div>

      <div class="flex items-baseline gap-2">
        <span class="al-num text-2xl font-semibold tracking-tight text-al-ink">
          {format_value(@kpi.value, @kpi.definition)}
        </span>
        <span :if={@kpi.value} class="text-xs text-al-ink-soft">{unit_label(@kpi.definition.unit)}</span>
        <.trend_arrow delta={@kpi[:delta]} definition={@kpi.definition} class="ml-auto" />
      </div>

      <.bullet_chart
        definition={@kpi.definition}
        value={@kpi.value}
        status={@kpi.status}
        baseline={@kpi[:baseline]}
      />

      <div class="flex items-center justify-between text-xs text-al-ink-soft">
        <.sample_meter
          sample_n={@kpi.sample_n}
          population_n={@kpi.population_n}
          definition={@kpi.definition}
        />
        <span :if={@kpi[:granularity]} class="al-num" title="The bucket size this reading came from">
          {granularity_label(@kpi[:granularity])}
        </span>
      </div>
    </div>
    """
  end

  @doc """
  An agent tile for the grid: the rolled-up status plus what drove it.

  The count badge matters. "Critical" alone invites a hunt; "Critical, 1 of 5"
  says how much of the agent is actually unwell.
  """
  attr :summary, :map, required: true
  attr :id, :string, required: true

  def agent_tile(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "group relative flex flex-col gap-4 rounded-xl border bg-al-panel p-5 transition",
        "hover:shadow-sm",
        tile_border(@summary.status)
      ]}
    >
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <.link
            navigate={"/agents/#{@summary.agent_id}"}
            class="text-base font-semibold text-al-ink hover:text-al-accent"
          >
            <span class="absolute inset-0" aria-hidden="true"></span>
            {@summary.agent_id}
          </.link>
          <p class="mt-0.5 text-xs text-al-ink-soft">
            {contributing_count(@summary)} contributing KPIs
          </p>
        </div>
        <.status_badge status={@summary.status} />
      </div>

      <dl class="flex flex-wrap gap-1.5">
        <div
          :for={{status, count} <- ordered_counts(@summary.counts)}
          :if={count > 0}
          class={[
            "inline-flex items-center gap-1 rounded-md border px-1.5 py-0.5 text-xs",
            status_classes(status)
          ]}
        >
          <dt class="sr-only">{status_label(status)}</dt>
          <span class={[status_icon(status), "size-3"]} aria-hidden="true" />
          <dd class="al-num font-medium">{count}</dd>
        </div>
      </dl>

      <ul class="flex flex-col gap-2">
        <li :for={kpi <- @summary.kpis} class="flex items-center gap-2">
          <span class="w-28 shrink-0 truncate text-xs text-al-ink-soft" title={kpi.definition.name}>
            {kpi.definition.name}
          </span>
          <.bullet_chart
            definition={kpi.definition}
            value={kpi.value}
            status={kpi.status}
            height={14}
            class="flex-1"
          />
          <span class="al-num w-20 shrink-0 text-right text-xs text-al-ink">
            {format_value(kpi.value, kpi.definition)}
          </span>
        </li>
      </ul>
    </div>
    """
  end

  @doc """
  Says plainly when the dashboard is showing generated data.

  Falling back to the mock keeps a misconfigured deploy running, which is
  right. Letting anyone mistake invented numbers for real telemetry would not
  be, so this is deliberately hard to miss.
  """
  attr :class, :string, default: nil

  def mock_notice(assigns) do
    ~H"""
    <span
      :if={AgentLens.LangSmith.Client.mock?()}
      id="mock-data-notice"
      class={[
        "inline-flex items-center gap-1.5 rounded-full border border-status-warning/40",
        "bg-status-warning-soft px-2.5 py-1 text-xs font-medium text-status-warning",
        @class
      ]}
      title="No LangSmith is configured, so these figures are generated. Set LANGSMITH_API_KEY to read real telemetry."
    >
      <span class="hero-beaker size-3.5" aria-hidden="true" /> Mock data
    </span>
    """
  end

  @doc """
  Says how old the numbers are.

  A dashboard that shows stale figures without saying so is making the same
  mistake as one that shows a confident zero.
  """
  attr :age_seconds, :integer, default: nil
  attr :class, :string, default: nil

  def freshness(assigns) do
    ~H"""
    <span class={["inline-flex items-center gap-1.5 text-xs text-al-ink-soft", @class]}>
      <span
        class={[
          "size-1.5 rounded-full",
          stale?(@age_seconds) && "bg-status-warning",
          !stale?(@age_seconds) && "bg-status-good"
        ]}
        aria-hidden="true"
      />
      <span class="al-num">{freshness_label(@age_seconds)}</span>
    </span>
    """
  end

  # ── Formatting ────────────────────────────────────────────────────────────

  @doc "Formats a value for display, in the unit its definition declares."
  @spec format_value(number() | nil, Definition.t()) :: String.t()
  def format_value(nil, _definition), do: "—"

  def format_value(value, %Definition{unit: :ratio}), do: percent(value)
  def format_value(value, %Definition{unit: :ms}), do: duration(value)
  def format_value(value, %Definition{unit: :usd}), do: "$" <> decimals(value, 4)
  def format_value(value, %Definition{unit: :count}), do: decimals(value, 0)
  def format_value(value, %Definition{unit: :score}), do: decimals(value, 3)

  defp percent(value), do: decimals(value * 100, 1) <> "%"

  defp duration(ms) when ms >= 1_000, do: decimals(ms / 1_000, 2) <> "s"
  defp duration(ms), do: decimals(ms, 0) <> "ms"

  defp decimals(value, places) do
    :erlang.float_to_binary(value * 1.0, decimals: places)
  end

  @doc "The unit's short label, or an empty string for units the number speaks for."
  @spec unit_label(atom()) :: String.t()
  def unit_label(:ratio), do: ""
  def unit_label(:ms), do: ""
  def unit_label(:usd), do: "USD"
  def unit_label(:count), do: "runs"
  def unit_label(:score), do: "score"

  @doc "Human label for a rollup grain."
  @spec granularity_label(atom() | nil) :: String.t()
  def granularity_label(:minute), do: "per minute"
  def granularity_label(:hour), do: "last hour"
  def granularity_label(:day), do: "last day"
  def granularity_label(_other), do: ""

  @doc "The word for a status."
  @spec status_label(atom()) :: String.t()
  def status_label(status), do: Map.get(@status_labels, status, "Unknown")

  @doc "The icon class for a status."
  @spec status_icon(atom()) :: String.t()
  def status_icon(status), do: Map.get(@status_icons, status, "hero-question-mark-circle")

  defp status_explanation(:good), do: "Within its healthy range"
  defp status_explanation(:warning), do: "Past its warning threshold"
  defp status_explanation(:critical), do: "Past its critical threshold"

  defp status_explanation(:unknown),
    do: "Not enough data to judge — this is not the same as healthy"

  defp status_classes(:good), do: "border-status-good/30 bg-status-good-soft text-status-good"

  defp status_classes(:warning),
    do: "border-status-warning/30 bg-status-warning-soft text-status-warning"

  defp status_classes(:critical),
    do: "border-status-critical/30 bg-status-critical-soft text-status-critical"

  defp status_classes(_unknown),
    do: "border-status-unknown/30 bg-status-unknown-soft text-status-unknown"

  defp tile_border(:critical), do: "border-status-critical/40"
  defp tile_border(:warning), do: "border-status-warning/40"
  defp tile_border(_other), do: "border-al-line"

  defp zone_class(:good), do: "fill-status-good/15"
  defp zone_class(:warning), do: "fill-status-warning/20"
  defp zone_class(:critical), do: "fill-status-critical/20"
  defp zone_class(_other), do: "fill-transparent"

  defp bar_class(:good), do: "fill-status-good"
  defp bar_class(:warning), do: "fill-status-warning"
  defp bar_class(:critical), do: "fill-status-critical"
  defp bar_class(_other), do: "fill-status-unknown"

  defp tick_class(:good), do: "stroke-status-good"
  defp tick_class(:warning), do: "stroke-status-warning"
  defp tick_class(:critical), do: "stroke-status-critical"
  defp tick_class(_other), do: "stroke-status-unknown"

  defp stroke_class(:good), do: "stroke-status-good"
  defp stroke_class(:warning), do: "stroke-status-warning"
  defp stroke_class(:critical), do: "stroke-status-critical"
  defp stroke_class(_other), do: "stroke-status-unknown"

  defp trend_class(:better), do: "text-status-good"
  defp trend_class(:worse), do: "text-status-critical"
  defp trend_class(_neutral), do: "text-al-ink-soft"

  defp trend_icon(delta) when delta > 0, do: "hero-arrow-trending-up"
  defp trend_icon(delta) when delta < 0, do: "hero-arrow-trending-down"
  defp trend_icon(_flat), do: "hero-minus-small"

  defp trend_description(:better), do: "improved"
  defp trend_description(:worse), do: "worsened"
  defp trend_description(_neutral), do: "changed"

  # Geometry is the delta; colour is what the delta means for this KPI.
  defp delta_meaning(_definition, nil), do: :neutral
  defp delta_meaning(_definition, delta) when delta == 0, do: :neutral

  defp delta_meaning(%Definition{direction: :higher_is_better}, delta),
    do: if(delta > 0, do: :better, else: :worse)

  defp delta_meaning(%Definition{direction: :lower_is_better}, delta),
    do: if(delta < 0, do: :better, else: :worse)

  # For a banded KPI, moving in either direction is only good if it moves
  # toward the band, which the delta alone cannot say.
  defp delta_meaning(%Definition{direction: :target_band}, _delta), do: :neutral

  defp format_delta(delta) when delta > 0, do: "+" <> decimals(delta, 1) <> "%"
  defp format_delta(delta), do: decimals(delta, 1) <> "%"

  defp sample_explanation(sample_n, population_n, definition) do
    if sample_n >= definition.min_sample_n do
      "#{sample_n} observations of #{population_n} runs"
    else
      "Only #{sample_n} observations — below the #{definition.min_sample_n} this KPI needs to be judged"
    end
  end

  defp stale?(nil), do: true
  defp stale?(age), do: age > 120

  defp freshness_label(nil), do: "not yet computed"
  defp freshness_label(age) when age < 5, do: "just now"
  defp freshness_label(age) when age < 90, do: "#{age}s ago"
  defp freshness_label(age), do: "#{div(age, 60)}m ago"

  defp contributing_count(summary) do
    Enum.count(summary.kpis, fn kpi ->
      kpi.definition && kpi.definition.health_contribution != :none
    end)
  end

  defp ordered_counts(counts) do
    for status <- [:critical, :warning, :unknown, :good], do: {status, Map.get(counts, status, 0)}
  end

  # ── Bullet geometry ───────────────────────────────────────────────────────

  # A declared range wins. Otherwise the domain is inferred from the thresholds
  # with headroom, so an unbounded KPI like latency still gets a sensible scale.
  defp bullet_domain(%Definition{range: {low, high}}, _value), do: {low * 1.0, high * 1.0}

  defp bullet_domain(
         %Definition{direction: :target_band, thresholds: %{warning: {low, high}}},
         value
       ) do
    pad = (high - low) * 0.35
    {min(low - pad, value || low), max(high + pad, value || high)}
  end

  defp bullet_domain(%Definition{thresholds: %{critical: critical}}, value) do
    high = max(critical * 1.35, (value || 0) * 1.1)
    {0.0, high * 1.0}
  end

  defp bullet_zones(%Definition{direction: :higher_is_better, thresholds: t}, low, high) do
    [
      %{status: :critical, from: 0, to: scale(t.critical, low, high)},
      %{status: :warning, from: scale(t.critical, low, high), to: scale(t.warning, low, high)},
      %{status: :good, from: scale(t.warning, low, high), to: 100}
    ]
  end

  defp bullet_zones(%Definition{direction: :lower_is_better, thresholds: t}, low, high) do
    [
      %{status: :good, from: 0, to: scale(t.warning, low, high)},
      %{status: :warning, from: scale(t.warning, low, high), to: scale(t.critical, low, high)},
      %{status: :critical, from: scale(t.critical, low, high), to: 100}
    ]
  end

  defp bullet_zones(%Definition{direction: :target_band, thresholds: t}, low, high) do
    %{good: {good_low, good_high}, warning: {warn_low, warn_high}} = t

    [
      %{status: :critical, from: 0, to: scale(warn_low, low, high)},
      %{status: :warning, from: scale(warn_low, low, high), to: scale(good_low, low, high)},
      %{status: :good, from: scale(good_low, low, high), to: scale(good_high, low, high)},
      %{status: :warning, from: scale(good_high, low, high), to: scale(warn_high, low, high)},
      %{status: :critical, from: scale(warn_high, low, high), to: 100}
    ]
  end

  defp scale(value, low, high), do: fraction(value, low, high) * 100

  defp fraction(nil, _low, _high), do: nil
  defp fraction(_value, low, high) when high == low, do: 0.5

  defp fraction(value, low, high) do
    ((value - low) / (high - low)) |> max(0.0) |> min(1.0)
  end

  defp bullet_label(definition, nil, _status),
    do: "#{definition.name}: no reading"

  defp bullet_label(definition, value, status) do
    "#{definition.name}: #{format_value(value, definition)}, #{status_label(status)}"
  end

  defp sparkline_path([]), do: nil
  defp sparkline_path([_single]), do: nil

  defp sparkline_path(points) do
    values = Enum.map(points, & &1.value)
    {low, high} = Enum.min_max(values)
    span = if high == low, do: 1.0, else: high - low
    last = length(points) - 1

    points
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {point, index} ->
      x = index / last * 100
      y = 30 - (point.value - low) / span * 28 - 1
      "#{if index == 0, do: "M", else: "L"}#{Float.round(x, 2)},#{Float.round(y, 2)}"
    end)
  end
end
