defmodule LS.CTL.LogConfigsTest do
  @moduledoc """
  The boot fallback source list — what the poller ingests when gstatic is
  unreachable at boot. A stale or malformed fallback silently narrows
  discovery on exactly the boots where nobody is watching, so its invariants
  are pinned here. (The primary list is live: `LS.CTL.Sources.desired/2`,
  reconciled every 6h — tested in sources_test.exs.)
  """
  use ExUnit.Case, async: true
  alias LS.CTL.{LogList, Sources}

  test "every fallback source is well-formed for its protocol" do
    for c <- Sources.fallback() do
      assert is_binary(c.name) and c.name != ""
      assert String.starts_with?(c.url, "https://")
      assert c.batch_size > 0 and c.avg_entries > 0
      assert c.min_workers >= 1 and c.max_workers >= c.min_workers

      case c.protocol do
        :rfc6962 -> assert String.ends_with?(c.url, "/ct/v1")
        :static_ct -> refute String.ends_with?(c.url, "/ct/v1")
      end
    end
  end

  test "the fallback includes static-CT sources — without them every Let's Encrypt log is invisible" do
    static = Enum.filter(Sources.fallback(), &(&1.protocol == :static_ct))
    assert length(static) >= 2
    assert Enum.any?(static, &(&1.name =~ "Let's Encrypt")), "LE only publishes via Static CT since Feb 2026"
  end

  test "no frozen half-year shard is configured (they yield nothing)" do
    stale = Sources.fallback() |> Enum.filter(&String.contains?(&1.url, "2026h1")) |> Enum.map(& &1.name)
    assert stale == [], "these shards' temporal window closed; they poll forever for zero rows: #{inspect(stale)}"
  end

  test "log names and URLs are unique — a duplicate double-polls one log" do
    names = Enum.map(Sources.fallback(), & &1.name)
    urls = Enum.map(Sources.fallback(), & &1.url)
    assert length(Enum.uniq(names)) == length(names)
    assert length(Enum.uniq(urls)) == length(urls)
  end

  test "the fallback matches what LogList would call 'ours' (diff has a stable base)" do
    # If diff/2 saw a differently-shaped config it would report every log as
    # new AND retired, which is how a real drift would get lost in noise.
    assert LogList.diff(Sources.fallback(), []).new == []
    retired = LogList.diff(Sources.fallback(), []).retired
    assert length(retired) == length(Sources.fallback())
  end

  test "static tile claims stay aligned: tile-sized batches on every static source" do
    for c <- Sources.fallback(), c.protocol == :static_ct do
      assert c.batch_size == 256, "#{c.name}: static claims must be exactly one immutable tile"
    end
  end
end
