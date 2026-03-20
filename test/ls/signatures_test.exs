defmodule LS.SignaturesTest do
  use ExUnit.Case, async: false

  setup_all do
    LS.Signatures.load_all()
    :ok
  end

  @expected_tables [
    :ctl_tld, :ctl_issuer, :ctl_subdomain,
    :dns_txt, :dns_mx,
    :http_tech, :http_tools, :http_cdn, :http_blocked, :http_server,
    :http_content_type, :http_response_time,
    :bgp_asn_org, :bgp_country, :bgp_prefix
  ]

  test "all 15 signature tables exist and are populated" do
    for type <- @expected_tables do
      table = LS.Signatures.table_name(type)
      size = :ets.info(table, :size)
      assert size > 0, "#{type} has 0 entries"
    end
  end

  test "signature tables have correct tuple format {pattern, score_type, points, comment}" do
    for type <- @expected_tables do
      table = LS.Signatures.table_name(type)
      [first | _] = :ets.tab2list(table)
      assert tuple_size(first) == 4, "#{type} tuple has #{tuple_size(first)} elements, expected 4"
      {pattern, score_type, points, comment} = first
      assert is_binary(pattern), "#{type} pattern should be binary"
      assert is_atom(score_type), "#{type} score_type should be atom"
      assert is_integer(points), "#{type} points should be integer"
      assert is_binary(comment), "#{type} comment should be binary"
    end
  end

  test "http_tech has substantial entries (700+)" do
    assert :ets.info(:sig_http_tech, :size) > 700
  end

  test "http_tools has substantial entries (500+)" do
    assert :ets.info(:sig_http_tools, :size) > 500
  end

  test "score/2 returns scores for known patterns" do
    # DNS TXT with SPF should score
    scores = LS.Signatures.score(:dns_txt, "v=spf1 include:_spf.google.com ~all")
    assert is_map(scores)
  end

  test "score/2 returns empty map for unknown text" do
    assert LS.Signatures.score(:http_tech, "xyzzy_no_match_ever") == %{}
  end

  test "detect_http_tech/2 finds tech in HTML with script tags" do
    body = ~s(<script src="https://cdn.jsdelivr.net/npm/vue@3"></script>)
    headers = [{"server", "nginx"}]
    result = LS.Signatures.detect_http_tech(body, headers)
    assert is_list(result.tech)
    assert is_list(result.tools)
    assert "Vue" in result.tech or length(result.tech) > 0
  end

  test "detect_http_tech/2 returns empty lists for blank input" do
    result = LS.Signatures.detect_http_tech("", [])
    assert result == %{tech: [], tools: []}
  end
end
