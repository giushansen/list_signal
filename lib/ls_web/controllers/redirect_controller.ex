defmodule LSWeb.RedirectController do
  use LSWeb, :controller

  def signup(conn, _params) do
    redirect(conn, to: ~p"/users/register")
  end

  def login(conn, _params) do
    redirect(conn, to: ~p"/users/log-in")
  end
end
