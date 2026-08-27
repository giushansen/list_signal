defmodule LSWeb.HiringController do
  @moduledoc """
  Public /hiring page: hiring activity across the tracked businesses.

  Shows deliberately COARSE aggregates, total hiring companies, total open
  roles, department-level counts. Nothing per-company, no board names, no
  platform detail: the collection method is a competitive asset, and this
  page sells the dataset's existence without teaching anyone how to build it.

  Aggregates are cached in :persistent_term for an hour, the query walks
  9M+ rows, and this is a public, crawlable page.
  """
  use LSWeb, :controller

  @cache_key {__MODULE__, :overview}
  @ttl_s 3_600

  def index(conn, _params) do
    stats = cached_overview()

    conn
    |> assign(:page_title, "Hiring Signals, Which Online Businesses Are Hiring Right Now")
    |> assign(
      :page_description,
      "Live hiring activity across millions of tracked online businesses: open roles by department, growing companies, and hiring as a buying signal."
    )
    |> assign(:stats, stats)
    |> put_layout(html: {LSWeb.Layouts, :public})
    |> render(:index)
  end

  defp cached_overview do
    now = System.system_time(:second)

    case :persistent_term.get(@cache_key, nil) do
      {stats, expires} when expires > now ->
        stats

      _ ->
        case LS.Clickhouse.hiring_overview() do
          {:ok, stats} ->
            :persistent_term.put(@cache_key, {stats, now + @ttl_s})
            stats

          _ ->
            %{companies: 0, roles: 0, departments: []}
        end
    end
  end
end
