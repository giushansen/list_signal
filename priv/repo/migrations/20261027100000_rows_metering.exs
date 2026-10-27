defmodule LS.Repo.Migrations.RowsMetering do
  use Ecto.Migration

  @moduledoc """
  Rows are the unit (2026-10-27, LS.Plans). Two changes:

    * `api_usage.rows`: rows delivered by the key this month, next to the
      call count. NULL on rows written before this migration; the quota
      reads `coalesce(rows, calls)`, so a legacy month still counts.
      Existing rows are backfilled with their call count, the only number
      we had.
    * `users.exports_reset_at`: the CSV counter never reset. The column
      existed since the first migration but nothing read or wrote it, so
      a customer who exported 5,000 rows in June was still at 5,000 in
      October. The counter now belongs to the month in `exports_reset_at`;
      NULL rows are stamped with today so they reset on the 1st.
  """

  def up do
    alter table(:api_usage) do
      add :rows, :integer
    end

    execute "UPDATE api_usage SET rows = calls WHERE rows IS NULL"

    execute "UPDATE users SET exports_reset_at = '#{DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()}' WHERE exports_reset_at IS NULL"
  end

  def down do
    alter table(:api_usage) do
      remove :rows
    end
  end
end
