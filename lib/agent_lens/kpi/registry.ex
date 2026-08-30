defmodule AgentLens.Kpi.Registry do
  @moduledoc """
  Builds and validates the set of configured KPIs.

  This runs once at boot, outside the data path, and is the point at which a
  misconfigured KPI stops the application instead of crashing a worker later.
  It validates that every configured module implements the behaviour, that its
  definition is internally coherent, that every field it requires is one we
  actually store, and that derived KPIs depend only on registered slugs without
  forming a cycle.

  It is a plain function over a module list rather than a process. There is no
  state to own and nothing to supervise — the result is data, held by whoever
  needs it.
  """

  alias AgentLens.Kpi
  alias AgentLens.Kpi.Definition
  alias AgentLens.Kpi.FieldManifest

  @typedoc "A registered KPI: the module that computes it and its validated definition."
  @type entry :: %{module: module(), definition: Definition.t()}

  @typedoc "Registered KPIs, keyed by slug."
  @type t :: %{optional(atom()) => entry()}

  @doc """
  Builds the registry from application config, raising on any problem.

  This is the boot path. A clear startup failure naming the offending module is
  the entire point.
  """
  @spec load!() :: t()
  def load!, do: build!(configured_modules())

  @doc "The KPI modules listed in config."
  @spec configured_modules() :: [module()]
  def configured_modules do
    :agent_lens
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:kpis, [])
  end

  @doc "Builds the registry, raising a `RuntimeError` if it is not valid."
  @spec build!([module()]) :: t()
  def build!(modules) do
    case build(modules) do
      {:ok, registry} -> registry
      {:error, reason} -> raise "invalid KPI configuration: " <> reason
    end
  end

  @doc """
  Builds the registry from an explicit module list.

  Returns `{:error, reason}` with a message naming the module at fault rather
  than a partially populated registry.
  """
  @spec build([module()]) :: {:ok, t()} | {:error, String.t()}
  def build(modules) when is_list(modules) do
    with {:ok, entries} <- collect(modules),
         {:ok, registry} <- index(entries),
         :ok <- validate_dependencies(registry) do
      {:ok, registry}
    end
  end

  @doc "Fetches a definition by slug."
  @spec fetch_definition(t(), atom()) :: {:ok, Definition.t()} | :error
  def fetch_definition(registry, slug) do
    case Map.fetch(registry, slug) do
      {:ok, %{definition: definition}} -> {:ok, definition}
      :error -> :error
    end
  end

  @doc "Fetches the module implementing a slug."
  @spec fetch_module(t(), atom()) :: {:ok, module()} | :error
  def fetch_module(registry, slug) do
    case Map.fetch(registry, slug) do
      {:ok, %{module: module}} -> {:ok, module}
      :error -> :error
    end
  end

  @doc "All definitions, ordered by slug."
  @spec definitions(t()) :: [Definition.t()]
  def definitions(registry) do
    registry
    |> Map.values()
    |> Enum.map(& &1.definition)
    |> Enum.sort_by(& &1.slug)
  end

  @doc """
  Definitions of a given kind.

  Each kind has its own scheduler — extracted inline on ingest, judged sampled
  and asynchronous, derived on bucket close — so this is how each one finds its
  work without hardcoding a list of slugs.
  """
  @spec by_kind(t(), Definition.kind()) :: [Definition.t()]
  def by_kind(registry, kind) do
    registry
    |> definitions()
    |> Enum.filter(&(&1.kind == kind))
  end

  defp collect(modules) do
    modules
    |> Enum.reduce_while({:ok, []}, fn module, {:ok, acc} ->
      case entry_for(module) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, _reason} = error -> error
    end
  end

  defp entry_for(module) do
    with :ok <- ensure_implemented(module),
         definition = module.definition(),
         :ok <- validate_definition(module, definition),
         :ok <- validate_requires(module) do
      {:ok, %{module: module, definition: definition}}
    end
  end

  defp ensure_implemented(module) do
    if Kpi.implemented_by?(module) do
      :ok
    else
      {:error,
       "#{inspect(module)} is configured as a KPI but does not implement AgentLens.Kpi; " <>
         "it must exist and export definition/0 and compute/1"}
    end
  end

  defp validate_definition(module, %Definition{} = definition) do
    case Definition.validate(definition) do
      :ok -> :ok
      {:error, reason} -> {:error, "#{inspect(module)} returned an invalid definition: #{reason}"}
    end
  end

  defp validate_definition(module, other) do
    {:error,
     "#{inspect(module)}.definition/0 must return an %AgentLens.Kpi.Definition{}, " <>
       "got #{inspect(other)}"}
  end

  defp validate_requires(module) do
    case FieldManifest.validate(module.requires()) do
      :ok -> :ok
      {:error, reason} -> {:error, "#{inspect(module)} requires an unavailable field: #{reason}"}
    end
  end

  defp index(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn entry, {:ok, acc} ->
      slug = entry.definition.slug

      case Map.fetch(acc, slug) do
        {:ok, %{module: existing}} ->
          {:halt,
           {:error,
            "duplicate KPI slug #{inspect(slug)}, claimed by both " <>
              "#{inspect(existing)} and #{inspect(entry.module)}"}}

        :error ->
          {:cont, {:ok, Map.put(acc, slug, entry)}}
      end
    end)
  end

  defp validate_dependencies(registry) do
    with :ok <- validate_dependencies_registered(registry) do
      detect_cycles(registry)
    end
  end

  defp validate_dependencies_registered(registry) do
    Enum.reduce_while(registry, :ok, fn {slug, %{module: module}}, :ok ->
      case Enum.reject(module.depends_on(), &Map.has_key?(registry, &1)) do
        [] ->
          {:cont, :ok}

        [missing | _rest] ->
          {:halt,
           {:error,
            "#{inspect(module)} (#{slug}) depends on #{inspect(missing)}, " <>
              "which is not a registered KPI"}}
      end
    end)
  end

  defp detect_cycles(registry) do
    graph = Map.new(registry, fn {slug, %{module: module}} -> {slug, module.depends_on()} end)

    graph
    |> Map.keys()
    |> Enum.reduce_while({:ok, []}, fn slug, {:ok, visited} ->
      case visit(slug, graph, [], visited) do
        {:ok, visited} -> {:cont, {:ok, visited}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _visited} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @typep graph :: %{optional(atom()) => [atom()]}

  # Depth-first search carrying the current path to spot a back edge. Plain
  # lists rather than sets: the graph is one node per KPI, so membership cost is
  # irrelevant and this stays readable.
  @spec visit(atom(), graph(), [atom()], [atom()]) ::
          {:ok, [atom()]} | {:error, String.t()}
  defp visit(slug, graph, path, visited) do
    cond do
      slug in visited ->
        {:ok, visited}

      slug in path ->
        {:error,
         "KPI dependency cycle detected involving #{inspect(slug)}; " <>
           "derived KPIs must form an acyclic graph"}

      true ->
        walk(slug, graph, [slug | path], visited)
    end
  end

  @spec walk(atom(), graph(), [atom()], [atom()]) ::
          {:ok, [atom()]} | {:error, String.t()}
  defp walk(slug, graph, path, visited) do
    graph
    |> Map.get(slug, [])
    |> Enum.reduce_while({:ok, visited}, fn dependency, {:ok, acc} ->
      case visit(dependency, graph, path, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, [slug | acc]}
      {:error, _reason} = error -> error
    end
  end
end
