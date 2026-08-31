defmodule AgentLensWeb.TimeRange do
  @moduledoc """
  The time ranges the dashboard offers, and their URL representation.

  Ranges live in the query string rather than in socket state so the back
  button works and a link to what you are looking at is just the address bar.
  That is cheap to do and most of what makes a dashboard feel finished.
  """

  @ranges [
    {"1h", "1 hour", 3_600},
    {"24h", "24 hours", 86_400},
    {"7d", "7 days", 604_800},
    {"30d", "30 days", 2_592_000},
    {"90d", "90 days", 7_776_000}
  ]

  @default "7d"

  @doc "The default range key."
  @spec default() :: String.t()
  def default, do: @default

  @doc "`{key, label}` pairs for the range picker, shortest first."
  @spec options() :: [{String.t(), String.t()}]
  def options, do: Enum.map(@ranges, fn {key, label, _seconds} -> {key, label} end)

  @doc "Every valid key."
  @spec keys() :: [String.t()]
  def keys, do: Enum.map(@ranges, &elem(&1, 0))

  @doc """
  Parses a range key from a URL parameter, falling back to the default.

  Never raises and never trusts the input: an unrecognised value is simply the
  default, so a hand-edited or stale link still renders.
  """
  @spec parse(term()) :: String.t()
  def parse(key) when is_binary(key) do
    if key in keys(), do: key, else: @default
  end

  def parse(_other), do: @default

  @doc "The human label for a key."
  @spec label(String.t()) :: String.t()
  def label(key) do
    Enum.find_value(@ranges, "", fn {k, label, _seconds} -> k == key && label end)
  end

  @doc "How many seconds a range spans."
  @spec seconds(String.t()) :: pos_integer()
  def seconds(key) do
    Enum.find_value(@ranges, 604_800, fn {k, _label, seconds} -> k == key && seconds end)
  end

  @doc "The `{from, to}` bounds for a range, ending now unless told otherwise."
  @spec bounds(String.t(), DateTime.t()) :: {DateTime.t(), DateTime.t()}
  def bounds(key, now \\ DateTime.utc_now()) do
    {DateTime.add(now, -seconds(key), :second), now}
  end

  @doc """
  The same range, one week earlier.

  Trend comparisons use this rather than the immediately preceding window, so
  Monday traffic is compared with Monday traffic and ordinary weekly rhythm
  does not read as a regression.
  """
  @spec previous_week_bounds(String.t(), DateTime.t()) :: {DateTime.t(), DateTime.t()}
  def previous_week_bounds(key, now \\ DateTime.utc_now()) do
    {from, to} = bounds(key, now)
    {DateTime.add(from, -7, :day), DateTime.add(to, -7, :day)}
  end
end
