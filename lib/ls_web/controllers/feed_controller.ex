defmodule LSWeb.FeedController do
  use LSWeb, :controller
  plug :cache_headers

  def new_stores(conn, _params) do
    stores = case LS.Clickhouse.recent_stores(50) do
      {:ok, rows} ->
        Enum.map(rows, fn row ->
          %{domain: Enum.at(row, 0) || "", country: Enum.at(row, 1) || "",
            title: Enum.at(row, 2) || "", tech: Enum.at(row, 3) || "",
            enriched_at: Enum.at(row, 4)}
        end)
      _ -> []
    end

    conn
    |> assign(:page_title, "New Shopify Stores — Detected Today")
    |> assign(:page_description, "Live feed of newly detected Shopify stores. Updated continuously via SSL Certificate Transparency monitoring.")
    |> assign(:stores, stores)
    |> put_layout(html: {LSWeb.Layouts, :public})
    |> render(:new_stores)
  end

  defp cache_headers(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "public, s-maxage=300, max-age=60")
    |> put_resp_header("vary", "Accept-Encoding")
  end
end
