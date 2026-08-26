defmodule LS.Verification.BoardDiscoveryTest do
  use ExUnit.Case, async: true

  alias LS.Verification.{BoardDiscovery, HRBoards}

  test "every CDX query targets a platform the harvester has a pattern for" do
    known = HRBoards.patterns() |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    for {platform, _q, mode} <- BoardDiscovery.queries() do
      assert platform in known, "#{platform} queried but has no slug pattern"
      assert mode in [:prefix, :domain]
    end
  end

  test "slugs are extracted from CDX result lines, reserved names dropped, case kept" do
    body = """
    {"url": "https://jobs.lever.co/Acme/307e052c-a765"}
    {"url": "https://jobs.lever.co/acme/other-posting"}
    {"url": "https://jobs.lever.co/api/health"}
    {"url": "https://jobs.lever.co/"}
    not json at all
    """

    slugs = BoardDiscovery.extract_page_slugs(body, "lever")
    assert MapSet.equal?(slugs, MapSet.new(["Acme", "acme"]))
  end

  test "workday slugs join host and site, host lowercased, site case kept" do
    body = ~s({"url": "https://Stord.wd503.myworkdayjobs.com/Stord_External_Career/job/X/Y_JR1"})
    assert BoardDiscovery.extract_page_slugs(body, "workday") |> MapSet.to_list() ==
             ["stord.wd503:Stord_External_Career"]
  end

  test "subdomain platforms extract from CC-shaped URLs" do
    body = """
    {"url": "https://accrete-ai.breezy.hr/p/00aeaa3ba280-dev"}
    {"url": "https://www.breezy.hr/pricing"}
    """

    assert BoardDiscovery.extract_page_slugs(body, "breezy") |> MapSet.to_list() == ["accrete-ai"]
  end
end
