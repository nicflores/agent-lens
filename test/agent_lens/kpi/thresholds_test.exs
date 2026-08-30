defmodule AgentLens.Kpi.ThresholdsTest do
  use ExUnit.Case, async: true

  alias AgentLens.Kpi.Thresholds

  doctest Thresholds

  describe "validate/2 for :higher_is_better" do
    test "accepts thresholds where critical is below warning" do
      assert {:ok, %{warning: 0.95, critical: 0.9}} =
               Thresholds.validate(:higher_is_better, %{warning: 0.95, critical: 0.9})
    end

    test "rejects thresholds where critical is above warning" do
      assert {:error, message} =
               Thresholds.validate(:higher_is_better, %{warning: 0.9, critical: 0.95})

      assert message =~ "critical"
    end

    test "rejects a missing key" do
      assert {:error, _} = Thresholds.validate(:higher_is_better, %{warning: 0.95})
    end

    test "rejects a target_band shape" do
      assert {:error, _} =
               Thresholds.validate(:higher_is_better, %{good: {0.1, 0.2}, warning: {0.0, 0.3}})
    end
  end

  describe "validate/2 for :lower_is_better" do
    test "accepts thresholds where warning is below critical" do
      assert {:ok, %{warning: 100.0, critical: 500.0}} =
               Thresholds.validate(:lower_is_better, %{warning: 100.0, critical: 500.0})
    end

    test "rejects thresholds where warning is above critical" do
      assert {:error, _} =
               Thresholds.validate(:lower_is_better, %{warning: 500.0, critical: 100.0})
    end
  end

  describe "validate/2 for :target_band" do
    test "accepts a good band nested inside the warning band" do
      bands = %{good: {0.3, 0.7}, warning: {0.1, 0.9}}
      assert {:ok, ^bands} = Thresholds.validate(:target_band, bands)
    end

    test "rejects a good band wider than the warning band" do
      assert {:error, message} =
               Thresholds.validate(:target_band, %{good: {0.1, 0.9}, warning: {0.3, 0.7}})

      assert message =~ "nested"
    end

    test "rejects an inverted band" do
      assert {:error, _} =
               Thresholds.validate(:target_band, %{good: {0.7, 0.3}, warning: {0.1, 0.9}})
    end

    test "rejects a monotonic shape" do
      assert {:error, _} = Thresholds.validate(:target_band, %{warning: 0.9, critical: 0.95})
    end
  end

  describe "classify/3 for :higher_is_better" do
    setup do
      %{thresholds: %{warning: 0.95, critical: 0.9}}
    end

    test "is good at or above the warning threshold", %{thresholds: t} do
      assert :good = Thresholds.classify(:higher_is_better, t, 0.99)
      assert :good = Thresholds.classify(:higher_is_better, t, 0.95)
    end

    test "is warning between the two thresholds", %{thresholds: t} do
      assert :warning = Thresholds.classify(:higher_is_better, t, 0.94)
      assert :warning = Thresholds.classify(:higher_is_better, t, 0.9)
    end

    test "is critical below the critical threshold", %{thresholds: t} do
      assert :critical = Thresholds.classify(:higher_is_better, t, 0.89)
      assert :critical = Thresholds.classify(:higher_is_better, t, 0.0)
    end
  end

  describe "classify/3 for :lower_is_better" do
    setup do
      %{thresholds: %{warning: 100.0, critical: 500.0}}
    end

    test "is good at or below the warning threshold", %{thresholds: t} do
      assert :good = Thresholds.classify(:lower_is_better, t, 10.0)
      assert :good = Thresholds.classify(:lower_is_better, t, 100.0)
    end

    test "is warning between the two thresholds", %{thresholds: t} do
      assert :warning = Thresholds.classify(:lower_is_better, t, 101.0)
      assert :warning = Thresholds.classify(:lower_is_better, t, 500.0)
    end

    test "is critical above the critical threshold", %{thresholds: t} do
      assert :critical = Thresholds.classify(:lower_is_better, t, 501.0)
    end
  end

  describe "classify/3 for :target_band" do
    setup do
      %{thresholds: %{good: {0.3, 0.7}, warning: {0.1, 0.9}}}
    end

    test "is good inside the good band", %{thresholds: t} do
      assert :good = Thresholds.classify(:target_band, t, 0.5)
      assert :good = Thresholds.classify(:target_band, t, 0.3)
      assert :good = Thresholds.classify(:target_band, t, 0.7)
    end

    test "is warning between the good and warning band edges", %{thresholds: t} do
      assert :warning = Thresholds.classify(:target_band, t, 0.2)
      assert :warning = Thresholds.classify(:target_band, t, 0.8)
    end

    # This is the case a two-direction system gets wrong: a maximal value is a
    # failure for a banded KPI, not an excellent result.
    test "is critical at both extremes", %{thresholds: t} do
      assert :critical = Thresholds.classify(:target_band, t, 0.0)
      assert :critical = Thresholds.classify(:target_band, t, 1.0)
    end
  end
end
