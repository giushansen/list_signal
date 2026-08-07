defmodule LS.GoldenSetTest do
  use ExUnit.Case, async: true

  @header "bucket,domain,url,tranco_rank,predicted_model,model_confidence,predicted_industry,predicted_revenue,revenue_confidence,is_real_business,model_ok,true_model,industry_ok,true_industry,true_revenue,notes"

  defp csv(rows), do: Enum.join([@header | rows], "\n")

  defp parse!(content) do
    path = Path.join(System.tmp_dir!(), "golden_#{System.unique_integer([:positive])}.csv")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    {:ok, rows} = LS.GoldenSet.parse(path)
    rows
  end

  test "parses quoted fields containing commas" do
    rows =
      parse!(csv([~s(model:SaaS:high,a.com,https://a.com,5,SaaS,0.9,DevTools,<$1M,0.7,y,y,,,,,"note, with comma")]))

    assert [%{"domain" => "a.com", "notes" => "note, with comma"}] = rows
  end

  test "pads short rows so partially filled sheets don't crash" do
    rows = parse!(csv(["model:SaaS:high,a.com,https://a.com,5,SaaS,0.9,,,,y,y"]))
    assert [%{"true_model" => "", "notes" => ""}] = rows
  end

  test "scores junk rate, per-class precision and confidence bands" do
    rows =
      parse!(
        csv([
          "model:SaaS:high,a.com,https://a.com,,SaaS,0.90,,,,y,y,,,,,",
          "model:SaaS:low,b.com,https://b.com,,SaaS,0.56,,,,y,n,Agency,,,,",
          "model:Ecommerce:high,c.com,https://c.com,,Ecommerce,0.85,,,,Y,y,,,,,",
          "revenue:$1M-$10M,d.com,https://d.com,,,,,$1M-$10M,0.6,n,,,,,,parked",
          "unclassified,e.com,https://e.com,,,,,,,y,,SaaS,,,,",
          # unlabeled row — must be ignored, not counted
          "model:Tool:low,f.com,https://f.com,,Tool,0.55,,,,,,,,,,"
        ])
      )

    s = LS.GoldenSet.score(rows)

    assert s.total == 6
    assert s.labeled == 5
    assert_in_delta s.junk_rate, 0.2, 0.001
    assert {"SaaS", %{n: 2, precision: +0.5}} in s.model_precision
    assert {"Ecommerce", %{n: 1, precision: 1.0}} in s.model_precision
    assert s.band_accuracy.high == %{n: 2, accuracy: 1.0}
    assert s.band_accuracy.low == %{n: 1, accuracy: 0.0}
    assert s.unclassified_real == 1
    # the report renders without raising
    assert LS.GoldenSet.format(s) =~ "Junk rate"
  end

  test "empty labels everywhere produces a zero report, not a crash" do
    rows = parse!(csv(["model:SaaS:high,a.com,https://a.com,,SaaS,0.9,,,,,,,,,,"]))
    s = LS.GoldenSet.score(rows)
    assert s.labeled == 0
    assert LS.GoldenSet.format(s) =~ "0/1 rows labeled"
  end
end
