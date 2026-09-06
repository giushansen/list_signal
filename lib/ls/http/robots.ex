defmodule LS.HTTP.Robots do
  @moduledoc """
  robots.txt: fetch, parse, cache, and answer "may ListSignalBot fetch this
  path on this domain?".

  ## Why (2026-09-06)

  The crawler declares itself as `ListSignalBot` and `/bot` tells site owners
  that a `Disallow` in their robots.txt stops us. Until this module, nothing
  read robots.txt at all: the promise on the transparency page was not kept
  by the code, and a declared bot that ignores robots.txt is exactly what
  turns a WAF complaint into a provider abuse report (two Vultr reports in
  one week, 2026-08-28 and 2026-09-04, each ending in "mitigation or VPS
  termination"). Honouring robots.txt is the baseline every hosting
  acceptable-use policy expects of automated access, and it is cheap: one
  small extra request per crawled domain, cached for a day.

  ## Semantics (RFC 9309, the Google conventions where the RFC is silent)

  * The group(s) naming `listsignalbot` apply; otherwise the `*` group(s);
    otherwise everything is allowed.
  * Longest matching rule wins; `Allow` wins a tie. `*` is a wildcard, `$`
    anchors the end. An empty `Disallow:` allows everything.
  * A robots.txt that cannot be fetched (4xx, 5xx, timeout, no IP) allows
    everything: unreachable robots.txt is the web's default, and refusing to
    crawl on a transient error would silently drop good domains.
  * Third-party data is hostile: the file is capped at 128 KB, parsing never
    raises, and anything that is not a binary allows everything.

  Decisions are cached per domain for 24h in a size-bounded ETS table, so
  the discovery pipeline (one home page per domain) pays one robots.txt
  fetch per domain-day and the enrichment pipeline (several pages per
  business) pays it once per business.
  """

  require Logger

  @ua_token "listsignalbot"
  @table :ls_robots_cache
  @ttl_s 86_400
  @error_ttl_s 6 * 3_600
  @max_entries 200_000
  @max_bytes 128 * 1024
  @max_rules 1_000
  @fetch_timeout 8_000
  # Row: {domain, {rules, expires_at}} — age bound to $1, key to $2, the
  # LS.Cache.evict_to/3 convention.
  @age_spec {:"$2", {:_, :"$1"}}

  @type rules :: [{:allow | :disallow, String.t()}]

  # ── Gate ────────────────────────────────────────────────────────────────

  @doc "Paths that are never gated: the file that defines the gate."
  @spec exempt?(String.t() | nil) :: boolean()
  def exempt?(path), do: path in [nil, "", "/robots.txt"] or String.starts_with?(to_string(path), "/robots.txt?")

  @doc """
  `:allow` or `:disallow` for `path` on `domain`. Fetches and caches the
  domain's robots.txt on a miss (through `LS.HTTP.Client`, so the politeness
  limiter applies to the robots request as to any other). `ip` may be nil;
  the resolver is consulted then.
  """
  @spec check(String.t(), String.t() | nil, String.t()) :: :allow | :disallow
  def check(domain, ip, path) when is_binary(domain) do
    rules =
      case lookup(domain) do
        {:ok, rules} -> rules
        :miss -> fetch_and_cache(domain, ip)
      end

    if allowed?(rules, path), do: :allow, else: :disallow
  rescue
    _ -> :allow
  end

  def check(_, _, _), do: :allow

  # ── Cache ───────────────────────────────────────────────────────────────

  @doc false
  def lookup(domain) do
    ensure_table()
    now = System.system_time(:second)

    case :ets.lookup(@table, domain) do
      [{^domain, {rules, expires_at}}] when expires_at > now -> {:ok, rules}
      _ -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc false
  # Test seam and the write path: remember `rules` for `domain`.
  def seed(domain, rules, ttl_s \\ @ttl_s) do
    ensure_table()

    if :ets.info(@table, :size) >= @max_entries do
      LS.Cache.evict_to(@table, trunc(@max_entries * 0.9), @age_spec)
    end

    :ets.insert(@table, {domain, {rules, System.system_time(:second) + ttl_s}})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc false
  def forget(domain) do
    ensure_table()
    :ets.delete(@table, domain)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp ensure_table do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true, write_concurrency: true])
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp fetch_and_cache(domain, ip) do
    ip = ip || resolve(domain)

    case ip && LS.HTTP.Client.fetch(domain, ip, path: "/robots.txt", timeout: @fetch_timeout, max_bytes: @max_bytes, politeness_retries: 1) do
      {:ok, %{status: 200, body: body}} ->
        rules = parse(body)
        seed(domain, rules)
        rules

      # 4xx (most often 404): no robots.txt, everything allowed, remember for
      # the full day. 5xx / transport errors / no IP: allow, retry sooner.
      {:ok, %{status: s}} when is_integer(s) and s >= 400 and s < 500 ->
        seed(domain, [])
        []

      _ ->
        seed(domain, [], @error_ttl_s)
        []
    end
  end

  defp resolve(domain) do
    case LS.DNS.Resolver.lookup(domain) do
      {:ok, %{a: [ip | _]}} when is_binary(ip) -> ip
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # ── Parser ──────────────────────────────────────────────────────────────

  @doc """
  Parse a robots.txt body into the rules that apply to ListSignalBot.
  Pure; never raises; `[]` means everything is allowed.
  """
  @spec parse(term()) :: rules()
  def parse(body) when is_binary(body) do
    body
    |> binary_part(0, min(byte_size(body), @max_bytes))
    |> String.replace_prefix("﻿", "")
    |> String.split(~r/\r\n|\r|\n/)
    |> Enum.map(&strip_comment/1)
    |> Enum.reduce({[], [], :none}, &collect/2)
    |> pick_group()
    |> Enum.take(@max_rules)
  rescue
    _ -> []
  end

  def parse(_), do: []

  defp strip_comment(line) do
    line |> String.split("#", parts: 2) |> hd() |> String.trim()
  end

  # State: {rules_for_us, rules_for_star, current_group}
  #   current_group is :us | :star | :other | :none. A run of consecutive
  #   User-agent lines opens one group (RFC 9309 §2.2.1).
  defp collect("", state), do: state

  defp collect(line, {us, star, group} = state) do
    case String.split(line, ":", parts: 2) do
      [field, value] ->
        field = field |> String.trim() |> String.downcase()
        value = String.trim(value)
        g = close_ua_run(group)

        case field do
          "user-agent" ->
            {us, star, open_group(group, value)}

          "disallow" when g in [:us, :star] ->
            add_rule({us, star, g}, g, :disallow, value)

          "allow" when g in [:us, :star] ->
            add_rule({us, star, g}, g, :allow, value)

          # Any other directive ends the run of User-agent lines that opened
          # the group, but keeps the group itself.
          _ ->
            {us, star, g}
        end

      _ ->
        state
    end
  end

  # {:opening, g} means "still inside the User-agent lines of group g", so a
  # second User-agent line joins the same group instead of replacing it.
  defp open_group({:opening, g}, value), do: {:opening, merge_group(g, ua_kind(value))}
  defp open_group(_, value), do: {:opening, ua_kind(value)}

  defp merge_group(:us, _), do: :us
  defp merge_group(_, :us), do: :us
  defp merge_group(:star, _), do: :star
  defp merge_group(_, :star), do: :star
  defp merge_group(a, _), do: a

  defp close_ua_run({:opening, g}), do: g
  defp close_ua_run(g), do: g

  defp ua_kind(value) do
    v = value |> String.downcase() |> String.trim()

    cond do
      v == "*" -> :star
      String.contains?(v, @ua_token) -> :us
      true -> :other
    end
  end

  defp add_rule({us, star, group}, kind, rule, value) do
    g = close_ua_run(group)
    # An empty Disallow allows everything: it is not a rule (RFC 9309 §2.2.2).
    rules = if value == "", do: [], else: [{rule, value}]

    case kind do
      :us -> {us ++ rules, star, g}
      :star -> {us, star ++ rules, g}
    end
  end

  defp pick_group({us, star, _}) do
    if us == [], do: star, else: us
  end

  # ── Matcher ─────────────────────────────────────────────────────────────

  @doc """
  Is `path` allowed under `rules`? Longest match wins, `Allow` wins ties,
  no match means allowed.
  """
  @spec allowed?(rules(), String.t() | nil) :: boolean()
  def allowed?([], _), do: true

  def allowed?(rules, path) when is_list(rules) do
    path = normalize_path(path)

    rules
    |> Enum.filter(fn {_, pattern} -> matches?(pattern, path) end)
    |> Enum.max_by(fn {kind, pattern} -> {String.length(pattern), if(kind == :allow, do: 1, else: 0)} end, fn -> nil end)
    |> case do
      nil -> true
      {:allow, _} -> true
      {:disallow, _} -> false
    end
  rescue
    _ -> true
  end

  def allowed?(_, _), do: true

  defp normalize_path(nil), do: "/"
  defp normalize_path(""), do: "/"
  defp normalize_path("/" <> _ = p), do: p
  defp normalize_path(p), do: "/" <> to_string(p)

  @doc false
  # `*` matches any run of characters; a trailing `$` anchors the end.
  # Everything else is literal. Patterns are checked as prefixes, per RFC 9309.
  def matches?(pattern, path) do
    {pattern, anchored} =
      if String.ends_with?(pattern, "$"),
        do: {String.trim_trailing(pattern, "$"), true},
        else: {pattern, false}

    regex =
      pattern
      |> String.split("*")
      |> Enum.map(&Regex.escape/1)
      |> Enum.join(".*")

    Regex.match?(Regex.compile!("\\A" <> regex <> if(anchored, do: "\\z", else: "")), path)
  rescue
    _ -> false
  end
end
