defmodule Mix.Tasks.Ls.SchemaV2 do
  @shortdoc "Write the v2 data model migration SQL to clickhouse/migrations/025_data_model_v2.sql"
  @moduledoc """
  Generates the migration script from `LS.Schema.Migration.script/0` so the
  committed file is always what the code would produce. Run after any change
  to the column spec, the catalog or the changes rules:

      mix ls.schema_v2

  The runbook `clickhouse/migrations/025_data_model_v2.sh` applies it.
  """
  use Mix.Task

  @path "clickhouse/migrations/025_data_model_v2.sql"

  @impl true
  def run(_args) do
    File.write!(@path, LS.Schema.Migration.script())
    Mix.shell().info("wrote #{@path} (#{length(LS.Schema.Migration.statements())} statements)")
  end
end
