defmodule LS.Verification.SourcesTest do
  @moduledoc """
  Pure extractors of pipeline 3. Third-party data is hostile until proven
  otherwise: every source gets its empty / negative / oversized / wrong-shape
  case here, and the rule is always the same — no fact beats a guessed fact.
  """
  use ExUnit.Case, async: true

  alias LS.Verification
  alias LS.Verification.Sources.{Wikidata, YC, EDGAR, CompaniesHouse, Sirene}
  alias LS.Verification.Store

  # ── Wikidata ──

  describe "Wikidata" do
    test "simplify/1 flattens bindings and strips entity URIs" do
      b = %{"item" => %{"type" => "uri", "value" => "http://www.wikidata.org/entity/Q42"},
            "rev" => %{"value" => "1200000"}, "unit" => %{"value" => "http://www.wikidata.org/entity/Q4916"}}
      assert Wikidata.simplify(b) == %{"item" => "Q42", "rev" => "1200000", "unit" => "Q4916"}
    end

    test "build_records/3: newest statement wins, USD conversion, unknown unit keeps raw only" do
      rev = [
        %{"item" => "Q1", "website" => "https://www.acme.com/", "rev" => "1000000", "unit" => "Q4916", "date" => "2022-01-01T00:00:00Z"},
        %{"item" => "Q1", "website" => "https://www.acme.com/", "rev" => "2000000", "unit" => "Q4916", "date" => "2024-01-01T00:00:00Z"},
        %{"item" => "Q2", "website" => "https://beta.example.org", "rev" => "500", "unit" => "Q999999", "date" => nil}
      ]
      emp = [%{"item" => "Q1", "website" => "https://www.acme.com/", "emp" => "250", "date" => "2023-06-01T00:00:00Z"}]
      meta = [%{"item" => "Q1", "website" => "https://www.acme.com/", "itemLabel" => "Acme Corp", "inception" => "1990-05-01T00:00:00Z",
                "industryLabel" => "software", "hqLabel" => "Berlin", "countryCode" => "DE"}]

      [q1, q2] = Wikidata.build_records(rev, emp, meta) |> Enum.sort_by(& &1.source_id)
      assert q1.website_domain == "acme.com"
      assert_in_delta q1.revenue_usd, 2_200_000, 1
      assert q1.revenue_raw =~ "2000000 Q4916 2024"
      assert q1.employees == 250
      assert q1.period == "2024"
      assert q1.extra == %{"industry" => "software", "inception" => "1990", "hq" => "Berlin", "employees_period" => "2023"}
      assert q1.country == "DE"
      assert q2.revenue_usd == nil
      assert q2.revenue_raw == "500 Q999999"
    end

    test "hostile: no website, garbage amounts, negative, absurd magnitude → dropped or no USD" do
      assert Wikidata.build_records([%{"item" => "Q1", "website" => "not a url", "rev" => "1"}], [], []) == []
      assert Wikidata.revenue_usd(%{"rev" => "abc", "unit" => "Q4917"}) == {nil, "abc Q4917"}
      assert Wikidata.revenue_usd(%{"rev" => "-5", "unit" => "Q4917"}) == {nil, "-5 Q4917"}
      assert Wikidata.revenue_usd(%{"rev" => "1e14", "unit" => "Q4917"}) == {nil, "1e14 Q4917"}
      assert Wikidata.revenue_usd(nil) == {nil, ""}
    end
  end

  # ── YC ──

  describe "YC" do
    test "algolia_opts/1 finds the public search key exactly as the site embeds it" do
      html = ~s(<script>window.AlgoliaOpts = {"app":"45BWZJ1SGC","key":"Nzll_abc-123="};</script>)
      assert YC.algolia_opts(html) == {:ok, "45BWZJ1SGC", "Nzll_abc-123="}
      assert YC.algolia_opts("<html></html>") == {:error, :no_algolia_opts}
    end

    test "record/1 keeps website, team size, batch, one-liner as mission" do
      hit = %{"name" => "DoorDash", "slug" => "doordash", "website" => "http://doordash.com", "team_size" => 8600,
              "batch" => "Summer 2013", "one_liner" => "Restaurant delivery.", "industry" => "Consumer",
              "all_locations" => "San Francisco, CA, USA", "status" => "Public", "nonprofit" => false}
      r = YC.record(hit)
      assert r.website_domain == "doordash.com"
      assert r.employees == 8600
      assert r.period == "Summer 2013"
      assert r.extra["mission"] == "Restaurant delivery."
      assert r.source_url == "https://www.ycombinator.com/companies/doordash"
    end

    test "hostile: team_size 0/negative/huge is unknown; no website → no record" do
      base = %{"slug" => "x", "website" => "https://x.com"}
      assert YC.record(Map.put(base, "team_size", 0)).employees == nil
      assert YC.record(Map.put(base, "team_size", -3)).employees == nil
      assert YC.record(Map.put(base, "team_size", 5_000_000)).employees == nil
      assert YC.record(%{"slug" => "x", "website" => ""}) == nil
      assert YC.record("garbage") == nil
    end
  end

  # ── SEC EDGAR ──

  describe "EDGAR" do
    defp fact(tag, val, fy, start, stop, form \\ "10-K", fp \\ "FY") do
      {tag, %{"val" => val, "fy" => fy, "fp" => fp, "form" => form, "start" => start, "end" => stop, "filed" => "#{fy}-03-01"}}
    end

    defp facts_json(list) do
      gaap = list |> Enum.group_by(&elem(&1, 0), &elem(&1, 1)) |> Map.new(fn {tag, vs} -> {tag, %{"units" => %{"USD" => vs}}} end)
      %{"facts" => %{"us-gaap" => gaap}}
    end

    test "extract_revenue/1: latest full fiscal year from an annual form; quarters and stubs ignored" do
      json = facts_json([
        fact("Revenues", 100, 2022, "2022-01-01", "2022-12-31"),
        fact("Revenues", 120, 2023, "2023-01-01", "2023-12-31"),
        fact("Revenues", 40, 2024, "2024-01-01", "2024-03-31", "10-Q", "Q1"),
        fact("Revenues", 999, 2024, "2024-07-01", "2024-12-31", "10-K", "FY"),
        fact("RevenueFromContractWithCustomerExcludingAssessedTax", 130, 2024, "2024-01-01", "2024-12-31")
      ])
      assert %{val: 130, fy: 2024, tag: "RevenueFromContractWithCustomerExcludingAssessedTax", form: "10-K"} = EDGAR.extract_revenue(json)
    end

    test "tag priority breaks ties on the same period end" do
      json = facts_json([
        fact("SalesRevenueNet", 5, 2024, "2024-01-01", "2024-12-31"),
        fact("Revenues", 6, 2024, "2024-01-01", "2024-12-31")
      ])
      assert EDGAR.extract_revenue(json).val == 6
    end

    test "hostile: no facts, negative, absurd, malformed dates, non-USD → nil" do
      assert EDGAR.extract_revenue(%{}) == nil
      assert EDGAR.extract_revenue(%{"facts" => %{"us-gaap" => %{}}}) == nil
      assert EDGAR.extract_revenue(facts_json([fact("Revenues", -1, 2024, "2024-01-01", "2024-12-31")])) == nil
      assert EDGAR.extract_revenue(facts_json([fact("Revenues", 1.0e14, 2024, "2024-01-01", "2024-12-31")])) == nil
      assert EDGAR.extract_revenue(facts_json([fact("Revenues", 10, 2024, "garbage", "2024-12-31")])) == nil
      eur = %{"facts" => %{"us-gaap" => %{"Revenues" => %{"units" => %{"EUR" => [%{"val" => 1, "form" => "10-K", "fp" => "FY", "start" => "2024-01-01", "end" => "2024-12-31"}]}}}}}
      assert EDGAR.extract_revenue(eur) == nil
    end

    test "record/3: US country gate only from a US state; website reduces to a domain" do
      sub = %{"name" => "ACME CORP", "website" => "https://www.acme.com", "sicDescription" => "Services",
              "addresses" => %{"business" => %{"stateOrCountry" => "CA"}}, "tickers" => ["ACME"]}
      r = EDGAR.record("0000000001", sub, %{revenue: %{val: 5.0e8, fy: 2024, end: "2024-12-31", form: "10-K", tag: "Revenues"}, employees: nil})
      assert r.country == "US"
      assert r.website_domain == "acme.com"
      assert r.revenue_usd == 5.0e8
      assert r.revenue_raw =~ "FY2024 (10-K, us-gaap:Revenues)"
      assert r.extra["industry"] == "Services"

      foreign = EDGAR.record("2", %{"name" => "X", "addresses" => %{"business" => %{"stateOrCountry" => "X0"}}}, %{revenue: nil, employees: %{val: 12, end: "2023-12-31"}})
      assert foreign.country == ""
      assert foreign.employees == 12
      assert foreign.period == "2023"
    end
  end

  # ── Companies House ──

  describe "Companies House" do
    test "parse_filename/1 pulls company number and period end from the accounts file name" do
      assert CompaniesHouse.parse_filename("Prod223_2373_00123456_20240331.html") == {:ok, "00123456", "2024-03-31"}
      assert CompaniesHouse.parse_filename("Prod224_0001_SC123456_20231231.xml") == {:ok, "SC123456", "2023-12-31"}
      assert CompaniesHouse.parse_filename("readme.txt") == :error
    end

    test "month_labels/2 names the last complete months the way the download site does" do
      assert CompaniesHouse.month_labels(~D[2026-08-18], 3) == ["July2026", "June2026", "May2026"]
      assert CompaniesHouse.month_labels(~D[2026-01-05], 2) == ["December2025", "November2025"]
    end

    test "parse_row/2 keeps UK companies and their SIC; record/2 converts turnover" do
      {:ok, idx} = LS.Verification.CSV.header_index("CompanyName,CompanyNumber,CountryOfOrigin,CompanyStatus,IncorporationDate,CompanyCategory,SICCode.SicText_1,SICCode.SicText_2")
      row = CompaniesHouse.parse_row(~s("ACME WIDGETS LIMITED",00123456,United Kingdom,Active,01/02/2010,Private Limited Company,"62012 - Software","",), idx)
      assert row.number == "00123456"
      assert row.sic == "62012 - Software"
      assert CompaniesHouse.parse_row("X,1,France,Active,,,,", idx) == nil
      assert CompaniesHouse.parse_row(~s("unbalanced,1,United Kingdom), idx) == nil

      r = CompaniesHouse.record(row, {2_000_000.0, 12, "2024-03-31"})
      assert r.country == "GB"
      assert_in_delta r.revenue_usd, 2_600_000, 1
      assert r.employees == 12
      assert r.period == "2024"
      assert r.extra["inception"] == "2010"
      assert r.website_domain == nil
    end
  end

  # ── Sirene / INPI ──

  describe "Sirene + INPI" do
    test "band_bracket/1 maps INSEE tranches onto our employee brackets" do
      assert Sirene.band_bracket("03") == "1-10"
      assert Sirene.band_bracket("12") == "11-50"
      assert Sirene.band_bracket("32") == "51-500"
      assert Sirene.band_bracket("41") == "501-5000"
      assert Sirene.band_bracket("53") == "5001+"
      assert Sirene.band_bracket("NN") == ""
      assert Sirene.band_bracket("") == ""
    end

    test "parse_unit/2 keeps active companies with a denomination, drops persons and inactive units" do
      {:ok, idx} = LS.Verification.CSV.header_index("siren,etatAdministratifUniteLegale,denominationUniteLegale,trancheEffectifsUniteLegale,anneeEffectifsUniteLegale,activitePrincipaleUniteLegale,dateCreationUniteLegale")
      u = Sirene.parse_unit("123456789,A,ACME SAS,12,2023,62.01Z,2010-02-01", idx)
      assert u == %{siren: "123456789", name: "ACME SAS", band: "12", band_year: "2023", naf: "62.01Z", created: "2010-02-01"}
      assert Sirene.parse_unit("123456789,A,,12,2023,62.01Z,2010-02-01", idx) == nil, "a person has no denomination"
      assert Sirene.parse_unit("123456789,C,ACME SAS,12,2023,62.01Z,2010-02-01", idx) == nil, "ceased"
      assert Sirene.parse_unit("12345,A,ACME SAS,12,2023,62.01Z,2010-02-01", idx) == nil, "bad SIREN"
      assert Sirene.parse_unit("123456789,A,ACME SAS,99,2023,62.01Z,2010", idx).band == ""
    end

    test "parse_ratio/2 keeps public revenue rows; garbage and negatives dropped" do
      {:ok, idx} = LS.Verification.CSV.header_index("siren;date_cloture_exercice;chiffre_d_affaires;type_bilan", ";")
      assert Sirene.parse_ratio("523816320;2023-12-31;308192;S", idx) == %{siren: "523816320", closing: "2023-12-31", revenue_eur: 308_192.0, kind: "S"}
      assert Sirene.parse_ratio("523816320;2023-12-31;;S", idx) == nil
      assert Sirene.parse_ratio("523816320;2023-12-31;-5;S", idx) == nil
      assert Sirene.parse_ratio("523816320;2023-12-31;abc;S", idx) == nil
      assert Sirene.parse_ratio("52;2023-12-31;100;S", idx) == nil
    end

    test "record/2: revenue fact is attributed to INPI, band to Sirene" do
      u = %{siren: "123456789", name: "ACME SAS", band: "12", band_year: "2023", naf: "62.01Z", created: "2010-02-01"}
      r = Sirene.record(u, {308_192.0, "2023-12-31"})
      assert r.country == "FR"
      assert r.employees_band == "11-50"
      assert_in_delta r.revenue_usd, 339_011, 1
      assert r.extra["revenue_source"] == "inpi"
      assert r.period == "2023"

      facts = Store.facts_for(Store.record_row(r, ~N[2026-08-18 00:00:00]) |> Map.put(:matched_domain, "acme.fr") |> Map.put(:match_method, "name_country"), ~N[2026-08-18 00:00:00])
      by = Map.new(facts, &{&1.fact, &1})
      assert by["revenue_usd"].source == "inpi"
      assert by["employees_band"].source == "sirene"
      assert by["employees_band"].value == "11-50"
      assert by["revenue_usd"].value == "339011"
    end
  end

  # ── Brackets + display ──

  test "brackets are the estimator's vocabulary, so verified_* filters like estimated_*" do
    for label <- ["<$1M", "$1M-$10M", "$10M-$100M", "$100M-$1B", "$1B+"] do
      assert label in LS.Revenue.Estimator.revenue_labels()
    end
    assert Verification.revenue_bracket(999_999) == "<$1M"
    assert Verification.revenue_bracket(1_000_000) == "$1M-$10M"
    assert Verification.revenue_bracket(5.0e8) == "$100M-$1B"
    assert Verification.revenue_bracket(-1) == ""
    assert Verification.employees_bracket(10) == "1-10"
    assert Verification.employees_bracket(11) == "11-50"
    assert Verification.employees_bracket(500) == "51-500"
    assert Verification.employees_bracket(501) == "501-5000"
    for label <- ["1-10", "11-50", "51-500", "501-5000", "5001+"] do
      assert label in LS.Revenue.Estimator.employee_labels()
    end
  end

  test "display/2 shows the verified value when present, else the estimate" do
    row = %{"estimated_revenue" => "$1M-$10M", "verified_revenue" => "$100M-$1B", "estimated_employees" => "1-10", "verified_employees" => ""}
    assert Verification.display(row, :revenue) == "$100M-$1B"
    assert Verification.display(row, :employees) == "1-10"
    assert Verification.verified?(row, :revenue)
    refute Verification.verified?(row, :employees)
  end
end
