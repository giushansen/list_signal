defmodule LSWeb.RedirectController do
  use LSWeb, :controller

  def signup(conn, params) do
    query_params =
      []
      |> then(fn q -> if params["plan"] in ["starter", "pro"], do: [{"plan", params["plan"]} | q], else: q end)
      |> then(fn q -> if params["billing"] in ["monthly", "annual"], do: [{"billing", params["billing"]} | q], else: q end)

    target = case query_params do
      [] -> "/users/register"
      _ -> "/users/register?" <> URI.encode_query(query_params)
    end

    redirect(conn, to: target)
  end

  def login(conn, _params) do
    redirect(conn, to: ~p"/users/log-in")
  end
end
