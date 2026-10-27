defmodule LSWeb.PriceConsistencyTest do
  use LSWeb.ConnCase, async: true

  @moduledoc """
  Every surface that states a plan price must state the same one.

  2026-09-05 changed Pro from $99 to $149 "in every user-facing surface"
  and missed the homepage's JSON-LD, which is what search engines and AI
  agents quote; a reader pointed it out a week later. The pricing page is
  the source of truth here: whatever its monthly figures say, the JSON-LD
  offers, the settings page and the alternatives pages must repeat.
  """

  defp monthly_prices(html) do
    ~r/data-monthly="\$(\d+)"/ |> Regex.scan(html) |> Enum.map(fn [_, p] -> p end)
  end

  test "the homepage JSON-LD offers quote the pricing page's monthly prices" do
    pricing = build_conn() |> get("/pricing") |> html_response(200)
    [starter, pro, scale] = monthly_prices(pricing)
    # 2026-10-27: Starter $49, Pro $149, Scale $399 (LS.Plans). If the price
    # changed on purpose, update LS.Plans; every page reads from it.
    assert {starter, pro, scale} == {"49", "149", "399"}
    assert [starter, pro, scale] == Enum.map(~w(starter pro scale), &Integer.to_string(LS.Plans.monthly(&1)))

    home = build_conn() |> get("/") |> html_response(200)
    [_, ld] = Regex.run(~r|<script type="application/ld\+json">(.*?)</script>|s, home)
    offers = ld |> String.replace("\\u003c", "<") |> Jason.decode!() |> Map.fetch!("offers")
    by_name = Map.new(offers, fn o -> {o["name"], o["price"]} end)
    assert by_name == %{"Free" => "0", "Starter" => starter, "Pro" => pro, "Scale" => scale, "Done for you" => Integer.to_string(LS.Plans.monthly("dfy"))}
  end

  test "no other web surface still carries the old $99 Pro price" do
    offenders =
      for f <- Path.wildcard("lib/ls_web/**/*.{ex,heex}"),
          line <- File.read!(f) |> String.split("\n"),
          line =~ ~r/\$99\b|"price" => "99"|\b99\/mo/,
          do: "#{f}: #{String.trim(line)}"

    assert offenders == [], Enum.join(offenders, "\n")
  end
end
