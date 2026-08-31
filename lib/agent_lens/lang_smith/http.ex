defmodule AgentLens.LangSmith.HTTP do
  @moduledoc """
  The real LangSmith client. **Not yet implemented** — this arrives in Phase 8,
  along with rate limiting and retries.

  It exists now so that selecting it via `LANGSMITH_CLIENT=http` fails with an
  explanation rather than an `UndefinedFunctionError` from somewhere inside the
  poller. `runtime.exs` already validates the API key and workspace list when
  this client is chosen, so the configuration path is exercised; only the
  requests are missing.

  When implemented it must satisfy the same contract the mock does:
  oldest-first ordering, `:since` exclusive, and an honest `has_more?`. The
  poller's cursor arithmetic depends on all three.

  It returns an error rather than raising, which keeps it within the behaviour's
  contract: the poller records the reason on the cursor and backs off, instead
  of crash-looping under its supervisor. The reason is visible in
  `ingestion_cursors.last_error` and in the log.
  """

  @behaviour AgentLens.LangSmith.Client

  @impl AgentLens.LangSmith.Client
  def list_runs(_workspace, _opts), do: {:error, :not_implemented}

  @impl AgentLens.LangSmith.Client
  def list_feedback(_workspace, _opts), do: {:error, :not_implemented}
end
