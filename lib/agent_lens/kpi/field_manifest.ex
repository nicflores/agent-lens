defmodule AgentLens.Kpi.FieldManifest do
  @moduledoc """
  The set of run fields a KPI is allowed to declare in `c:AgentLens.Kpi.requires/0`.

  This exists to convert a class of runtime failure into a startup failure. A KPI
  that reads a field we never stored would otherwise surface as a `nil`
  arithmetic crash in a worker, at volume, long after deploy. Validating
  `requires/0` against this manifest at boot turns that into a named error
  before the application starts.

  Three forms of path are recognised:

    * `:latency_ms` — a flattened column on `runs`
    * `{:payload, ["outputs", "text"]}` — a path into the retained `jsonb` payload
    * `{:feedback, "kpi.toxicity"}` — a LangSmith feedback key

  The payload form is only checked as far as its root key, since anything deeper
  is data-dependent. That still catches the typo, which is the point.
  """

  @columns [
    :langsmith_run_id,
    :agent_id,
    :trace_id,
    :parent_run_id,
    :name,
    :run_type,
    :start_time,
    :end_time,
    :latency_ms,
    :status,
    :error,
    :model,
    :prompt_tokens,
    :completion_tokens,
    :cost_usd
  ]

  # Top-level keys of a LangSmith run payload.
  @payload_roots ~w(inputs outputs extra events error serialized tags metadata feedback_stats)

  @feedback_prefix "kpi."

  @typedoc "A field a KPI may declare a dependency on."
  @type path :: atom() | {:payload, [String.t()]} | {:feedback, String.t()}

  @doc "The flattened columns available on `runs`."
  @spec columns() :: [atom()]
  def columns, do: @columns

  @doc "The recognised top-level keys of a retained run payload."
  @spec payload_roots() :: [String.t()]
  def payload_roots, do: @payload_roots

  @doc """
  Validates every path in a `requires/0` list, reporting the first failure.
  """
  @spec validate([path()]) :: :ok | {:error, String.t()}
  def validate(paths) when is_list(paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case validate_path(path) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  def validate(other),
    do: {:error, "requires/0 must return a list, got #{inspect(other)}"}

  @doc """
  Validates a single field path against the manifest.
  """
  @spec validate_path(term()) :: :ok | {:error, String.t()}
  def validate_path(column) when is_atom(column) and not is_nil(column) do
    if column in @columns do
      :ok
    else
      {:error,
       "unknown run field #{inspect(column)}. Known columns: #{inspect(@columns)}. " <>
         "If the value lives in the retained payload, declare it as " <>
         "{:payload, [\"...\"]} instead."}
    end
  end

  def validate_path({:payload, []}),
    do: {:error, "a {:payload, path} requirement needs at least one segment"}

  def validate_path({:payload, [root | _rest] = segments}) when is_list(segments) do
    cond do
      not Enum.all?(segments, &is_binary/1) ->
        {:error,
         "payload path segments must be strings, since jsonb keys are strings, " <>
           "got #{inspect(segments)}"}

      root not in @payload_roots ->
        {:error, "unknown payload root #{inspect(root)}. Known roots: #{inspect(@payload_roots)}"}

      true ->
        :ok
    end
  end

  def validate_path({:feedback, key}) when is_binary(key) do
    if String.starts_with?(key, @feedback_prefix) do
      :ok
    else
      {:error,
       "feedback key #{inspect(key)} must be namespaced #{inspect(@feedback_prefix)} so that " <>
         "mapping a LangSmith evaluator to a KPI slug stays mechanical"}
    end
  end

  def validate_path(other),
    do:
      {:error,
       "unrecognised field path #{inspect(other)}. Expected an atom column, " <>
         "{:payload, segments}, or {:feedback, key}."}
end
