defmodule LS.Verification.DomainTest do
  use ExUnit.Case, async: true
  alias LS.Verification.Domain

  describe "from_url/1 — the website tier joins on these bytes" do
    test "reduces every URL shape to the registrable domain Discovery uses" do
      assert Domain.from_url("https://www.Example.co.uk/about?x=1") == "example.co.uk"
      assert Domain.from_url("http://doordash.com") == "doordash.com"
      assert Domain.from_url("doordash.com") == "doordash.com"
      assert Domain.from_url("shop.example.com.au/") == "example.com.au"
      assert Domain.from_url("  https://Example.COM.  ") == "example.com"
      assert Domain.from_url("https://user:pw@example.org:8443/x") == "example.org"
    end

    test "refuses what is not a public hostname — never a guessed link" do
      assert Domain.from_url("http://192.168.0.1/") == nil
      assert Domain.from_url("localhost") == nil
      assert Domain.from_url("http://localhost:4000") == nil
      assert Domain.from_url("not a url") == nil
      assert Domain.from_url("") == nil
      assert Domain.from_url(nil) == nil
      assert Domain.from_url(:atom) == nil
      assert Domain.from_url("mailto:x@example.com") == nil
    end

    test "hostile input: control characters, oversized, IDN we cannot represent" do
      assert Domain.from_url("https://exam\x00ple.com") == nil
      assert Domain.from_url("https://example.com\n") == nil or Domain.from_url("https://example.com\n") == "example.com"
      assert Domain.from_url("https://" <> String.duplicate("a", 300) <> ".com") == nil
      assert Domain.from_url("https://bücher.de") == nil
    end
  end

  test "label_key/1 matches the SQL key expression: first label, hyphens removed" do
    assert Domain.label_key("acme-widgets.co.uk") == "acmewidgets"
    assert Domain.label_key("acme.com") == "acme"
  end
end
