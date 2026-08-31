defmodule AgentLensWeb.DashboardComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias AgentLens.Kpi.Registry
  alias AgentLensWeb.DashboardComponents, as: UI

  defp definition(slug) do
    {:ok, definition} = Registry.fetch_definition(Registry.load!(), slug)
    definition
  end

  describe "status_badge/1" do
    # Colour alone excludes a meaningful fraction of users, so every status
    # carries an icon and a word as well.
    test "renders icon, colour and text together" do
      html = render_component(&UI.status_badge/1, status: :critical)

      assert html =~ "Critical"
      assert html =~ "hero-exclamation-circle"
      assert html =~ "text-status-critical"
    end

    test "unknown is grey and says so, never green" do
      html = render_component(&UI.status_badge/1, status: :unknown)

      assert html =~ "Unknown"
      assert html =~ "status-unknown"
      refute html =~ "status-good"
    end

    test "explains what unknown means, since it is easily mistaken for healthy" do
      html = render_component(&UI.status_badge/1, status: :unknown)

      assert html =~ "not the same as healthy"
    end
  end

  describe "bullet_chart/1 zones" do
    test "a lower-is-better KPI shades good at the left and critical at the right" do
      html =
        render_component(&UI.bullet_chart/1,
          definition: definition(:latency_p95),
          value: 1_200.0,
          status: :good
        )

      assert html =~ "fill-status-good"
      assert html =~ "fill-status-critical"
    end

    test "a higher-is-better KPI is judged on the same scale it declares" do
      html =
        render_component(&UI.bullet_chart/1,
          definition: definition(:success_rate),
          value: 0.97,
          status: :good
        )

      assert html =~ "Success Rate: 97.0%, Good"
    end

    # The case a two-direction encoding gets wrong: for a banded KPI the healthy
    # zone is in the middle, so both extremes must shade toward critical.
    test "a banded KPI has healthy in the middle and critical at both ends" do
      html =
        render_component(&UI.bullet_chart/1,
          definition: definition(:sentiment),
          value: 0.3,
          status: :good
        )

      critical_zones =
        html |> String.split("fill-status-critical") |> length() |> Kernel.-(1)

      assert critical_zones == 2, "expected critical shading at both extremes"
    end

    test "renders no value bar at all when there is no reading" do
      html =
        render_component(&UI.bullet_chart/1, definition: definition(:toxicity), value: nil)

      assert html =~ "no reading"
    end

    test "is labelled for assistive technology" do
      html =
        render_component(&UI.bullet_chart/1,
          definition: definition(:toxicity),
          value: 0.02,
          status: :good
        )

      assert html =~ ~s(role="img")
      assert html =~ "Toxicity: 0.020, Good"
    end
  end

  describe "trend_arrow/1" do
    # Geometry is the delta; colour is what the delta means for this KPI.
    test "a rise in a lower-is-better KPI is a red up-arrow" do
      html =
        render_component(&UI.trend_arrow/1, delta: 12.0, definition: definition(:toxicity))

      assert html =~ "hero-arrow-trending-up"
      assert html =~ "text-status-critical"
    end

    test "a rise in a higher-is-better KPI is a green up-arrow" do
      html =
        render_component(&UI.trend_arrow/1, delta: 12.0, definition: definition(:success_rate))

      assert html =~ "hero-arrow-trending-up"
      assert html =~ "text-status-good"
    end

    test "a banded KPI takes no position from the delta alone" do
      html =
        render_component(&UI.trend_arrow/1, delta: 12.0, definition: definition(:sentiment))

      refute html =~ "text-status-good"
      refute html =~ "text-status-critical"
    end

    test "compares against the same window last week, and says so" do
      html =
        render_component(&UI.trend_arrow/1, delta: -3.5, definition: definition(:toxicity))

      assert html =~ "same window last week"
    end

    test "renders nothing when there is no comparison to make" do
      html = render_component(&UI.trend_arrow/1, delta: nil, definition: definition(:toxicity))

      refute html =~ "hero-arrow"
    end
  end

  describe "sample_meter/1" do
    test "shows how much of the population a reading rests on" do
      html =
        render_component(&UI.sample_meter/1,
          sample_n: 40,
          population_n: 240,
          definition: definition(:toxicity)
        )

      assert html =~ "40"
      assert html =~ "240"
    end

    # A score from three runs and one from four hundred must not look alike.
    test "flags a sample below the KPI's minimum" do
      html =
        render_component(&UI.sample_meter/1,
          sample_n: 3,
          population_n: 240,
          definition: definition(:toxicity)
        )

      assert html =~ "text-status-unknown"
      assert html =~ "below the 30"
    end
  end

  describe "format_value/2" do
    test "renders a ratio as a percentage" do
      assert "97.0%" = UI.format_value(0.97, definition(:success_rate))
    end

    test "renders sub-second latency in milliseconds and above it in seconds" do
      assert "850ms" = UI.format_value(850.0, definition(:latency_p95))
      assert "7.00s" = UI.format_value(7000.0, definition(:latency_p95))
    end

    test "renders a score at the precision people actually compare on" do
      assert "0.151" = UI.format_value(0.1512, definition(:toxicity))
    end

    # An em dash, not a zero. There is a difference between "we measured zero"
    # and "we have nothing".
    test "renders an absent value as a dash" do
      assert "—" = UI.format_value(nil, definition(:toxicity))
    end
  end

  describe "sparkline/1" do
    test "draws a path when there is a shape to draw" do
      points = for v <- [1.0, 2.0, 1.5, 3.0], do: %{value: v}

      assert render_component(&UI.sparkline/1, points: points) =~ "<path"
    end

    test "says there is no data rather than drawing a flat line at zero" do
      html = render_component(&UI.sparkline/1, points: [])

      refute html =~ "<path"
      assert html =~ "No data"
    end
  end
end
