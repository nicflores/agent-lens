defmodule AgentLensWeb.ChartConfig do
  @moduledoc """
  Builds the JSON payload the chart hook renders.

  Everything the chart knows about judgement comes from the KPI definition:
  the threshold bands are the definition's own thresholds, and the line colour
  is the current status. Nothing here is per-KPI code, so a new KPI charts
  correctly the moment it is registered.
  """

  alias AgentLens.Kpi.Definition

  @doc """
  Serialises a series and its definition into chart configuration.

  ## Options

    * `:status` — colours the line; defaults to `:unknown`
    * `:height` — pixels
    * `:annotations` — `[%{at: DateTime, label: String}]`, marking events that
      change what the number means
    * `:legend` — show uPlot's legend
  """
  @spec build(Definition.t(), map(), keyword()) :: map()
  def build(%Definition{} = definition, series, opts \\ []) do
    %{
      label: definition.name,
      status: Keyword.get(opts, :status, :unknown),
      height: Keyword.get(opts, :height, 260),
      legend: Keyword.get(opts, :legend, true),
      unit_suffix: unit_suffix(definition.unit),
      precision: precision(definition.unit),
      points_visible: length(series.points) <= 60,
      bands: bands(definition),
      annotations: annotations(opts),
      points: points(series)
    }
  end

  @doc "The chart payload as JSON, ready for a `data-chart` attribute."
  @spec to_json(Definition.t(), map(), keyword()) :: String.t()
  def to_json(definition, series, opts \\ []) do
    definition |> build(series, opts) |> Jason.encode!()
  end

  # uPlot wants seconds. `nil` values keep gaps as gaps: the line breaks rather
  # than implying a measurement that was never taken.
  defp points(series) do
    Enum.map(series.points, fn point ->
      %{t: DateTime.to_unix(point.at), v: point.value}
    end)
  end

  # Open-ended bands use nil for "as far as the axis goes", so the shading
  # always reaches the edge of the plot whatever the data does.
  defp bands(%Definition{direction: :higher_is_better, thresholds: t}) do
    [
      %{from: nil, to: t.critical, status: :critical},
      %{from: t.critical, to: t.warning, status: :warning},
      %{from: t.warning, to: nil, status: :good}
    ]
  end

  defp bands(%Definition{direction: :lower_is_better, thresholds: t}) do
    [
      %{from: nil, to: t.warning, status: :good},
      %{from: t.warning, to: t.critical, status: :warning},
      %{from: t.critical, to: nil, status: :critical}
    ]
  end

  defp bands(%Definition{direction: :target_band, thresholds: t}) do
    %{good: {good_low, good_high}, warning: {warn_low, warn_high}} = t

    [
      %{from: nil, to: warn_low, status: :critical},
      %{from: warn_low, to: good_low, status: :warning},
      %{from: good_low, to: good_high, status: :good},
      %{from: good_high, to: warn_high, status: :warning},
      %{from: warn_high, to: nil, status: :critical}
    ]
  end

  defp annotations(opts) do
    opts
    |> Keyword.get(:annotations, [])
    |> Enum.map(fn annotation ->
      %{at: DateTime.to_unix(annotation.at), label: annotation.label}
    end)
  end

  defp unit_suffix(:ratio), do: ""
  defp unit_suffix(:ms), do: "ms"
  defp unit_suffix(:usd), do: ""
  defp unit_suffix(:count), do: ""
  defp unit_suffix(:score), do: ""

  defp precision(:ratio), do: 3
  defp precision(:ms), do: 0
  defp precision(:usd), do: 4
  defp precision(:count), do: 0
  defp precision(:score), do: 3
end
