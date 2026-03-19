defmodule LSWeb.PageController do
  use LSWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
