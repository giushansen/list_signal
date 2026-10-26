defmodule LS.Enrichment.BrowserPrivateHostTest do
  @moduledoc """
  2026-10-26: the browser sidecar gates IP-literal hosts and the requests a
  page makes, but it resolves a hostname itself, so a name pointed at
  10.0.0.x rendered an internal host. The name is resolved and checked in
  Elixir before any render.
  """
  use ExUnit.Case, async: true

  alias LS.Enrichment.Browser

  test "a name with only private addresses is not rendered" do
    refute Browser.public_host?("internal.example", fn _ -> {:ok, %{a: ["10.0.0.156"]}} end)
    refute Browser.public_host?("loop.example", fn _ -> {:ok, %{a: ["127.0.0.1", "192.168.1.2"]}} end)
  end

  test "a name with a public address among others is rendered" do
    assert Browser.public_host?("shop.example", fn _ -> {:ok, %{a: ["10.0.0.1", "104.21.68.88"]}} end)
  end

  test "a name that does not resolve, or a resolver that raises, is not rendered" do
    refute Browser.public_host?("gone.example", fn _ -> {:error, :nxdomain} end)
    refute Browser.public_host?("gone.example", fn _ -> raise "boom" end)
    refute Browser.public_host?("gone.example", fn _ -> {:ok, %{}} end)
  end
end
