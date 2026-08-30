defmodule AgentLens.Kpis.DriftTest do
  use ExUnit.Case, async: true

  alias AgentLens.Kpi.Input
  alias AgentLens.Kpis.Drift

  defp window(current, baseline) do
    %Input.Window{
      agent_id: "ws-support",
      bucket_start: ~U[2026-08-30 00:00:00Z],
      bucket_end: ~U[2026-08-31 00:00:00Z],
      granularity: :day,
      current: %{latency_p95: current},
      baseline: %{latency_p95: baseline}
    }
  end

  defp sample(n, offset), do: Enum.map(1..n, fn i -> i / n + offset end)

  describe "depends_on/0" do
    test "declares the KPI whose distribution it compares" do
      assert [:latency_p95] = Drift.depends_on()
    end
  end

  describe "compute/1" do
    test "is near zero when the distributions are identical" do
      values = sample(200, 0)

      assert {:ok, psi} = Drift.compute(window(values, values))
      assert psi < 0.01
    end

    test "grows as the distribution shifts away from the baseline" do
      baseline = sample(200, 0)

      {:ok, small} = Drift.compute(window(sample(200, 0.1), baseline))
      {:ok, large} = Drift.compute(window(sample(200, 2.0), baseline))

      assert small < large
    end

    test "reports a wholly displaced distribution as significant drift" do
      # Standard PSI reading: above 0.25 is a significant population shift.
      {:ok, psi} = Drift.compute(window(sample(200, 100.0), sample(200, 0)))
      assert psi > 0.25
    end

    # Every current observation lands in one bin, leaving the rest empty. The
    # epsilon floor is what keeps ln(0) — and so the whole statistic — finite.
    test "returns a large but finite number when bins are empty on one side" do
      {:ok, psi} = Drift.compute(window(List.duplicate(1.0, 200), sample(200, 0)))

      assert is_float(psi)
      assert psi > 0.25, "a fully concentrated distribution is significant drift"
      assert psi < 1.0e6, "PSI must stay finite when a bin is empty"
    end
  end

  # Drift computed from a handful of points is noise presented as signal. It is
  # a skip, so the KPI renders grey rather than alarming on nothing.
  describe "compute/1 refuses to guess" do
    test "skips when the current window has too few observations" do
      assert :skip = Drift.compute(window([1.0, 2.0], sample(200, 0)))
    end

    test "skips when there is no baseline to compare against" do
      assert :skip = Drift.compute(window(sample(200, 0), []))
    end

    test "skips when the baseline is too small to bin" do
      assert :skip = Drift.compute(window(sample(200, 0), [1.0, 2.0, 3.0]))
    end

    test "skips when the baseline is entirely constant, which has no spread to bin" do
      assert :skip = Drift.compute(window(sample(200, 0), List.duplicate(5.0, 200)))
    end
  end
end
