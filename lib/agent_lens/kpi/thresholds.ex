defmodule AgentLens.Kpi.Thresholds do
  @moduledoc """
  Threshold shapes and the pure classification of a value against them.

  A KPI's threshold shape is determined by its `direction`, and the two are
  validated together — a monotonic threshold pair is meaningless for a banded
  KPI and vice versa.

  ## Why three directions rather than two

  `:target_band` is not a convenience. An agent scoring maximum positive
  sentiment on every single response is broken, not excellent; a refusal rate
  near zero means the guardrails are not engaging, while a high one means the
  agent has over-blocked. A two-direction system renders exactly those KPIs
  green at the values that should worry you most.
  """

  @typedoc "Which way is good."
  @type direction :: :higher_is_better | :lower_is_better | :target_band

  @typedoc "An inclusive `{lower, upper}` interval."
  @type band :: {number(), number()}

  @typedoc """
  Monotonic directions carry a warning/critical pair; `:target_band` carries a
  good band nested inside a warning band.
  """
  @type t :: %{warning: number(), critical: number()} | %{good: band(), warning: band()}

  @typedoc "The classification of a value. Excludes `:unknown`, which is not a threshold outcome."
  @type status :: :good | :warning | :critical

  @doc """
  Validates that a threshold shape is coherent for the given direction.

  ## Examples

      iex> Thresholds.validate(:higher_is_better, %{warning: 0.95, critical: 0.9})
      {:ok, %{warning: 0.95, critical: 0.9}}

      iex> {:error, message} = Thresholds.validate(:lower_is_better, %{warning: 500, critical: 100})
      iex> message =~ "warning"
      true

  """
  @spec validate(direction(), term()) :: {:ok, t()} | {:error, String.t()}
  def validate(:higher_is_better, %{warning: warning, critical: critical} = thresholds)
      when is_number(warning) and is_number(critical) do
    if critical < warning do
      {:ok, thresholds}
    else
      {:error,
       "for :higher_is_better the critical threshold must be below the warning threshold, " <>
         "got critical=#{critical} warning=#{warning}"}
    end
  end

  def validate(:lower_is_better, %{warning: warning, critical: critical} = thresholds)
      when is_number(warning) and is_number(critical) do
    if warning < critical do
      {:ok, thresholds}
    else
      {:error,
       "for :lower_is_better the warning threshold must be below the critical threshold, " <>
         "got warning=#{warning} critical=#{critical}"}
    end
  end

  def validate(:target_band, %{good: {glo, ghi}, warning: {wlo, whi}} = thresholds)
      when is_number(glo) and is_number(ghi) and is_number(wlo) and is_number(whi) do
    cond do
      glo > ghi -> {:error, "the good band is inverted, got {#{glo}, #{ghi}}"}
      wlo > whi -> {:error, "the warning band is inverted, got {#{wlo}, #{whi}}"}
      wlo > glo or ghi > whi -> {:error, "the good band must be nested inside the warning band"}
      true -> {:ok, thresholds}
    end
  end

  def validate(direction, thresholds)
      when direction in [:higher_is_better, :lower_is_better, :target_band] do
    {:error, "thresholds #{inspect(thresholds)} do not match the shape required by #{direction}"}
  end

  def validate(direction, _thresholds) do
    {:error, "unknown direction #{inspect(direction)}"}
  end

  @doc """
  Classifies a value against validated thresholds.

  Boundaries are inclusive on the healthier side: a value sitting exactly on the
  warning threshold is still `:good`.

  ## Examples

      iex> Thresholds.classify(:higher_is_better, %{warning: 0.95, critical: 0.9}, 0.92)
      :warning

      iex> Thresholds.classify(:target_band, %{good: {0.3, 0.7}, warning: {0.1, 0.9}}, 1.0)
      :critical

  """
  @spec classify(direction(), t(), number()) :: status()
  def classify(:higher_is_better, %{warning: warning, critical: critical}, value)
      when is_number(value) do
    cond do
      value >= warning -> :good
      value >= critical -> :warning
      true -> :critical
    end
  end

  def classify(:lower_is_better, %{warning: warning, critical: critical}, value)
      when is_number(value) do
    cond do
      value <= warning -> :good
      value <= critical -> :warning
      true -> :critical
    end
  end

  def classify(:target_band, %{good: {glo, ghi}, warning: {wlo, whi}}, value)
      when is_number(value) do
    cond do
      value >= glo and value <= ghi -> :good
      value >= wlo and value <= whi -> :warning
      true -> :critical
    end
  end
end
