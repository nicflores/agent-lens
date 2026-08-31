defmodule AgentLens.Kpi.Input.Window do
  @moduledoc """
  A closed rollup bucket, plus the series a derived KPI needs to compare.

  `current` and `baseline` are keyed by KPI slug, carrying the values named by
  the KPI's `depends_on/0`. Drift compares the two.

  The baseline holds only periods in which the source KPI was healthy, and
  `baseline_excluded` counts what was left out. See
  `AgentLens.Rollup.Derived` for why a reference window has to be built that
  way.
  """

  defstruct [
    :agent_id,
    :bucket_start,
    :bucket_end,
    :granularity,
    current: %{},
    baseline: %{},
    baseline_excluded: %{}
  ]

  @type series :: %{optional(atom()) => [number()]}

  @type t :: %__MODULE__{
          agent_id: String.t() | nil,
          bucket_start: DateTime.t() | nil,
          bucket_end: DateTime.t() | nil,
          granularity: atom() | nil,
          current: series(),
          baseline: series(),
          baseline_excluded: %{optional(atom()) => non_neg_integer()}
        }

  @doc "The values observed for `slug` in this bucket, or `[]` if there were none."
  @spec current(t(), atom()) :: [number()]
  def current(%__MODULE__{current: series}, slug), do: Map.get(series, slug, [])

  @doc "The healthy values observed for `slug` across the baseline window, or `[]`."
  @spec baseline(t(), atom()) :: [number()]
  def baseline(%__MODULE__{baseline: series}, slug), do: Map.get(series, slug, [])

  @doc """
  How many baseline buckets were dropped for `slug` as unhealthy.

  Useful for explaining a reading: a baseline that discarded most of its window
  is a different claim from one that discarded none.
  """
  @spec baseline_excluded(t(), atom()) :: non_neg_integer()
  def baseline_excluded(%__MODULE__{baseline_excluded: counts}, slug),
    do: Map.get(counts, slug, 0)
end
