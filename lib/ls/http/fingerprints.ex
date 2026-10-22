defmodule LS.HTTP.Fingerprints do
  @moduledoc """
  Data-driven technology fingerprints, the second detection layer next to
  the hand-written rules in `LS.HTTP.TechDetector` (2026-10-22).

  ## Why

  The hand-written detector names about 230 technologies and every new one
  costs a session of reading the web and editing a rule. The community
  continuation of the Wappalyzer fingerprints (github.com/enthec/
  webappanalyzer, GPL-3, 7,647 technologies) already carries the script
  hosts, meta tags, response headers and cookies that give 5,000 of them
  away. We do not ship that whole file: `priv/tech/fingerprints.json` holds
  a curated 270-odd business-relevant vendors (CRM, chat, payments, booking,
  consent, reviews, hosting, commerce platforms, builders) chosen by hand
  from it, plus a handful of vendors mined from the third-party script
  hosts of our own crawl that no public fingerprint explained (Trustindex,
  TrustedSite, Umami, CallRail, Leadoo, Unbxd, CCM19, CleanTalk). The
  selection script and the measurement live in `analysis/tech/`.

  ## What it reads, and what it refuses to

  Only strong evidence: script `src` hostnames and paths, `<meta>` name and
  content, response headers, cookie names. The upstream file also carries
  HTML regexes, JavaScript globals and DOM queries; those need a rendered
  page or match prose, so they are left out, as are patterns too short to
  name a vendor (six literal characters with a dot, slash or dash). Measured
  on the 616 cached golden homepages (v6 + v7): 79 detections on 616 pages
  and the one false positive found in review ("Website Builder" in a meta
  generator, which Wix also writes) was removed from the file.

  Every name here is also a `LS.Tech.Catalog` entry, so the closed list the
  product publishes still holds. Patterns compile once, on first use, into
  `:persistent_term`; a pattern that fails to compile is skipped and logged
  rather than taking detection down.
  """

  require Logger

  @path Path.join([:code.priv_dir(:ls) |> to_string(), "tech", "fingerprints.json"])
  @external_resource "priv/tech/fingerprints.json"
  @raw File.read!("priv/tech/fingerprints.json") |> Jason.decode!()

  @doc "Every fingerprinted name, with its category and ecosystem."
  @spec names() :: [String.t()]
  def names, do: Map.keys(@raw) |> Enum.sort()

  @doc "The raw entry for a name (patterns as strings), or nil."
  def entry(name), do: Map.get(@raw, name)

  @doc """
  Names whose evidence appears in the page. `srcs` are script src values,
  `metas` a map of lowercase meta name to content, `headers` a map of
  lowercase header name to value, `cookies` the cookie names set.
  """
  @spec detect([String.t()], %{String.t() => String.t()}, %{String.t() => String.t()}, [String.t()]) :: [String.t()]
  def detect(srcs, metas, headers, cookies) when is_list(srcs) and is_map(metas) and is_map(headers) and is_list(cookies) do
    for {name, c} <- compiled(), hit?(c, srcs, metas, headers, cookies), do: name
  rescue
    _ -> []
  end

  def detect(_, _, _, _), do: []

  defp hit?(c, srcs, metas, headers, cookies) do
    Enum.any?(c.script, fn re -> Enum.any?(srcs, &Regex.match?(re, &1)) end) or
      Enum.any?(c.meta, fn {k, res} -> (v = Map.get(metas, k)) != nil and Enum.any?(res, &Regex.match?(&1, v)) end) or
      Enum.any?(c.headers, fn {k, res} -> (v = Map.get(headers, k)) != nil and Enum.any?(res, &Regex.match?(&1, v)) end) or
      Enum.any?(c.cookies, fn k -> k in cookies end)
  end

  @doc "The compiled rule set, built on first use."
  def compiled do
    case :persistent_term.get({__MODULE__, :compiled}, nil) do
      nil ->
        c = compile_all(@raw)
        :persistent_term.put({__MODULE__, :compiled}, c)
        c

      c ->
        c
    end
  end

  defp compile_all(raw) do
    Enum.map(raw, fn {name, e} ->
      {name,
       %{
         script: compile_list(name, e["script"] || []),
         meta: compile_map(name, e["meta"] || %{}),
         headers: compile_map(name, e["headers"] || %{}),
         cookies: Enum.map(Map.keys(e["cookies"] || %{}), &String.downcase/1)
       }}
    end)
  end

  defp compile_map(name, m), do: for({k, pats} <- m, res = compile_list(name, pats), res != [], do: {String.downcase(k), res})

  defp compile_list(name, pats) do
    Enum.flat_map(pats, fn p ->
      case Regex.compile(p, "i") do
        {:ok, re} ->
          [re]

        {:error, reason} ->
          Logger.warning("[FINGERPRINTS] #{name}: pattern #{inspect(p)} skipped (#{inspect(reason)})")
          []
      end
    end)
  end

  @doc false
  def path, do: @path
end
