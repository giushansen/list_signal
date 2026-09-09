defmodule LSWeb.BotPageTest do
  use LSWeb.ConnCase, async: true

  @moduledoc """
  /bot is what an abuse desk reads before deciding to block or report us.
  2026-09-09: after three Vultr reports in two weeks, it lists the crawl
  addresses so our traffic can be told from a spoofed User-Agent.
  """

  test "the bot page publishes every public crawl address and no private one" do
    ips = LSWeb.PageController.crawler_ips()
    assert length(ips) == 13
    assert Enum.all?(ips, &match?({:ok, _}, :inet.parse_ipv4_address(String.to_charlist(&1))))
    refute Enum.any?(ips, &String.starts_with?(&1, "100.")), "the home node's CGNAT address is not ours to publish"
    refute "45.63.7.58" in ips, "the master does not crawl sites"

    body = build_conn() |> get("/bot") |> html_response(200)
    for ip <- ips, do: assert(body =~ ip)
    assert body =~ "ListSignalBot/1.0"
  end
end
