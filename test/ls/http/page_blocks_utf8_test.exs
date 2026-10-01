defmodule LS.HTTP.PageBlocksUtf8Test do
  @moduledoc """
  2026-10-01, first v2 morning: pages with a stray Latin-1 byte made
  `Jason.encode!` raise on the master and the whole batch of page rows was
  dropped. 45% of eligible domains had a page; some workers 11%. A page row
  must always encode, whatever bytes the site served.
  """
  use ExUnit.Case, async: true

  alias LS.HTTP.PageBlocks

  @latin1 <<"<html><body><header><nav><a href='/'>Firmenprofil</a></nav></header><main><h1>Gr", 0xF6, "ndung</h1><p>Wir sind ein B", 0xFC, "ro in K", 0xF6, "ln.</p></main><footer><p>Tel: +49 221 1234567</p></footer>",
            "<script type='application/ld+json'>{\"@type\":\"Organization\",\"name\":\"B", 0x85, "ro\"}</script></body></html>">>

  test "a page served with invalid UTF-8 still produces an encodable row" do
    parts = PageBlocks.extract(@latin1)
    row = PageBlocks.page_row(parts, "home", "2026-10-01 10:00:00")
    assert {:ok, json} = Jason.encode(row)
    assert json =~ "Gr"
    assert json =~ "ndung"
    assert Enum.all?(row.http_body_texts, &String.valid?/1)
    assert String.valid?(row.http_jsonld)
  end

  test "scrub keeps every valid run and never raises" do
    assert PageBlocks.scrub("plain") == "plain"
    assert PageBlocks.scrub(<<"a", 0xFF, "b">>) == "ab"
    assert PageBlocks.scrub(nil) == ""
    assert PageBlocks.scrub("déjà vu") == "déjà vu"
  end
end
