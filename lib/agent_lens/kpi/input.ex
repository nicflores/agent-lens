defmodule AgentLens.Kpi.Input do
  @moduledoc """
  The inputs a KPI computes from.

  The three kinds of KPI arrive from genuinely different places, so `compute/1`
  is given a tagged struct and each module pattern-matches the one it expects:

    * `AgentLens.Kpi.Input.Run` — one run, for `:extracted` and `:imported`
      KPIs, computed on run arrival.
    * `AgentLens.Kpi.Input.Window` — a closed bucket plus the series it depends
      on, for `:derived` KPIs, computed on bucket close.

  This is the seam that lets both schedules share a single callback. Without it,
  a derived KPI's baseline wiring would have to live in the rollup module, which
  is exactly the leak the KPI behaviour exists to prevent.
  """

  alias AgentLens.Kpi.Input.Run
  alias AgentLens.Kpi.Input.Window

  @typedoc "Either shape of KPI input."
  @type t :: Run.t() | Window.t()
end
