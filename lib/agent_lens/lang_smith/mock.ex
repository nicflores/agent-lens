defmodule AgentLens.LangSmith.Mock do
  @moduledoc """
  A deterministic stand-in for LangSmith, generating ~90 days of plausible
  history.

  ## Why it is not random noise

  A mock that emits uniform noise makes a dashboard look alive while showing
  nothing. Every chart is flat, no threshold is ever crossed, and drift
  detection has nothing to detect — so none of it gets exercised until real
  data arrives, which is exactly when you want it already working.

  This one injects specific, findable events at known times:

    * a **latency spike** over a few days, which recovers
    * a **toxicity regression** beginning at a simulated model version change,
      which does not recover
    * a slow **cost creep** across the whole window

  `anomalies/0` exposes those windows so tests and drift fixtures can refer to
  them symbolically instead of by magic numbers.

  ## Determinism

  There is no process state and no `:rand`. Every value derives from a hash of
  `{workspace, index, field}`, so the same window returns byte-identical data on
  every call, in every process, forever. That is what makes it usable as a
  fixture set rather than merely as filler.
  """

  @behaviour AgentLens.LangSmith.Client

  @backfill_days 90
  @interval_seconds 360
  @models %{before: "claude-sonnet-4-5", after: "claude-sonnet-5"}
  @feedback_keys ["kpi.toxicity", "kpi.polarity"]

  # Judged KPIs are sampled, so only a fraction of runs carry a score.
  @feedback_sample_rate 0.2

  @doc """
  The injected anomalies, as day offsets from `epoch/1`.

  Exposed so tests and drift fixtures name these events rather than hardcoding
  the timestamps they happen to fall on.
  """
  @spec anomalies() :: map()
  def anomalies do
    %{
      latency_spike: %{from_day: 34, to_day: 37, factor: 6.0},
      toxicity_regression: %{
        from_day: 62,
        model_before: @models.before,
        model_after: @models.after
      },
      cost_creep: %{per_day: 0.9 / @backfill_days}
    }
  end

  @doc "The start of the generated history: midnight, `#{@backfill_days}` days back."
  @spec epoch(DateTime.t()) :: DateTime.t()
  def epoch(now \\ DateTime.utc_now()) do
    now
    |> DateTime.add(-@backfill_days, :day)
    |> Map.merge(%{hour: 0, minute: 0, second: 0, microsecond: {0, 6}})
  end

  @impl AgentLens.LangSmith.Client
  def list_runs(workspace, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    limit = Keyword.get(opts, :limit, 100)
    since = Keyword.get(opts, :since, epoch(now))

    epoch = epoch(now)
    first = first_index_after(epoch, since)
    last = last_index(epoch, now)

    indexes = index_range(first, last, limit)
    items = Enum.map(indexes, &build_run(workspace, &1, epoch))

    {:ok, %{items: items, has_more?: List.last(indexes, first - 1) < last}}
  end

  @impl AgentLens.LangSmith.Client
  def list_feedback(workspace, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    limit = Keyword.get(opts, :limit, 100)
    since = Keyword.get(opts, :since, epoch(now))

    epoch = epoch(now)
    first = first_index_after(epoch, since)
    last = last_index(epoch, now)

    {items, exhausted?} = collect_feedback(workspace, first, last, epoch, limit)

    {:ok, %{items: items, has_more?: not exhausted?}}
  end

  # Walks forward from `first` gathering feedback for sampled runs only, so the
  # sampling rate is honoured without generating every run's worth of scores.
  #
  # The accumulator stays in ascending order throughout. Prepending chunks and
  # reversing at the end is tempting but wrong here: each run contributes
  # several scores sharing one timestamp, so a reversed page still *looks*
  # sorted by `created_at` while actually being newest-run-first, and the
  # poller would advance its cursor past feedback it never returned.
  defp collect_feedback(workspace, first, last, epoch, limit) do
    {items, exhausted?} =
      Enum.reduce_while(first..max(first, last)//1, {[], true}, fn index, {acc, _} ->
        cond do
          length(acc) >= limit ->
            {:halt, {acc, false}}

          index > last ->
            {:halt, {acc, true}}

          sampled?(workspace, index) ->
            {:cont, {acc ++ feedback_for(workspace, index, epoch), true}}

          true ->
            {:cont, {acc, true}}
        end
      end)

    {Enum.take(items, limit), exhausted?}
  end

  defp index_range(first, last, _limit) when first > last, do: []
  defp index_range(first, last, limit), do: Enum.to_list(first..min(last, first + limit - 1)//1)

  defp first_index_after(epoch, since) do
    seconds = DateTime.diff(since, epoch)
    max(0, floor(seconds / @interval_seconds) + 1)
  end

  defp last_index(epoch, now), do: max(-1, floor(DateTime.diff(now, epoch) / @interval_seconds))

  defp started_at(epoch, index), do: DateTime.add(epoch, index * @interval_seconds)

  defp build_run(workspace, index, epoch) do
    start_time = started_at(epoch, index)
    day = day_offset(epoch, start_time)

    latency = latency_ms(workspace, index, day)
    failed? = unit(workspace, index, :failure) < failure_rate(day)
    prompt_tokens = 400 + round(unit(workspace, index, :prompt) * 2_200)
    completion_tokens = 80 + round(unit(workspace, index, :completion) * 900)

    %{
      "id" => run_id(workspace, index),
      "trace_id" => run_id(workspace, index),
      "parent_run_id" => nil,
      "name" => "agent_turn",
      "run_type" => Enum.at(["chain", "llm", "tool"], rem(index, 3)),
      "start_time" => start_time,
      "end_time" => DateTime.add(start_time, latency, :millisecond),
      "latency_ms" => latency,
      "status" => if(failed?, do: "error", else: "success"),
      "error" => if(failed?, do: "upstream tool timed out", else: nil),
      "prompt_tokens" => prompt_tokens,
      "completion_tokens" => completion_tokens,
      "total_cost" => cost(prompt_tokens, completion_tokens, day),
      "inputs" => %{"question" => "sample question #{index}"},
      "outputs" => %{"text" => "sample answer #{index}"},
      "extra" => %{
        "metadata" => %{
          "model" => model_for(day),
          "workspace" => workspace,
          "cache_hit" => unit(workspace, index, :cache) < 0.35
        }
      },
      "tags" => ["mock"]
    }
  end

  defp feedback_for(workspace, index, epoch) do
    day = day_offset(epoch, started_at(epoch, index))
    created = DateTime.add(started_at(epoch, index), 45)

    Enum.map(@feedback_keys, fn key ->
      %{
        "id" => "#{run_id(workspace, index)}-#{key}",
        "run_id" => run_id(workspace, index),
        "key" => key,
        "score" => score_for(key, workspace, index, day),
        "comment" => nil,
        "created_at" => created,
        "feedback_source" => %{"type" => "model"}
      }
    end)
  end

  defp score_for("kpi.toxicity", workspace, index, day) do
    %{toxicity_regression: regression} = anomalies()
    base = if day >= regression.from_day, do: 0.14, else: 0.02

    clamp(base * (0.4 + unit(workspace, index, :toxicity) * 1.6), 0.0, 1.0)
  end

  defp score_for("kpi.polarity", workspace, index, _day) do
    clamp(0.15 + normal(workspace, index, :polarity) * 0.45, -1.0, 1.0)
  end

  defp latency_ms(workspace, index, day) do
    %{latency_spike: spike} = anomalies()

    base = 900 + round(normal(workspace, index, :latency) * 350)

    multiplier =
      if day >= spike.from_day and day <= spike.to_day, do: spike.factor, else: 1.0

    max(60, round(base * multiplier))
  end

  # Errors rise during the latency spike: the same upstream problem shows up in
  # both, which is what makes the injected incident coherent rather than two
  # unrelated wobbles.
  defp failure_rate(day) do
    %{latency_spike: spike} = anomalies()
    if day >= spike.from_day and day <= spike.to_day, do: 0.22, else: 0.03
  end

  defp cost(prompt_tokens, completion_tokens, day) do
    %{cost_creep: creep} = anomalies()
    base = prompt_tokens * 3.0e-6 + completion_tokens * 1.5e-5

    Float.round(base * (1.0 + creep.per_day * day), 8)
  end

  defp model_for(day) do
    %{toxicity_regression: regression} = anomalies()
    if day >= regression.from_day, do: regression.model_after, else: regression.model_before
  end

  defp sampled?(workspace, index), do: unit(workspace, index, :sample) < @feedback_sample_rate

  defp day_offset(epoch, at), do: div(DateTime.diff(at, epoch), 86_400)

  defp run_id(workspace, index) do
    "#{workspace}-run-#{String.pad_leading(Integer.to_string(index), 7, "0")}"
  end

  # A deterministic value in [0, 1) — no :rand, no process state, so the same
  # window is byte-identical on every call.
  defp unit(workspace, index, field) do
    :erlang.phash2({workspace, index, field}, 1_000_000) / 1_000_000
  end

  # Roughly bell-shaped in [-1.5, 1.5) by summing three uniforms.
  defp normal(workspace, index, field) do
    unit(workspace, index, {field, 1}) + unit(workspace, index, {field, 2}) +
      unit(workspace, index, {field, 3}) - 1.5
  end

  defp clamp(value, low, high), do: value |> max(low) |> min(high)
end
