defmodule LS.Verification.IXBRLTest do
  use ExUnit.Case, async: true
  alias LS.Verification.IXBRL

  @ixbrl """
  <html xmlns:ix="http://www.xbrl.org/2013/inlineXBRL"><body>
  <ix:header><ix:resources>
    <xbrli:context id="cur"><xbrli:entity><xbrli:identifier scheme="x">00123456</xbrli:identifier></xbrli:entity>
      <xbrli:period><xbrli:startDate>2023-04-01</xbrli:startDate><xbrli:endDate>2024-03-31</xbrli:endDate></xbrli:period></xbrli:context>
    <xbrli:context id="prev"><xbrli:period><xbrli:startDate>2022-04-01</xbrli:startDate><xbrli:endDate>2023-03-31</xbrli:endDate></xbrli:period></xbrli:context>
    <xbrli:context id="seg"><xbrli:entity><xbrli:identifier scheme="x">1</xbrli:identifier>
      <xbrli:segment><xbrldi:explicitMember dimension="d">m</xbrldi:explicitMember></xbrli:segment></xbrli:entity>
      <xbrli:period><xbrli:startDate>2023-04-01</xbrli:startDate><xbrli:endDate>2024-03-31</xbrli:endDate></xbrli:period></xbrli:context>
  </ix:resources></ix:header>
  <p>Turnover <ix:nonFraction name="core:TurnoverRevenue" contextRef="cur" unitRef="GBP" decimals="0" scale="3" format="ixt:numdotdecimal">1,234</ix:nonFraction></p>
  <p>Turnover prev <ix:nonFraction name="core:TurnoverRevenue" contextRef="prev" unitRef="GBP" decimals="0" scale="3">999</ix:nonFraction></p>
  <p>Segment <ix:nonFraction name="core:TurnoverRevenue" contextRef="seg" unitRef="GBP" decimals="0" scale="3">50</ix:nonFraction></p>
  <p>Staff <ix:nonFraction contextRef="cur" name="core:AverageNumberEmployeesDuringPeriod" unitRef="pure" decimals="0">12</ix:nonFraction></p>
  <p>Loss <ix:nonFraction name="core:ProfitLoss" contextRef="cur" unitRef="GBP" sign="-" scale="0">7</ix:nonFraction></p>
  </body></html>
  """

  test "takes the current whole-entity period: latest endDate, no segment; applies scale" do
    assert IXBRL.extract(@ixbrl) == %{turnover: 1_234_000.0, employees: 12, period_end: "2024-03-31"}
  end

  test "plain (non-inline) XBRL from older filings" do
    xml = """
    <xbrli:xbrl><xbrli:context id="c1"><xbrli:period><xbrli:startDate>2015-01-01</xbrli:startDate><xbrli:endDate>2015-12-31</xbrli:endDate></xbrli:period></xbrli:context>
    <uk-gaap:TurnoverGrossOperatingRevenue contextRef="c1" unitRef="GBP" decimals="0">250000</uk-gaap:TurnoverGrossOperatingRevenue>
    <uk-gaap:AverageNumberEmployeesDuringPeriod contextRef="c1" unitRef="pure">3</uk-gaap:AverageNumberEmployeesDuringPeriod></xbrli:xbrl>
    """
    assert IXBRL.extract(xml) == %{turnover: 250_000.0, employees: 3, period_end: "2015-12-31"}
  end

  test "number/2: dashes are zero, comma-decimal format, sign, nested markup, garbage" do
    assert IXBRL.number("-", ~s(format="ixt:fixed-zero")) == {:ok, 0}
    assert IXBRL.number("1.234,50", ~s(format="ixt:numcommadecimal")) == {:ok, 1234.5}
    assert IXBRL.number("<b>1,000</b>", ~s(scale="0" sign="-")) == {:ok, -1000.0}
    assert IXBRL.number("n/a", "") == :error
    assert IXBRL.number("", "") == :error
    assert IXBRL.number("12", ~s(scale="99")) == {:ok, 12.0}
  end

  test "hostile input: empty, no contexts, Latin-1 bytes, oversized, absurd values → no fact, never a guess" do
    assert IXBRL.extract("") == %{}
    assert IXBRL.extract("<html><body>no xbrl here</body></html>") == %{}
    latin1 = "<html>caf\xE9 " <> @ixbrl
    assert IXBRL.extract(latin1).turnover == 1_234_000.0
    assert IXBRL.extract(String.duplicate("x", 31_000_000)) == %{}

    absurd = String.replace(@ixbrl, ~s|scale="3" format="ixt:numdotdecimal">1,234|, ~s|scale="12">9,999,999|)
    refute Map.has_key?(IXBRL.extract(absurd), :turnover)
    # employees stays — one bad fact does not poison the others
    assert IXBRL.extract(absurd).employees == 12
  end

  test "a fact whose context has no endDate is ignored" do
    body = String.replace(@ixbrl, "<xbrli:endDate>2024-03-31</xbrli:endDate>", "")
    assert IXBRL.extract(body).period_end == "2023-03-31"
    assert IXBRL.extract(body).turnover == 999_000.0
  end
end
