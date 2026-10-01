defmodule LS.Tech.CatalogSync do
  @moduledoc """
  Mirrors `LS.Tech.Catalog` into the `tech_catalog` ClickHouse table on
  master boot, so the compactor fold, the stable-domain check and the
  explorer's category filters read the list this release ships
  (data model v2, 2026-10-01).

  ReplacingMergeTree keyed on name: re-inserting the same rows is idempotent
  after the next merge, and a removed name is deleted explicitly below so
  the fold stops publishing it. Runs once, in a task, and never blocks boot:
  a failed sync is logged and retried on the next restart, and the fold
  keeps using whatever the table holds in the meantime.
  """
  use Task, restart: :transient
  require Logger

  alias LS.Clickhouse
  alias LS.Schema.{Changes, Migration, Tables}

  def start_link(_), do: Task.start_link(&run/0)

  @doc "Create the table if missing, insert the catalog, then drop names no longer listed."
  def run do
    with {:ok, _} <- Clickhouse.query_raw(Changes.catalog_ddl(), 30_000),
         {:ok, _} <- Clickhouse.query_raw(Migration.catalog_insert_sql(), 60_000) do
      Logger.info("[CATALOG] tech_catalog synced: #{length(LS.Tech.Catalog.names())} names")
      prune()
    else
      err -> Logger.warning("[CATALOG] tech_catalog sync failed (fold keeps the stored list): #{inspect(err) |> String.slice(0, 200)}")
    end
  rescue
    e -> Logger.warning("[CATALOG] tech_catalog sync crashed: #{Exception.message(e)}")
  end

  # Pruning is the one step that needs a privilege the app user did not have
  # on the first v2 boot (2026-10-01: Code 497, ALTER DELETE). The insert
  # above is what the fold depends on, so a refused prune only leaves names
  # the catalog dropped in the table until the grant is applied:
  #   GRANT ALTER DELETE ON ls.tech_catalog TO ls_app
  defp prune do
    case Clickhouse.query_raw(delete_sql(), 60_000) do
      {:ok, _} -> :ok
      err -> Logger.warning("[CATALOG] prune of removed names skipped (needs GRANT ALTER DELETE ON ls.tech_catalog TO ls_app): #{inspect(err) |> String.slice(0, 160)}")
    end
  end

  defp delete_sql do
    names = Enum.map_join(LS.Tech.Catalog.names(), ", ", &"'#{String.replace(&1, "'", "\\'")}'")
    "ALTER TABLE #{Tables.tech_catalog()} DELETE WHERE name NOT IN (#{names})"
  end
end
