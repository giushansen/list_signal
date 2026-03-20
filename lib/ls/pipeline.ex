defmodule LS.Pipeline do
  @moduledoc """
  Run pipeline stages independently or end-to-end.

  ## Full pipeline (like CTL → ClickHouse)

      LS.Pipeline.run("stripe.com")
      LS.Pipeline.run(["stripe.com", "github.com", "shopify.com"])

  ## Individual stages

      LS.Pipeline.dns("stripe.com")
      LS.Pipeline.http("stripe.com")
      LS.Pipeline.http("stripe.com", "104.18.0.1")   # with specific IP
      LS.Pipeline.bgp("104.18.0.1")
      LS.Pipeline.bgp(["8.8.8.8", "1.1.1.1"])
      LS.Pipeline.tech("https://stripe.com")          # fetch + detect
      LS.Pipeline.detect(body, headers)                # detect from raw data

  ## Insert into ClickHouse (master only)

      LS.Pipeline.run("stripe.com", insert: true)
      LS.Pipeline.run(["stripe.com", "github.com"], insert: true)

  All functions return plain maps — easy to inspect in IEx.
  """

  require Logger

  alias LS.DNS.{Resolver, Scorer}
  alias LS.HTTP.{Client, TechDetector, PageExtractor, DomainFilter}
  alias LS.BGP.Resolver, as: BGPResolver
  alias LS.BGP.Scorer, as: BGPScorer

  # ============================================================================
  # FULL PIPELINE
  # ============================================================================

  @doc """
  Run the complete enrichment pipeline on one or more domains.

  Options:
    - insert: true  — insert results into ClickHouse (master only)
    - verbose: true — print each stage as it completes

  ## Examples

      LS.Pipeline.run("stripe.com")
      LS.Pipeline.run(["stripe.com", "github.com"], insert: true)
      LS.Pipeline.run("shopify.com", verbose: true)
  """
  def run(domains, opts \\ []) when is_binary(domains) or is_list(domains) do
    domains = List.wrap(domains)
    verbose = Keyword.get(opts, :verbose, false)
    insert = Keyword.get(opts, :insert, false)

    worker_name = Node.self() |> Atom.to_string()

    # 1. DNS
    if verbose, do: IO.puts("⏳ DNS (#{length(domains)} domains)...")
    {dns_us, dns_results} = :timer.tc(fn ->
      domains
      |> Enum.map(fn domain ->
        case dns(domain) do
          {:ok, data} -> {domain, data}
          {:error, _} -> {domain, %{dns: %{a: [], aaaa: [], mx: [], txt: [], cname: []},
                                     scores: %{dns_web_scoring: 0, dns_email_scoring: 0,
                                                dns_budget_scoring: 0, dns_security_scoring: 0}}}
        end
      end)
      |> Map.new()
    end)
    if verbose, do: IO.puts("✅ DNS done in #{div(dns_us, 1000)}ms — #{map_size(dns_results)} resolved")

    # 2. Classify
    {http_candidates, bgp_candidates} = classify(dns_results)
    if verbose do
      IO.puts("   HTTP candidates: #{length(http_candidates)} | BGP candidates: #{length(bgp_candidates)}")
    end

    # 3. HTTP
    if verbose, do: IO.puts("⏳ HTTP (#{length(http_candidates)} domains)...")
    {http_us, http_results} = :timer.tc(fn ->
      http_candidates
      |> Enum.map(fn {domain, ip} -> {domain, http(domain, ip)} end)
      |> Map.new()
    end)
    if verbose, do: IO.puts("✅ HTTP done in #{div(http_us, 1000)}ms — #{map_size(http_results)} fetched")

    # 4. BGP
    if verbose, do: IO.puts("⏳ BGP (#{length(bgp_candidates)} IPs)...")
    {bgp_us, bgp_results} = :timer.tc(fn ->
      ips = Enum.map(bgp_candidates, fn {_, ip} -> ip end) |> Enum.uniq()
      case bgp_batch(ips) do
        {:ok, asn_map} ->
          Enum.reduce(bgp_candidates, %{}, fn {domain, ip}, acc ->
            case Map.get(asn_map, ip) do
              nil -> acc
              asn_data ->
                scores = BGPScorer.score(asn_data)
                Map.put(acc, domain, %{
                  bgp_ip: ip,
                  bgp_asn_number: asn_data.asn || "",
                  bgp_asn_org: asn_data.org || "",
                  bgp_asn_country: asn_data.country || "",
                  bgp_asn_prefix: asn_data.prefix || "",
                  bgp_web_scoring: scores.bgp_web_scoring,
                  bgp_budget_scoring: scores.bgp_budget_scoring
                })
            end
          end)
        {:error, _} -> %{}
      end
    end)
    if verbose, do: IO.puts("✅ BGP done in #{div(bgp_us, 1000)}ms — #{map_size(bgp_results)} resolved")

    # 5. Merge
    now = NaiveDateTime.utc_now() |> NaiveDateTime.to_string() |> String.slice(0, 19)

    rows = Enum.map(domains, fn domain ->
      dns_data = Map.get(dns_results, domain, %{dns: %{}, scores: %{}})
      http_data = Map.get(http_results, domain, %{})
      bgp_data = Map.get(bgp_results, domain, %{})

      merge_row(domain, dns_data, http_data, bgp_data, worker_name, now)
    end)

    # 6. Insert if requested
    if insert do
      if verbose, do: IO.puts("⏳ Inserting #{length(rows)} rows into ClickHouse...")
      LS.Cluster.Inserter.insert(rows)
      if verbose, do: IO.puts("✅ Inserted (will flush within 5s)")
    end

    # 7. Return
    if verbose do
      total_ms = div(dns_us + http_us + bgp_us, 1000)
      IO.puts("\n═══ DONE in #{total_ms}ms ═══")
    end

    case rows do
      [single] -> single
      many -> many
    end
  end

  # ============================================================================
  # DNS
  # ============================================================================

  @doc """
  DNS lookup for a single domain. Returns all record types + scores.

  ## Examples

      LS.Pipeline.dns("stripe.com")
      # => {:ok, %{dns: %{a: ["104.18.0.1", ...], mx: [...], ...}, scores: %{...}}}
  """
  def dns(domain) when is_binary(domain) do
    case Resolver.lookup(domain) do
      {:ok, dns_data} ->
        scores = Scorer.score(%{domain: domain, dns: dns_data})
        {:ok, %{dns: dns_data, scores: scores}}
      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # HTTP
  # ============================================================================

  @doc """
  HTTP fetch + tech detection + page extraction for a domain.
  If no IP provided, does DNS first to get it.

  ## Examples

      LS.Pipeline.http("stripe.com")
      LS.Pipeline.http("stripe.com", "104.18.0.1")
  """
  def http(domain, ip \\ nil) when is_binary(domain) do
    # Resolve IP if not provided
    ip = ip || resolve_ip(domain)

    case Client.fetch(domain, ip || "0.0.0.0") do
      {:ok, response} ->
        tech = TechDetector.detect(response)
        body = response.body
        {pages, emails} = PageExtractor.extract_all(body, domain)

        %{
          http_status: response.status,
          http_response_time: response[:elapsed_ms],
          http_server: get_header(response.headers, "server"),
          http_cdn: tech[:cdn] || "",
          http_blocked: tech[:blocked] || "",
          http_content_type: get_header(response.headers, "content-type"),
          http_tech: tech[:tech] |> List.wrap() |> Enum.join("|"),
          http_tools: tech[:tools] |> List.wrap() |> Enum.join("|"),
          http_is_js_site: to_string(tech[:is_js_site] || false),
          http_title: extract_title(body),
          http_meta_description: extract_meta_description(body),
          http_pages: pages || "",
          http_emails: emails || "",
          http_error: ""
        }

      {:error, reason, _} -> %{http_error: to_string(reason)}
    end
  rescue
    e -> %{http_error: "crash:#{Exception.message(e)}"}
  end

  @doc """
  Fetch a URL and detect technologies (convenience for quick checks).

  ## Examples

      LS.Pipeline.tech("stripe.com")
  """
  def tech(domain) when is_binary(domain) do
    case Client.fetch(domain, resolve_ip(domain) || "0.0.0.0") do
      {:ok, response} ->
        TechDetector.detect(response)
      {:error, reason, _} -> {:error, reason}
    end
  end

  @doc """
  Detect tech from raw body + headers (no HTTP fetch).

  ## Examples

      LS.Pipeline.detect("<html>...", [{"server", "nginx"}])
  """
  def detect(body, headers) when is_binary(body) and is_list(headers) do
    TechDetector.detect(%{body: body, headers: headers})
  end

  # ============================================================================
  # BGP
  # ============================================================================

  @doc """
  BGP/ASN lookup for a single IP or batch of IPs.

  ## Examples

      LS.Pipeline.bgp("8.8.8.8")
      # => {:ok, %{asn: "15169", org: "GOOGLE - Google LLC, US", ...}}

      LS.Pipeline.bgp(["8.8.8.8", "1.1.1.1"])
      # => {:ok, %{"8.8.8.8" => %{...}, "1.1.1.1" => %{...}}}
  """
  def bgp(ip_or_ips)

  def bgp(ip) when is_binary(ip) do
    BGPResolver.lookup(ip)
  end

  def bgp(ips) when is_list(ips) do
    bgp_batch(ips)
  end

  defp bgp_batch(ips) do
    BGPResolver.lookup_batch(ips)
  rescue
    _ -> {:error, :bgp_crash}
  end

  # ============================================================================
  # FILTER CHECK
  # ============================================================================

  @doc """
  Check if a domain would pass the HTTP crawl filter.

  ## Examples

      LS.Pipeline.should_crawl?("stripe.com")
  """
  def should_crawl?(domain) when is_binary(domain) do
    case dns(domain) do
      {:ok, data} ->
        mx = data.dns[:mx] |> List.wrap() |> Enum.join("|")
        txt = data.dns[:txt] |> List.wrap() |> Enum.join(" ")
        has_ip = data.dns[:a] |> List.wrap() |> List.first()
        result = has_ip && DomainFilter.should_crawl?(domain, mx, txt)
        %{
          would_crawl: result || false,
          has_a_record: has_ip != nil,
          has_mx: mx != "",
          has_spf: String.contains?(txt, "spf"),
          a: data.dns[:a],
          mx: data.dns[:mx]
        }
      {:error, reason} ->
        %{would_crawl: false, error: reason}
    end
  end

  # ============================================================================
  # PRIVATE HELPERS
  # ============================================================================

  defp resolve_ip(domain) do
    case Resolver.lookup(domain) do
      {:ok, %{a: [ip | _]}} -> ip
      _ -> nil
    end
  end

  defp classify(dns_results) do
    Enum.reduce(dns_results, {[], []}, fn {domain, data}, {http_acc, bgp_acc} ->
      dns = data.dns
      first_ip = dns[:a] |> List.wrap() |> List.first()

      bgp_acc = if first_ip && first_ip != "",
        do: [{domain, first_ip} | bgp_acc], else: bgp_acc

      mx_str = dns[:mx] |> List.wrap() |> Enum.join("|")
      txt_str = dns[:txt] |> List.wrap() |> Enum.join(" ")

      http_acc = if first_ip && first_ip != "" &&
                    DomainFilter.should_crawl?(domain, mx_str, txt_str),
        do: [{domain, first_ip} | http_acc], else: http_acc

      {http_acc, bgp_acc}
    end)
  end

  defp merge_row(domain, dns_data, http_data, bgp_data, worker_name, now) do
    dns = dns_data[:dns] || %{}
    scores = dns_data[:scores] || %{}

    %{
      enriched_at: now,
      worker: worker_name,
      domain: domain,
      ctl_tld: domain |> String.split(".") |> List.last() || "",
      ctl_issuer: "",
      ctl_subdomain_count: 0,
      ctl_subdomains: "",
      ctl_web_scoring: 0,
      ctl_budget_scoring: 0,
      ctl_security_scoring: 0,
      dns_a: dns[:a] |> List.wrap() |> Enum.join("|"),
      dns_aaaa: dns[:aaaa] |> List.wrap() |> Enum.join("|"),
      dns_mx: dns[:mx] |> List.wrap() |> Enum.join("|"),
      dns_txt: dns[:txt] |> List.wrap() |> Enum.join("|"),
      dns_cname: dns[:cname] |> List.wrap() |> Enum.join("|"),
      dns_web_scoring: scores[:dns_web_scoring] || 0,
      dns_email_scoring: scores[:dns_email_scoring] || 0,
      dns_budget_scoring: scores[:dns_budget_scoring] || 0,
      dns_security_scoring: scores[:dns_security_scoring] || 0,
      http_status: http_data[:http_status],
      http_response_time: http_data[:http_response_time],
      http_server: http_data[:http_server] || "",
      http_cdn: http_data[:http_cdn] || "",
      http_blocked: http_data[:http_blocked] || "",
      http_content_type: http_data[:http_content_type] || "",
      http_tech: http_data[:http_tech] || "",
      http_tools: http_data[:http_tools] || "",
      http_is_js_site: http_data[:http_is_js_site] || "",
      http_title: http_data[:http_title] || "",
      http_meta_description: http_data[:http_meta_description] || "",
      http_pages: http_data[:http_pages] || "",
      http_emails: http_data[:http_emails] || "",
      http_error: http_data[:http_error] || "",
      bgp_ip: bgp_data[:bgp_ip] || "",
      bgp_asn_number: bgp_data[:bgp_asn_number] || "",
      bgp_asn_org: bgp_data[:bgp_asn_org] || "",
      bgp_asn_country: bgp_data[:bgp_asn_country] || "",
      bgp_asn_prefix: bgp_data[:bgp_asn_prefix] || "",
      bgp_web_scoring: bgp_data[:bgp_web_scoring] || 0,
      bgp_budget_scoring: bgp_data[:bgp_budget_scoring] || 0
    }
  end

  defp get_header(headers, name) when is_list(headers) do
    case List.keyfind(headers, name, 0) do
      {_, v} -> v
      nil -> ""
    end
  end
  defp get_header(_, _), do: ""

  defp extract_title(body) do
    case Regex.run(~r/<title[^>]*>([^<]{1,500})<\/title>/is, body) do
      [_, title] -> title |> String.trim() |> String.slice(0, 200)
      _ -> ""
    end
  rescue
    _ -> ""
  end

  defp extract_meta_description(body) do
    case Regex.run(~r/<meta[^>]*name\s*=\s*["']description["'][^>]*content\s*=\s*["']([^"']{1,1000})["']/is, body) do
      [_, desc] -> desc |> String.trim() |> String.slice(0, 500)
      _ ->
        case Regex.run(~r/<meta[^>]*content\s*=\s*["']([^"']{1,1000})["'][^>]*name\s*=\s*["']description["']/is, body) do
          [_, desc] -> desc |> String.trim() |> String.slice(0, 500)
          _ -> ""
        end
    end
  rescue
    _ -> ""
  end
end
