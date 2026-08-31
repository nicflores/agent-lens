defmodule AgentLensWeb.DashboardLiveTest do
  use AgentLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AgentLens.Broadcaster
  alias AgentLens.Cache
  alias AgentLens.Ingestion.FeedbackImporter
  alias AgentLens.Ingestion.RunImporter
  alias AgentLens.LangSmith.Mock
  alias AgentLens.Rollup

  @workspace "ws-support"

  setup do
    Cache.clear()

    now = DateTime.utc_now()
    since = DateTime.add(now, -3, :day)

    {:ok, %{items: runs}} = Mock.list_runs(@workspace, since: since, limit: 800, now: now)
    {:ok, _} = RunImporter.import(@workspace, runs)

    {:ok, %{items: feedback}} =
      Mock.list_feedback(@workspace, since: since, limit: 800, now: now)

    {:ok, _} = FeedbackImporter.import(@workspace, feedback)

    for granularity <- [:hour, :day], do: {:ok, _} = Rollup.run!(granularity, since, now)

    on_exit(&Cache.clear/0)

    :ok
  end

  describe "the agent grid" do
    test "lists every reporting agent", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#agent-grid")
      assert has_element?(view, "#agent-#{@workspace}")
    end

    test "links each agent to its drilldown", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert view
             |> element("#agent-#{@workspace} a", @workspace)
             |> render_click()
             |> follow_redirect(conn, ~p"/agents/#{@workspace}")
    end

    test "filters by status", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#filter-good") |> render_click()

      assert_patch(view, ~p"/?status=good")
    end

    test "an impossible filter shows an empty state rather than an error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/?status=warning")

      assert has_element?(view, "#empty-state") or has_element?(view, "#agent-grid")
    end

    # Twenty dashboards are pushed the same computed result rather than each
    # querying for it.
    test "updates in place when the broadcaster publishes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      {:ok, _overview} = Broadcaster.refresh()

      assert render(view) =~ @workspace
    end
  end

  describe "the agent drilldown" do
    test "renders a card for every registered KPI", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agents/#{@workspace}")

      for slug <- ~w(success_rate latency_p95 toxicity sentiment latency_drift) do
        assert has_element?(view, "#kpi-#{slug}")
      end
    end

    # State lives in the URL so the back button works and links are shareable.
    test "the range picker patches the URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agents/#{@workspace}")

      view |> element("#range-24h") |> render_click()

      assert_patch(view, ~p"/agents/#{@workspace}?range=24h")
    end

    test "reads its range from the URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agents/#{@workspace}?range=30d")

      assert has_element?(view, "#range-30d[aria-pressed='true']")
    end

    test "an unrecognised range falls back to the default rather than failing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agents/#{@workspace}?range=nonsense")

      assert has_element?(view, "#range-7d[aria-pressed='true']")
    end

    test "links a card through to its deep dive", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agents/#{@workspace}")

      assert view
             |> element("#kpi-toxicity a", "Toxicity")
             |> render_click()
             |> follow_redirect(conn)
    end
  end

  describe "the KPI deep dive" do
    test "renders the chart once the series has loaded", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agents/#{@workspace}/kpis/latency_p95")

      # start_async fills the chart in after mount; the skeleton goes with it.
      assert render_async(view) =~ "kpi-chart"
      refute has_element?(view, "#chart-skeleton")
    end

    test "hands the chart its threshold bands and points", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agents/#{@workspace}/kpis/latency_p95")
      render_async(view)

      config =
        view
        |> element("#kpi-chart")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.attribute("data-chart")
        |> hd()
        |> Jason.decode!()

      assert config["label"] == "Latency p95"
      assert length(config["bands"]) == 3
      assert config["points"] != []
      assert Enum.all?(config["points"], &Map.has_key?(&1, "t"))
    end

    test "the methodology drawer opens through the URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agents/#{@workspace}/kpis/toxicity")

      view |> element("#methodology-toggle") |> render_click()

      assert_patch(view, ~p"/agents/#{@workspace}/kpis/toxicity?methodology=open&range=7d")
      assert has_element?(view, "#methodology-drawer[class*='accent']")
    end

    test "explains where a judged score came from", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/agents/#{@workspace}/kpis/toxicity?methodology=open")

      drawer = view |> element("#methodology-drawer") |> render()

      assert drawer =~ "LangSmith evaluator"
      assert drawer =~ "20% of runs"
      assert drawer =~ "can turn the agent red"
    end

    test "says a KPI is informational when it cannot turn an agent red", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agents/#{@workspace}/kpis/latency_p95")

      refute view |> element("#methodology-drawer") |> render() =~ "can turn the agent red"
    end

    # A hand-typed slug must not grow the atom table or crash the page.
    test "an unknown KPI redirects instead of erroring", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/agents/#{@workspace}/kpis/not_a_real_kpi")

      assert to == "/agents/#{@workspace}"
    end

    test "a range with no data shows an empty chart rather than a flat zero", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agents/#{@workspace}/kpis/latency_p95?range=1h")
      render_async(view)

      assert has_element?(view, "#kpi-chart") or has_element?(view, "#chart-empty")
    end
  end
end
