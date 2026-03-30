defmodule LSWeb.LegalController do
  use LSWeb, :controller

  def privacy(conn, _params) do
    conn
    |> assign(:page_title, "Privacy Policy")
    |> put_layout(html: {LSWeb.Layouts, :public})
    |> render(:privacy)
  end

  def terms(conn, _params) do
    conn
    |> assign(:page_title, "Terms of Service")
    |> put_layout(html: {LSWeb.Layouts, :public})
    |> render(:terms)
  end
end
