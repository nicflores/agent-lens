defmodule AgentLens.LangSmith.HTTP do
  @moduledoc """
  The real LangSmith client.

  ## Read this before pointing it at a live instance

  This has been built and tested against stubbed responses, **not** against a
  running LangSmith. Every request and response shape below is written from the
  documented API, and the parts most likely to need correcting are gathered into
  `@endpoints` and the `extract_*` functions rather than scattered through the
  module, so fixing them is an edit in one place rather than a rewrite.

  What to check first against your instance:

    * the run query path and whether it takes a JSON body or query parameters
    * the cursor field name in the response, and whether paging is by cursor or
      offset
    * the header used to scope an org-wide key to one workspace
    * the feedback query path and its filter parameters

  The behaviour's contract is what actually matters, and it is pinned by the
  mock's own tests: results oldest-first, `:since` exclusive, and an honest
  `has_more?`. The poller's cursor arithmetic depends on all three, so a wrong
  implementation of any of them loses or repeats data silently.

  ## Retries

  Retried on 429 and 5xx with exponential backoff, honouring `Retry-After` when
  the server sends one. Never retried on 4xx: a malformed query or a bad key
  will fail identically however many times it is asked, and retrying only
  delays the error reaching someone who can fix it.
  """

  @behaviour AgentLens.LangSmith.Client

  require Logger

  alias AgentLens.LangSmith.RateLimiter

  # Gathered here so a correction is one edit. See the moduledoc.
  @endpoints %{
    runs: "/api/v1/runs/query",
    feedback: "/api/v1/feedback/query"
  }

  @max_attempts 4
  @base_backoff_ms 500

  @impl AgentLens.LangSmith.Client
  def list_runs(workspace, opts \\ []) do
    body = %{
      limit: Keyword.get(opts, :limit, 100),
      order: "asc",
      start_time: iso8601(Keyword.get(opts, :since))
    }

    with {:ok, payload} <- post(@endpoints.runs, body, workspace, opts) do
      {:ok, page(extract_runs(payload), Keyword.get(opts, :limit, 100))}
    end
  end

  @impl AgentLens.LangSmith.Client
  def list_feedback(workspace, opts \\ []) do
    body = %{
      limit: Keyword.get(opts, :limit, 100),
      order: "asc",
      start_time: iso8601(Keyword.get(opts, :since))
    }

    with {:ok, payload} <- post(@endpoints.feedback, body, workspace, opts) do
      {:ok, page(extract_feedback(payload), Keyword.get(opts, :limit, 100))}
    end
  end

  @doc """
  Whether the configuration is complete enough to talk to a real LangSmith.

  Used at boot to decide between this client and the mock. An incomplete
  configuration falls back rather than failing, so a deploy that has lost its
  key degrades to obviously-fake data instead of crashing — but the UI is told,
  because presenting generated numbers as real telemetry would be far worse
  than either.
  """
  @spec configured?(keyword()) :: boolean()
  def configured?(config) do
    present?(Keyword.get(config, :api_key)) and present?(Keyword.get(config, :endpoint))
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_other), do: false

  # LangSmith returns either a bare list or an envelope, depending on endpoint
  # and version. Accepting both costs nothing and removes a whole class of
  # first-contact failure.
  defp extract_runs(payload) when is_list(payload), do: payload
  defp extract_runs(%{"runs" => runs}) when is_list(runs), do: runs
  defp extract_runs(%{"data" => data}) when is_list(data), do: data
  defp extract_runs(_other), do: []

  defp extract_feedback(payload) when is_list(payload), do: payload
  defp extract_feedback(%{"feedback" => items}) when is_list(items), do: items
  defp extract_feedback(%{"data" => items}) when is_list(items), do: items
  defp extract_feedback(_other), do: []

  # A full page means there is more behind it. The poller re-reads from its
  # watermark rather than following a cursor, so it only needs to know whether
  # to come straight back.
  defp page(items, limit), do: %{items: items, has_more?: length(items) >= limit}

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp post(path, body, workspace, opts) do
    config = Keyword.get(opts, :config, langsmith_config())

    request =
      [
        method: :post,
        url: path,
        base_url: Keyword.fetch!(config, :endpoint),
        json: Map.reject(body, fn {_key, value} -> is_nil(value) end),
        headers: headers(workspace, config),
        receive_timeout: Keyword.get(opts, :receive_timeout, 30_000)
      ]
      |> maybe_put_plug(opts)

    attempt(request, 1, opts)
  end

  defp attempt(request, attempt_number, opts) do
    {:ok, _waited} = acquire(opts)

    case request |> Req.new() |> Req.request() do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status} = response} when status == 429 or status >= 500 ->
        retry(request, attempt_number, opts, {:http_status, status}, retry_after(response))

      {:ok, %{status: status, body: body}} ->
        # A 4xx will fail identically however often it is asked.
        {:error, {:http_status, status, body}}

      {:error, reason} ->
        retry(request, attempt_number, opts, reason, nil)
    end
  end

  defp retry(_request, attempt_number, _opts, reason, _after)
       when attempt_number >= @max_attempts,
       do: {:error, reason}

  defp retry(request, attempt_number, opts, reason, retry_after) do
    delay = retry_after || backoff(attempt_number)

    Logger.warning(
      "LangSmith request failed (#{inspect(reason)}), " <>
        "retrying in #{delay}ms (attempt #{attempt_number + 1}/#{@max_attempts})"
    )

    Process.sleep(delay)
    attempt(request, attempt_number + 1, opts)
  end

  # Full jitter, so a fleet of pollers that all failed together does not come
  # back in lockstep and fail together again.
  defp backoff(attempt_number) do
    ceiling = @base_backoff_ms * Integer.pow(2, attempt_number - 1)
    :rand.uniform(ceiling)
  end

  defp retry_after(%{headers: headers}) do
    case headers["retry-after"] || headers["Retry-After"] do
      [value | _rest] -> parse_retry_after(value)
      _absent -> nil
    end
  end

  defp parse_retry_after(value) do
    case Integer.parse(value) do
      {seconds, _rest} -> seconds * 1_000
      :error -> nil
    end
  end

  defp headers(workspace, config) do
    [
      {"x-api-key", Keyword.fetch!(config, :api_key)},
      {"content-type", "application/json"}
    ] ++ workspace_header(workspace, config)
  end

  # An org-scoped key needs telling which workspace to read. A key already
  # scoped to one workspace does not, and sending the header anyway is
  # harmless.
  defp workspace_header(nil, _config), do: []

  defp workspace_header(workspace, config),
    do: [{Keyword.get(config, :workspace_header, "x-tenant-id"), workspace}]

  defp acquire(opts) do
    case Keyword.get(opts, :rate_limiter, RateLimiter) do
      nil -> {:ok, 0}
      server -> RateLimiter.acquire(server)
    end
  end

  # Req's plug option lets tests exercise the real request-building and retry
  # logic without a network.
  defp maybe_put_plug(request, opts) do
    case Keyword.get(opts, :plug) do
      nil -> request
      plug -> Keyword.put(request, :plug, plug)
    end
  end

  defp langsmith_config, do: Application.get_env(:agent_lens, :langsmith, [])
end
