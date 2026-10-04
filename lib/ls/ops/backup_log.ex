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
  def last_ch_result(text) do
    case last_ch_run(text) do
      %{result: r} -> r
      nil -> nil
    end
  end

  @doc """
  The newest `[ch]` run as `%{result, started_at}` (`started_at` is the
  log's own timestamp, "2026-09-23 03:15:01"), or nil. The timestamp is
  what makes one failed run one alert: 2026-09-23 the same failure was
  emailed at 08:12, 14:12 and 20:27 because the key had no date in it.
  """
  @spec last_ch_run(String.t()) :: %{result: :ok | :error | :skipped | nil, started_at: String.t()} | nil
  def last_ch_run(text) when is_binary(text) do
    ch_lines = text |> String.split("\n") |> Enum.filter(&String.contains?(&1, "[ch]"))

    case Enum.reverse(ch_lines) |> Enum.split_while(&(not String.contains?(&1, "=== backup start"))) do
      {_, []} ->
        nil

      {after_start, [start | _]} ->
        # Any ERROR in the run makes it a failed run, even after "clickhouse
        # ok": on 2026-09-27 the dump succeeded and the offsite ship failed,
        # the archive sat on the master for five days, and this read :ok.
        result =
          cond do
            Enum.any?(after_start, &String.contains?(&1, "backup skipped")) -> :skipped
            Enum.any?(after_start, &String.contains?(&1, "ERROR")) -> :error
            Enum.any?(after_start, &(String.contains?(&1, "clickhouse ok") and plausible_ch_size?(&1))) -> :ok
            # A success line that reports no real archive is a failed run
            # (2026-10-04): the weekly tier asked for a table the v2 rename
            # had removed, dumped nothing, tarred the empty directory and
            # logged "clickhouse ok (12K)". This module read the week as
            # successful, so no alert fired on the age either, and an hour
            # later the retry shipped that 12 KB over the only real copy.
            Enum.any?(after_start, &String.contains?(&1, "clickhouse ok")) -> :error
            true -> nil
          end

        %{result: result, started_at: String.slice(String.trim(start), 0, 19)}
    end
  end

  def last_ch_run(_), do: nil

  @doc """
  Pure: whether a "clickhouse ok" line reports a size a real history dump
  could have. The archive has been 12G to 46.8G all year; anything in bytes,
  kilobytes or megabytes is not a backup of an 83 GiB table.

  A line this cannot read at all counts as implausible, deliberately. The
  script that writes the line lives in another repo (devops/listsignal/
  backup.sh), so a format change there must surface as a loud alert and a
  failing test here rather than as a guard that quietly stopped looking.
  Both current shapes are pinned in backup_log_size_test.
  """
  @spec plausible_ch_size?(String.t()) :: boolean()
  def plausible_ch_size?(line) when is_binary(line) do
    case Regex.run(~r/\((\d+(?:\.\d+)?)\s*([BKMGT])\b/, line) do
      [_, num, unit] when unit in ["G", "T"] ->
        case Float.parse(num) do
          {n, _} -> n >= 1.0
          :error -> false
        end

      _ ->
        false
    end
  end

  def plausible_ch_size?(_), do: false

  @doc """
  Timestamp of the newest successful `[ch]` run ("clickhouse ok"), or nil.
  Since 2026-09-24 the archive lives offsite and is deleted locally after
  the ship, so the archive's file age no longer says when the last dump
  succeeded; the log does.
  """
  @spec last_ch_ok_at(String.t()) :: String.t() | nil
  def last_ch_ok_at(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.filter(&(String.contains?(&1, "[ch]") and String.contains?(&1, "clickhouse ok") and plausible_ch_size?(&1)))
    |> List.last()
    |> case do
      nil -> nil
      line -> String.slice(String.trim(line), 0, 19)
    end
  end

  def last_ch_ok_at(_), do: nil
end
