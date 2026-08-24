defmodule LS.CTL.LogConfigsTest do
  @moduledoc """
  The poller's hardcoded log list is the one thing that silently narrows
  discovery when the CT landscape rotates: shards freeze every 6 months and a
  frozen log yields nothing while still looking configured. 2026-08-24 found
  four such logs (2026h1) still being polled with zero inflow, and seven
  Chrome-usable logs missing entirely.
  """
  use ExUnit.Case, async: true
  alias LS.CTL.{Poller, LogList}

  test "every configured log is well-formed and RFC-6962 shaped" do
    for c <- Poller.configs() do
      assert is_binary(c.name) and c.name != ""
      assert String.starts_with?(c.url, "https://")
      assert String.ends_with?(c.url, "/ct/v1"), "#{c.name}: the poller appends RFC-6962 paths to this base"
      assert c.batch_size > 0 and c.avg_entries > 0
      assert c.min_workers >= 1 and c.max_workers >= c.min_workers
    end
  end

  test "no frozen half-year shard is configured (they yield nothing)" do
    stale = Poller.configs() |> Enum.filter(&String.contains?(&1.url, "2026h1")) |> Enum.map(& &1.name)
    assert stale == [], "these shards' temporal window closed; they poll forever for zero rows: #{inspect(stale)}"
  end

  test "log names and URLs are unique — a duplicate double-polls one log" do
    names = Enum.map(Poller.configs(), & &1.name)
    urls = Enum.map(Poller.configs(), & &1.url)
    assert length(Enum.uniq(names)) == length(names)
    assert length(Enum.uniq(urls)) == length(urls)
  end

  test "the configured set matches what LogList would call 'ours' (diff has a stable base)" do
    # If diff/2 saw a differently-shaped config it would report every log as
    # new AND retired, which is how a real drift would get lost in noise.
    assert LogList.diff(Poller.configs(), []).new == []
    retired = LogList.diff(Poller.configs(), []).retired
    assert length(retired) == length(Poller.configs())
  end
end
