defmodule LS.Cluster.WorkQueueJunkDormantTest do
  @moduledoc """
  2026-10-24: a fetched page that came back parked or as a placeholder got
  only the 7-day daily bloom, so every certificate renewal fetched it again
  (8.6K junk rows a day, a third repeats). It now sleeps in the dormant
  ring. A failed fetch (404, 5xx, timeout) is deliberately NOT put to sleep:
  for a known business that is the down/back signal customers pay for.
  """
  use ExUnit.Case, async: false

  alias LS.Cluster.{CrawlDedup, WorkQueue}
  alias LS.Reputation.Bloom

  @dormant_key {LS.Cluster.CrawlDedup, :dormant}

  setup do
    saved = :persistent_term.get(@dormant_key, nil)
    on_exit(fn -> if saved, do: :persistent_term.put(@dormant_key, saved), else: :persistent_term.erase(@dormant_key) end)
    :persistent_term.put(@dormant_key, %{blooms: for(_ <- 1..3, do: Bloom.new(10_000, 0.02)), rotated_at: System.system_time(:second)})
    Application.put_env(:ls, :dormant_ring, true)
    :ok
  end

  test "parked and placeholder pages are junk, failures and real pages are not" do
    rows = [
      %{domain: "parked.example", is_junk: "parked", http_status: 200},
      %{domain: "holder.example", is_junk: "placeholder", http_status: 200},
      %{domain: "real.example", is_junk: "", http_status: 200},
      %{domain: "down.example", is_junk: "", http_status: 503},
      %{domain: "gone.example", is_junk: "", http_status: 404},
      %{ctl_domain: "ctl-shaped.example", is_junk: "parked"},
      %{"domain" => "string-keys.example", "is_junk" => "parked"},
      %{domain: "", is_junk: "parked"},
      %{is_junk: "parked"},
      "not a map"
    ]

    assert WorkQueue.junk_domains(rows) == ["parked.example", "holder.example", "ctl-shaped.example"]
    assert WorkQueue.junk_domains([]) == []
    assert WorkQueue.junk_domains(:nope) == []
  end

  test "completing a batch puts its junk pages to sleep and leaves the rest alone" do
    rows = [
      %{domain: "parked2.example", is_junk: "parked", http_status: 200},
      %{domain: "down2.example", is_junk: "", http_status: 503}
    ]

    assert WorkQueue.remember_junk(rows) == 1
    assert CrawlDedup.dormant?("parked2.example")
    refute CrawlDedup.dormant?("down2.example")
    assert WorkQueue.remember_junk([]) == 0
    assert WorkQueue.remember_junk(nil) == 0
  end
end
