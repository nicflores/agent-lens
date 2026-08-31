defmodule AgentLens.Kpi.Input.Window do
  @moduledoc """
  A closed rollup bucket, plus the series a derived KPI needs to compare.

  `current` and `baseline` are keyed by KPI slug, carrying the values named by
  the KPI's `depends_on/0`. Drift compares the two.
  """

  defstruct [
    :agent_id,
    :bucket_start,
    :bucket_end,
    :granularity,
    current: %{},
    baseline: %{}
  ]

  @type series :: %{optional(atom()) => [number()]}

  @type t :: %__MODULE__{
          agent_id: String.t() | nil,
          bucket_start: DateTime.t() | nil,
          bucket_end: DateTime.t() | nil,
          granularity: atom() | nil,
          current: series(),
          baseline: series()
        }

  @doc "The values observed for `slug` in this bucket, or `[]` if there were none."
  @spec current(t(), atom()) :: [number()]
  def current(%__MODULE__{current: series}, slug), do: Map.get(series, slug, [])

  @doc "The values observed for `slug` across the baseline window, or `[]`."
  @spec baseline(t(), atom()) :: [number()]
  def baseline(%__MODULE__{baseline: series}, slug), do: Map.get(series, slug, [])
end
