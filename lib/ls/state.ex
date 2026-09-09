defmodule LS.State do
  @moduledoc """
  Where the node keeps state that must survive a deploy: cache snapshots and
  the crawl gate's stable-domain blooms.

  ## Why not /tmp (2026-09-09)

  `LS.CacheSnapshot` wrote to `/tmp` because it "survives a deploy but not a
  reboot". Two things were wrong with that. systemd-tmpfiles deletes files
  in `/tmp` older than 10 days on Ubuntu, so a quiet week could silently
  erase the dedup memory the snapshot exists to keep. And a shared `/tmp`
  is what stops the unit from running with `PrivateTmp=yes`, one of the
  sandbox settings the security audit asked for. `/var/lib/listsignal`
  (owned by `ls`, mode 700) is the conventional home; `LS_STATE_DIR`
  overrides it and the temp dir is the fallback so a laptop needs no setup.
  """
  require Logger

  @doc "Directory for durable node state. Always exists and is writable on return."
  @spec dir() :: Path.t()
  def dir do
    case Application.get_env(:ls, :state_dir) do
      nil -> System.tmp_dir!()
      configured -> if writable?(configured), do: configured, else: fallback(configured)
    end
  end

  defp writable?(dir) do
    probe = Path.join(dir, ".writable")
    File.mkdir_p(dir) == :ok and File.touch(probe) == :ok
  end

  defp fallback(configured) do
    Logger.warning("[STATE] #{configured} is not writable, falling back to #{System.tmp_dir!()}")
    System.tmp_dir!()
  end
end
