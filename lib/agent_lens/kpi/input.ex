defmodule AgentLens.Kpi.Input do
  @moduledoc """
  The inputs a KPI computes from.

  The three kinds of KPI arrive from genuinely different places, so `compute/1`
  is given a tagged struct and each module pattern-matches the one it expects:

    * `Input.Run` — one run, for `:extracted` and `:imported` KPIs, computed on
      run arrival.
    * `Input.Window` — a closed bucket plus the series it depends on, for
      `:derived` KPIs, computed on bucket close.

  This is the seam that lets both schedules share a single callback. Without it,
  a derived KPI's baseline wiring would have to live in the rollup module, which
  is exactly the leak the KPI behaviour exists to prevent.
  """

  @typedoc "Either shape of KPI input."
  @type t :: __MODULE__.Run.t() | __MODULE__.Window.t()

  defmodule Run do
    @moduledoc """
    A single LangSmith run: the flattened columns, the retained `jsonb` payload,
    and any feedback scores attached to it.
    """

    alias AgentLens.Kpi.FieldManifest

    defstruct [
      :langsmith_run_id,
      :agent_id,
      :trace_id,
      :parent_run_id,
      :name,
      :run_type,
      :start_time,
      :end_time,
      :latency_ms,
      :status,
      :error,
      :model,
      :prompt_tokens,
      :completion_tokens,
      :cost_usd,
      payload: %{},
      feedback: %{}
    ]

    @type t :: %__MODULE__{
            langsmith_run_id: String.t() | nil,
            agent_id: String.t() | nil,
            trace_id: String.t() | nil,
            parent_run_id: String.t() | nil,
            name: String.t() | nil,
            run_type: String.t() | nil,
            start_time: DateTime.t() | nil,
            end_time: DateTime.t() | nil,
            latency_ms: non_neg_integer() | nil,
            status: String.t() | nil,
            error: String.t() | nil,
            model: String.t() | nil,
            prompt_tokens: non_neg_integer() | nil,
            completion_tokens: non_neg_integer() | nil,
            cost_usd: float() | nil,
            payload: map(),
            feedback: %{optional(String.t()) => number()}
          }

    @doc """
    Reads a field using the same path vocabulary `c:AgentLens.Kpi.requires/0`
    declares and `AgentLens.Kpi.FieldManifest` validates.

    Returns `:error` rather than `nil` for anything absent, so a KPI has to
    decide explicitly what a missing value means instead of silently doing
    arithmetic on `nil`.
    """
    @spec fetch(t(), FieldManifest.path()) :: {:ok, term()} | :error
    def fetch(%__MODULE__{} = run, column) when is_atom(column) do
      case Map.fetch(run, column) do
        {:ok, nil} -> :error
        {:ok, value} -> {:ok, value}
        :error -> :error
      end
    end

    def fetch(%__MODULE__{payload: payload}, {:payload, segments}) when is_list(segments) do
      dig(payload, segments)
    end

    def fetch(%__MODULE__{feedback: feedback}, {:feedback, key}) when is_binary(key) do
      case Map.fetch(feedback, key) do
        {:ok, nil} -> :error
        {:ok, value} -> {:ok, value}
        :error -> :error
      end
    end

    defp dig(value, []), do: {:ok, value}

    defp dig(map, [segment | rest]) when is_map(map) do
      case Map.fetch(map, segment) do
        {:ok, nil} -> :error
        {:ok, value} -> dig(value, rest)
        :error -> :error
      end
    end

    defp dig(_not_a_map, _segments), do: :error
  end

  defmodule Window do
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
end
