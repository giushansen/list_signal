defmodule LSWeb.DigestController do
  @moduledoc """
  One-click digest unsubscribe. Public and login-free by design: the link
  lives in emails, and an unsubscribe that demands a login is how legitimate
  mail becomes spam reports.
  """
  use LSWeb, :controller

  def unsubscribe(conn, %{"token" => token}) do
    status =
      case LS.Engagement.unsubscribe(token) do
        {:ok, _user} -> :ok
        _ -> :invalid
      end

    conn
    |> assign(:page_title, "Unsubscribed")
    |> assign(:status, status)
    |> put_layout(html: {LSWeb.Layouts, :public})
    |> render(:unsubscribe)
  end
end
