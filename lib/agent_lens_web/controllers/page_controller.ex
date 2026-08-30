defmodule AgentLensWeb.PageController do
  use AgentLensWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
