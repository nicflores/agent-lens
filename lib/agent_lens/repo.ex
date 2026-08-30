defmodule AgentLens.Repo do
  use Ecto.Repo,
    otp_app: :agent_lens,
    adapter: Ecto.Adapters.Postgres
end
