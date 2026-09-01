defmodule AgentLens.Kpi.Status do
  @moduledoc """
  Pure status evaluation: turning a KPI value into a health signal.

  There are **four** states, not three. `:unknown` covers an absent value, a
  sample too small to trust, and data too old to mean anything. It exists
  because a KPI that is not really being measured must render grey rather than
  green — missing data that looks healthy is the most dangerous thing a
  dashboard can show.

  Nothing here touches the database, the clock (except through an injectable
  `:now`), or any process. Status is a function of a definition and a value.
  """

  alias AgentLens.Kpi.Definition
  alias AgentLens.Kpi.Thresholds

  @typedoc "A KPI's health state."
  @type t :: :good | :warning | :critical | :unknown

  @doc """
  Evaluates a value against a definition's thresholds.

  Returns `:unknown` — never a threshold classification — when the value is
  absent, the sample is below `min_sample_n`, or the observation is older than
  the caller's staleness window.

  ## Options

    * `:sample_n` — how many observations back this value. Required whenever
      the definition sets a non-zero `min_sample_n`; a missing count cannot be
      assumed adequate.
    * `:observed_at` and `:max_age` — staleness window in seconds. Both must be
      supplied for the check to apply.
    * `:now` — injectable current time, defaulting to `DateTime.utc_now/0`.

  """
  @spec evaluate(Definition.t(), number() | nil, keyword()) :: t()
  def evaluate(definition, value, opts \\ [])

  def evaluate(%Definition{}, nil, _opts), do: :unknown

  def evaluate(%Definition{} = definition, value, opts) when is_number(value) do
    cond do
      not adequate_sample?(definition, Keyword.get(opts, :sample_n)) -> :unknown
      stale?(opts) -> :unknown
      true -> Thresholds.classify(definition.direction, definition.thresholds, value)
    end
  end

  defp adequate_sample?(%Definition{min_sample_n: 0}, nil), do: true
  defp adequate_sample?(%Definition{}, nil), do: false

  defp adequate_sample?(%Definition{min_sample_n: minimum}, sample_n)
       when is_integer(sample_n),
       do: sample_n >= minimum

  defp stale?(opts) do
    with {:ok, observed_at} <- Keyword.fetch(opts, :observed_at),
         {:ok, max_age} <- Keyword.fetch(opts, :max_age) do
      now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
      DateTime.diff(now, observed_at, :second) > max_age
    else
      :error -> false
    end
  end

  @doc """
  Damps status transitions so a KPI oscillating around a threshold does not
  flicker.

  `recent` is the raw evaluated status per bucket, most recent first. The status
  only flips once the newest `consecutive_required` buckets agree; otherwise the
  previous status holds. A KPI that flickers trains everyone to ignore it, which
  is worse than being slightly late.
  """
  @spec apply_hysteresis(t() | nil, [t()], pos_integer()) :: t() | nil
  def apply_hysteresis(previous, recent, consecutive_required)

  def apply_hysteresis(previous, [], _consecutive_required), do: previous

  def apply_hysteresis(nil, [latest | _rest], _consecutive_required), do: latest

  def apply_hysteresis(previous, recent, consecutive_required)
      when is_integer(consecutive_required) and consecutive_required > 0 do
    window = Enum.take(recent, consecutive_required)

    if length(window) == consecutive_required and uniform?(window) do
      hd(window)
    else
      previous
    end
  end

  defp uniform?([first | rest]), do: Enum.all?(rest, &(&1 == first))

  @doc """
  Folds hysteresis over a whole series, oldest first, returning the settled
  status.

  This is what the read path actually needs. It does not remember a previous
  status between requests — it has a list of buckets — so the damping is
  replayed from the start of the window each time. That also makes the result
  deterministic: the same buckets always settle to the same status, with no
  hidden state to drift out of step.
  """
  @spec stabilize([t()], pos_integer()) :: t() | nil
  def stabilize(statuses, consecutive_required) do
    statuses
    |> Enum.reduce({nil, []}, fn status, {settled, seen} ->
      seen = [status | seen]
      {apply_hysteresis(settled, seen, consecutive_required), seen}
    end)
    |> elem(0)
  end

  @doc """
  Rolls per-KPI statuses up into a single agent-level status.

  Takes the worst status among KPIs that contribute to health. KPIs whose
  `health_contribution` is `:none` are excluded entirely — token consumption is
  informational, and must not be able to turn an otherwise healthy agent red.

  Severity orders `:unknown` above `:good` but below `:warning`: not knowing is
  worse than being fine, and not as bad as a confirmed problem.
  """
  @spec roll_up([{Definition.t(), t()}]) :: t()
  def roll_up(entries) do
    entries
    |> Enum.reject(fn {%Definition{health_contribution: contribution}, _status} ->
      contribution == :none
    end)
    |> Enum.map(fn {_definition, status} -> status end)
    |> worst()
  end

  defp worst([]), do: :unknown
  defp worst(statuses), do: Enum.max_by(statuses, &severity/1)

  defp severity(:good), do: 0
  defp severity(:unknown), do: 1
  defp severity(:warning), do: 2
  defp severity(:critical), do: 3
end
