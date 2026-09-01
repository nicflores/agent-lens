defmodule AgentLens.LLM.Mock do
  @moduledoc """
  A deterministic stand-in for the model, so dev and test cost nothing.

  Like the LangSmith mock, it is hash-derived rather than random: the same
  prompt always returns the same score. A judge that answered differently on
  every call would make backfill unrepeatable and any test of it meaningless.
  """

  @behaviour AgentLens.LLM.Client

  alias AgentLens.LLM.Client

  @impl Client
  def complete(prompt, opts \\ []) do
    score = :erlang.phash2(prompt, 1_000) / 1_000

    {:ok,
     %{
       text: Float.to_string(Float.round(score, 3)),
       model: Keyword.get(opts, :model, "mock-judge")
     }}
  end
end
