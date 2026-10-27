defmodule LSWeb.PageHTML do
  @moduledoc false
  use LSWeb, :html
  embed_templates "page_html/*"

  @doc "ClickHouse type as a customer reads it on the data dictionary."
  def friendly_type("Array(" <> _), do: "list"
  def friendly_type("Nullable(DateTime)"), do: "date"
  def friendly_type("DateTime"), do: "date"
  def friendly_type("Nullable(Float32)"), do: "number"
  def friendly_type("Nullable(" <> _), do: "number"
  def friendly_type("UInt8"), do: "flag"
  def friendly_type(_), do: "text"

  @doc "The signal column of the data dictionary."
  def signal_label(nil), do: ""
  def signal_label(:set), do: "added, removed"
  def signal_label(:set_added), do: "added"
  def signal_label(:changed), do: "changed"
  def signal_label(:started_stopped), do: "started, stopped"
  def signal_label(:down_back), do: "down, back"
  def signal_label({:pct, p}), do: "changed by #{round(p * 100)}% or more"

  # The /data page reads the dictionary by where a value comes from, which
  # is what the column prefix says. Order is the order a buyer asks: the
  # business first, then what it runs, then how it was found.
  @groups [
    {"domain", "The key", "One row per registrable domain. Everything below hangs off it."},
    {"estimated_", "What it is: the estimates", "A rule or a model produced these. Each comes with a confidence and the evidence it rests on, so a filter on a label can also ask how sure we are."},
    {"verified_", "What a registry says", "SEC EDGAR, Companies House, SIRENE, Wikidata and Y Combinator. Rare, and when present it outranks the estimate on the dashboard."},
    {"http_deep_", "The deep pass over the site", "A second, slower read: SEO score, page speed, sitemap size, printed prices."},
    {"http_", "The website", "What the homepage and the contact, about and careers pages say: title, tagline, technologies, addresses, phone, people."},
    {"shop_", "The store catalog", "Read from the public catalog of Shopify stores: products, prices, stock, theme, currency."},
    {"hr_", "The job board", "Open roles on the public careers page or the ATS, with departments and locations."},
    {"dns_", "DNS", "Mail hosting, vendors visible in SPF and DKIM, DMARC policy, addresses."},
    {"ctl_", "Certificate logs", "Where discovery starts: the first certificate, the hosts that followed."},
    {"rdap_", "The registry", "Registration dates, registrar, nameservers."},
    {"bgp_", "The hosting network", "Who announces the IP: Cloudflare, Amazon, Hetzner and the like."},
    {"rank", "Traffic and links", "Tranco and Majestic ranks, a backlink breadth measure."},
    {"news_", "News", "Funding and press, when a source reported it."}
  ]

  @doc "The data dictionary grouped by source prefix: `[{title, intro, rows}]`, every customer-facing column exactly once."
  def data_groups do
    rows = LS.Schema.Columns.doc_rows()

    {groups, left} =
      Enum.reduce(@groups, {[], rows}, fn {prefix, title, intro}, {acc, left} ->
        {mine, rest} = Enum.split_with(left, fn {name, _, _, _, _} -> group_of(name) == prefix end)
        {acc ++ [{title, intro, mine}], rest}
      end)

    groups ++ if(left == [], do: [], else: [{"Other", "", left}])
  end

  defp group_of("domain"), do: "domain"
  defp group_of("http_deep_" <> _), do: "http_deep_"
  defp group_of("tranco_" <> _), do: "rank"
  defp group_of("majestic_" <> _), do: "rank"

  defp group_of(name) do
    Enum.find_value(@groups, "Other", fn {prefix, _, _} ->
      if String.starts_with?(name, prefix) and prefix not in ["domain", "rank"], do: prefix
    end)
  end

  @doc "The tracked columns with their rule, for the signals section."
  def tracked_rows do
    for {name, rule, _type} <- LS.Schema.Columns.tracked(), do: {name, signal_label(rule), LSWeb.ExplorerLive.Format.field_label(name)}
  end

  @doc "A JSON value the way the API prints it, for the example blocks."
  def json(value), do: Jason.encode!(value, pretty: true)
end
