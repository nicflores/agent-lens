defmodule AgentLens.LangSmith.HTTPTest do
  @moduledoc """
  Exercises the real request-building and retry logic against a stub, since
  there is no LangSmith to point at. What this cannot check is whether the
  endpoint paths and field names match the live API — see the moduledoc on the
  client itself for what to verify first.
  """

  use ExUnit.Case, async: true

  alias AgentLens.LangSmith.HTTP

  @config [api_key: "test-key", endpoint: "https://langsmith.test"]

  # A stub that records what it was asked and replies with what the test wants.
  defp stub(responses) do
    owner = self()
    counter = :counters.new(1, [])

    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      :counters.add(counter, 1, 1)
      attempt = :counters.get(counter, 1)

      send(
        owner,
        {:request,
         %{
           path: conn.request_path,
           headers: Map.new(conn.req_headers),
           body: Jason.decode!(body),
           attempt: attempt
         }}
      )

      {status, payload} = Enum.at(responses, attempt - 1, List.last(responses))

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(payload))
    end
  end

  defp opts(responses, extra \\ []) do
    Keyword.merge(
      [config: @config, plug: stub(responses), rate_limiter: nil, limit: 2],
      extra
    )
  end

  describe "list_runs/2" do
    test "returns the runs the API sent" do
      runs = [%{"id" => "run-1"}, %{"id" => "run-2"}]

      assert {:ok, %{items: ^runs}} =
               HTTP.list_runs("ws-support", opts([{200, %{"runs" => runs}}]))
    end

    test "authenticates with the API key" do
      {:ok, _page} = HTTP.list_runs("ws-support", opts([{200, %{"runs" => []}}]))

      assert_receive {:request, %{headers: headers}}
      assert headers["x-api-key"] == "test-key"
    end

    # An org-scoped key needs telling which workspace to read, and the workspace
    # is our agent identity.
    test "scopes the request to the workspace" do
      {:ok, _page} = HTTP.list_runs("ws-research", opts([{200, %{"runs" => []}}]))

      assert_receive {:request, %{headers: headers}}
      assert headers["x-tenant-id"] == "ws-research"
    end

    test "asks for results oldest first, which the cursor arithmetic depends on" do
      {:ok, _page} = HTTP.list_runs("ws-support", opts([{200, %{"runs" => []}}]))

      assert_receive {:request, %{body: body}}
      assert body["order"] == "asc"
    end

    test "passes the watermark as the start time" do
      since = ~U[2026-08-30 12:00:00.000000Z]

      {:ok, _page} =
        HTTP.list_runs("ws-support", opts([{200, %{"runs" => []}}], since: since))

      assert_receive {:request, %{body: body}}
      assert body["start_time"] == DateTime.to_iso8601(since)
    end

    test "omits the start time entirely when there is no watermark" do
      {:ok, _page} = HTTP.list_runs("ws-support", opts([{200, %{"runs" => []}}]))

      assert_receive {:request, %{body: body}}
      refute Map.has_key?(body, "start_time")
    end

    # A full page means there is more behind it.
    test "reports more results when the page comes back full" do
      runs = [%{"id" => "a"}, %{"id" => "b"}]

      assert {:ok, %{has_more?: true}} =
               HTTP.list_runs("ws-support", opts([{200, %{"runs" => runs}}], limit: 2))
    end

    test "reports no more results when the page is short" do
      assert {:ok, %{has_more?: false}} =
               HTTP.list_runs(
                 "ws-support",
                 opts([{200, %{"runs" => [%{"id" => "a"}]}}], limit: 2)
               )
    end

    # The API has returned both a bare list and an envelope across versions.
    # Accepting either removes a class of first-contact failure.
    test "accepts a bare list as well as an envelope" do
      runs = [%{"id" => "run-1"}]

      assert {:ok, %{items: ^runs}} = HTTP.list_runs("ws-support", opts([{200, runs}]))

      assert {:ok, %{items: ^runs}} =
               HTTP.list_runs("ws-support", opts([{200, %{"data" => runs}}]))
    end
  end

  describe "list_feedback/2" do
    test "returns the feedback the API sent" do
      items = [%{"id" => "fb-1", "key" => "kpi.toxicity"}]

      assert {:ok, %{items: ^items}} =
               HTTP.list_feedback("ws-support", opts([{200, %{"feedback" => items}}]))
    end

    test "uses its own endpoint, since feedback has an independent cursor" do
      {:ok, _page} = HTTP.list_feedback("ws-support", opts([{200, %{"feedback" => []}}]))

      assert_receive {:request, %{path: path}}
      assert path =~ "feedback"
    end
  end

  describe "retries" do
    test "retries a rate limit and succeeds" do
      responses = [{429, %{}}, {200, %{"runs" => [%{"id" => "run-1"}]}}]

      assert {:ok, %{items: [%{"id" => "run-1"}]}} =
               HTTP.list_runs("ws-support", opts(responses))

      assert_receive {:request, %{attempt: 1}}
      assert_receive {:request, %{attempt: 2}}
    end

    test "retries a server error" do
      responses = [{503, %{}}, {200, %{"runs" => []}}]

      assert {:ok, _page} = HTTP.list_runs("ws-support", opts(responses))
    end

    # A malformed query or a bad key fails identically however often it is
    # asked; retrying only delays the error reaching someone who can fix it.
    test "does not retry a client error" do
      assert {:error, {:http_status, 401, _body}} =
               HTTP.list_runs("ws-support", opts([{401, %{"detail" => "bad key"}}]))

      assert_receive {:request, %{attempt: 1}}
      refute_receive {:request, %{attempt: 2}}, 200
    end

    test "gives up after a bounded number of attempts" do
      assert {:error, {:http_status, 500}} =
               HTTP.list_runs("ws-support", opts([{500, %{}}]))
    end
  end

  describe "configured?/1" do
    test "is true only when there is both a key and an endpoint" do
      assert HTTP.configured?(api_key: "k", endpoint: "https://x")
    end

    test "is false without a key, so the mock is used instead of crashing" do
      refute HTTP.configured?(api_key: nil, endpoint: "https://x")
      refute HTTP.configured?(endpoint: "https://x")
    end

    # An empty string is what an unset variable usually becomes in a shell.
    test "treats a blank key as absent" do
      refute HTTP.configured?(api_key: "   ", endpoint: "https://x")
    end
  end
end
