defmodule LS.Cluster.RdapRetryTest do
  use ExUnit.Case, async: true

  @moduledoc """
  A failed RDAP lookup must stay retryable.

  2026-08-27: 47.9% of businesses had no domain creation date. Part is
  structural (DENIC and friends publish none), but .com sat at 63.5% against a
  registry that answers reliably, because the worker cached FAILURES: any
  {:error, _} called Cache.rdap_insert/1, marking the domain done for 90 days.
  A Verisign hiccup therefore froze that domain's gap through every weekly and
  monthly recrawl. The enrich_rdap error branch must never write to the cache.
  """

  test "the error branch of enrich_rdap does not mark the domain as done" do
    src = File.read!("lib/ls/cluster/worker_agent.ex")

    [_, error_branch] = String.split(src, "{:error, :rate_limited} ->", parts: 2)
    [_, after_generic_error] = String.split(error_branch, "{:error, _} ->", parts: 2)
    branch_body = after_generic_error |> String.split("end", parts: 2) |> List.first()

    refute branch_body =~ "rdap_insert",
           "caching an RDAP failure freezes the missing creation date for 90 days"
  end

  test "the success branches still cache, so politeness is unchanged" do
    src = File.read!("lib/ls/cluster/worker_agent.ex")
    assert length(String.split(src, "Cache.rdap_insert(d)")) >= 3
  end
end
