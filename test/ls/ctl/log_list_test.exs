defmodule LS.CTL.LogListTest do
  use ExUnit.Case, async: true
  alias LS.CTL.LogList

  @configs [
    %{name: "Google Argon 2026h2", url: "https://ct.googleapis.com/logs/us1/argon2026h2/ct/v1"},
    %{name: "Cloudflare Nimbus 2026", url: "https://ct.cloudflare.com/logs/nimbus2026/ct/v1"}
  ]

  test "diff matches logs across the /ct/v1 suffix and trailing-slash differences" do
    usable = [
      %{description: "Google 'Argon2026h2'", url: "https://ct.googleapis.com/logs/us1/argon2026h2/"},
      %{description: "Cloudflare 'Nimbus2026'", url: "https://ct.cloudflare.com/logs/nimbus2026/"}
    ]
    assert LogList.diff(@configs, usable) == %{new: [], retired: []}
  end

  test "a usable log we don't poll is NEW; a polled log gone from the list is RETIRED" do
    usable = [
      %{description: "Google 'Argon2026h2'", url: "https://ct.googleapis.com/logs/us1/argon2026h2/"},
      %{description: "Sectigo 'Tiger2026h2'", url: "https://tiger2026h2.ct.sectigo.com/"}
    ]
    d = LogList.diff(@configs, usable)
    assert d.new == ["Sectigo 'Tiger2026h2'"]
    assert d.retired == ["Cloudflare Nimbus 2026"]
  end

  test "parse/2 keeps only usable logs whose temporal window covers the date" do
    operators = [%{"logs" => [
      %{"description" => "Live", "url" => "https://a/", "state" => %{"usable" => %{}},
        "temporal_interval" => %{"start_inclusive" => "2026-07-01T00:00:00Z", "end_exclusive" => "2027-01-01T00:00:00Z"}},
      %{"description" => "Expired H1", "url" => "https://b/", "state" => %{"usable" => %{}},
        "temporal_interval" => %{"start_inclusive" => "2026-01-01T00:00:00Z", "end_exclusive" => "2026-07-01T00:00:00Z"}},
      %{"description" => "Retired state", "url" => "https://c/", "state" => %{"retired" => %{}}}
    ]}]
    got = LogList.parse(operators, ~D[2026-08-23]) |> Enum.map(& &1.description) |> Enum.sort()
    assert got == ["Live"]
  end
end
