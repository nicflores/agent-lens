defmodule AgentLens.Kpis.Drift do
  @moduledoc """
  Population Stability Index of the latency distribution against a rolling
  baseline.

  This is the KPI that turns the dashboard from a status board into something
  that tells you a model update quietly degraded an agent. Absolute thresholds
  catch an agent that is broken; drift catches one that is getting worse while
  still nominally passing.

  Derived: computed on bucket close from another KPI's series rather than from
  runs, which is why it declares `depends_on/0` instead of `requires/0`.

  PSI is read on the conventional scale: below 0.1 is no meaningful shift,
  0.1 to 0.25 is a moderate one, and above 0.25 is significant.
  """

  use AgentLens.Kpi

  alias AgentLens.Kpi.Definition
  alias AgentLens.Kpi.Input

  @source :latency_p95
  @max_bins 10
  @min_observations 30

  # Target observations per bin. PSI is biased upward when bins are thinly
  # populated: with ten bins and fifty points, ordinary sampling noise moves
  # each bin by a fifth of its mass and reads as drift. Sizing the bins to the
  # sample keeps a quiet window quiet, which matters more than resolution —
  # a drift KPI that cries wolf is one people learn to ignore.
  @per_bin 20

  # Floor for an empty bin, so a bin present on one side only yields a large
  # finite contribution rather than an infinity.
  @epsilon 1.0e-6

  @impl true
  def definition do
    %Definition{
      slug: :latency_drift,
      name: "Latency Drift (PSI)",
      short_description: "How far the latency distribution has moved from its baseline.",
      methodology: """
      The baseline distribution is split into quantile bins — at most
      #{@max_bins}, and fewer when the sample is small, targeting about
      #{@per_bin} observations per bin. Current and baseline populations are
      binned identically, and the Population Stability Index is the sum over
      bins of `(actual - expected) * ln(actual / expected)`.

      Requires at least #{@min_observations} observations on both sides; below
      that the statistic is noise, and the KPI reports no value rather than a
      misleading one.
      """,
      kind: :derived,
      unit: :score,
      range: nil,
      direction: :lower_is_better,
      aggregation: :mean,
      thresholds: %{warning: 0.1, critical: 0.25},
      health_contribution: :normal,
      min_sample_n: 0
    }
  end

  @impl true
  def depends_on, do: [@source]

  @impl true
  def compute(%Input.Window{} = window) do
    current = Input.Window.current(window, @source)
    baseline = Input.Window.baseline(window, @source)

    bins = bin_count(current, baseline)

    with :ok <- check_size(current),
         :ok <- check_size(baseline),
         {:ok, edges} <- bin_edges(baseline, bins) do
      {:ok, psi(current, baseline, edges, bins)}
    end
  end

  defp check_size(values) when length(values) < @min_observations, do: :skip
  defp check_size(_values), do: :ok

  # Sized by the smaller population, since that is the one whose bins would be
  # thin.
  defp bin_count(current, baseline) do
    min(length(current), length(baseline))
    |> div(@per_bin)
    |> max(2)
    |> min(@max_bins)
  end

  defp bin_edges(baseline, bins) do
    sorted = Enum.sort(baseline)

    if List.first(sorted) == List.last(sorted) do
      # A constant baseline has no spread to partition, so every value would
      # land in one bin and PSI would be meaningless.
      :skip
    else
      {:ok, Enum.map(1..(bins - 1), &quantile(sorted, &1 / bins))}
    end
  end

  defp quantile(sorted, fraction) do
    count = length(sorted)
    index = fraction |> Kernel.*(count) |> round() |> Kernel.-(1)
    Enum.at(sorted, index |> max(0) |> min(count - 1))
  end

  defp psi(current, baseline, edges, bins) do
    actual = proportions(current, edges, bins)
    expected = proportions(baseline, edges, bins)

    actual
    |> Enum.zip(expected)
    |> Enum.map(fn {a, e} -> (a - e) * :math.log(a / e) end)
    |> Enum.sum()
  end

  defp proportions(values, edges, bins) do
    total = length(values)

    counts =
      Enum.reduce(values, %{}, fn value, acc ->
        Map.update(acc, bin_index(value, edges), 1, &(&1 + 1))
      end)

    Enum.map(0..(bins - 1), fn bin ->
      max(Map.get(counts, bin, 0) / total, @epsilon)
    end)
  end

  defp bin_index(value, edges), do: Enum.count(edges, &(value > &1))
end
