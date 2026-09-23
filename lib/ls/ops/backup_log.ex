defmodule LS.Ops.BackupLog do
  @moduledoc """
  Reads the result of the last ClickHouse backup run out of `backup.sh`'s
  own log, so a failed night is an alert and not a line nobody reads.

  2026-09-23: the nightly domains_history dump had failed with "No space
  left on device" on four of the last five nights, filling the master's
  disk to 100% for sixteen minutes each time (ClickHouse refused inserts,
  rows were lost). The age check on the archive file could not see it: an
  archive from three nights ago is "fresh" against a nine-day threshold.
  The log said ERROR every night. Pure over the log text; the file read is
  in `LS.Metrics.backup_status/1`.
  """

  @doc """
  `:ok`, `:error` or `:skipped` for the newest `[ch]` run in `text`, `nil`
  when the log holds no such run. Only the lines after the newest
  `=== backup start` are considered, so an old failure never outlives a
  later success.
  """
  @spec last_ch_result(String.t()) :: :ok | :error | :skipped | nil
  def last_ch_result(text) when is_binary(text) do
    ch_lines = text |> String.split("\n") |> Enum.filter(&String.contains?(&1, "[ch]"))

    case Enum.reverse(ch_lines) |> Enum.split_while(&(not String.contains?(&1, "=== backup start"))) do
      {_, []} -> nil
      {after_start, [_start | _]} ->
        cond do
          Enum.any?(after_start, &String.contains?(&1, "clickhouse ok")) -> :ok
          Enum.any?(after_start, &String.contains?(&1, "backup skipped")) -> :skipped
          Enum.any?(after_start, &String.contains?(&1, "ERROR")) -> :error
          true -> nil
        end
    end
  end

  def last_ch_result(_), do: nil
end
