defmodule LS.Email.Score do
  @moduledoc """
  How much to trust a published address, with the reasons. Pure.

  No SMTP handshake (2026-10-27, decided with the owner): the handshake is
  defeated by catch-all domains, answers identically on most Microsoft 365
  tenants, and probing from our addresses would put them on blocklists. What
  we can know from our own data is scored instead, and every point carries
  a line a customer can read:

    * where it was published: the contact, imprint or policy page, the
      homepage, an about or career page
    * what it is for the business: a person's or a role mailbox on the
      domain, a sister domain, the owner's free-mail box
    * whether the domain can receive mail: MX, a known provider, SPF, DMARC
    * how recently it was seen on the site

  Score 0 to 100. Verdicts: `strong` (75 and up), `good` (55 to 74), `weak`
  (below 55 with mail set up), `undeliverable` (no MX or a disposable host).
  Expected deliverability without a handshake, from the published-address
  measurements of 2026-10-27: strong 93 to 97%, good 85 to 92%, weak under
  85%. An address not seen on the last two crawls is the one to re-verify
  externally before sending.
  """

  @points %{
    page_contact: 20,
    page_home: 15,
    page_about: 12,
    page_other: 8,
    kind_on_domain: 15,
    kind_sister: 10,
    kind_free: 8,
    mx: 25,
    provider: 5,
    spf: 3,
    dmarc: 2,
    seen_30: 20,
    seen_90: 15,
    seen_180: 8,
    seen_365: 3
  }

  @strong 75
  @good 55

  @type facts :: %{
          required(:email) => String.t(),
          required(:domain) => String.t(),
          optional(:kind) => atom() | String.t(),
          optional(:source_page) => String.t() | nil,
          optional(:last_seen) => DateTime.t() | NaiveDateTime.t() | String.t() | nil,
          optional(:mx) => boolean(),
          optional(:provider) => String.t() | nil,
          optional(:spf) => boolean(),
          optional(:dmarc) => boolean(),
          optional(:disposable) => boolean(),
          optional(:now) => DateTime.t()
        }

  @doc "The point table, for the SQL form and the docs."
  def points, do: @points

  @doc "Score one address. Returns `%{score, verdict, evidence}`."
  @spec score(facts()) :: %{score: non_neg_integer(), verdict: String.t(), evidence: [String.t()]}
  def score(%{email: email, domain: domain} = f) when is_binary(email) and is_binary(domain) do
    kind = kind(f)
    now = Map.get(f, :now) || DateTime.utc_now()

    cond do
      kind in [:placeholder, :third_party] ->
        %{score: 0, verdict: "rejected", evidence: ["#{kind_text(kind, domain)}: not published for this business"]}

      Map.get(f, :disposable, false) ->
        %{score: 0, verdict: "undeliverable", evidence: ["disposable mail host"]}

      not Map.get(f, :mx, false) ->
        {pts, ev} = base(f, kind, domain, now)
        %{score: min(pts, 15), verdict: "undeliverable", evidence: ["no MX record: mail cannot be delivered" | ev]}

      true ->
        {pts, ev} = base(f, kind, domain, now)
        {mail_pts, mail_ev} = mail(f)
        total = min(pts + mail_pts, 100)
        %{score: total, verdict: verdict(total), evidence: ev ++ mail_ev}
    end
  end

  def score(_), do: %{score: 0, verdict: "rejected", evidence: ["no address"]}

  @doc "Verdict for a score, with mail set up."
  def verdict(s) when s >= @strong, do: "strong"
  def verdict(s) when s >= @good, do: "good"
  def verdict(_), do: "weak"

  # ── pieces ────────────────────────────────────────────────────────────────

  defp base(f, kind, domain, now) do
    {p1, e1} = page(Map.get(f, :source_page))
    {p2, e2} = {kind_points(kind), kind_text(kind, domain)}
    {p3, e3} = seen(Map.get(f, :last_seen), now)
    {p1 + p2 + p3, [e1, e2, e3]}
  end

  defp mail(f) do
    provider = Map.get(f, :provider) || ""
    known = provider not in ["", "Other"]

    pts = @points.mx + if(known, do: @points.provider, else: 0) + if(Map.get(f, :spf, false), do: @points.spf, else: 0) + if(Map.get(f, :dmarc, false), do: @points.dmarc, else: 0)

    ev =
      ["MX present" <> if(known, do: " (#{provider})", else: "")] ++
        if(Map.get(f, :spf, false), do: ["SPF published"], else: []) ++
        if(Map.get(f, :dmarc, false), do: ["DMARC published"], else: [])

    {pts, ev}
  end

  defp page(p) when p in ["contact", "legal", "policy"], do: {@points.page_contact, "published on the #{page_name(p)} page"}
  defp page("homepage"), do: {@points.page_home, "published on the homepage"}
  defp page(p) when p in ["about", "career"], do: {@points.page_about, "published on the #{p} page"}
  defp page(p) when is_binary(p) and p != "", do: {@points.page_other, "published on the #{p} page"}
  defp page(_), do: {@points.page_home, "published on the site"}

  defp page_name("legal"), do: "imprint"
  defp page_name(p), do: p

  defp kind(f) do
    case Map.get(f, :kind) do
      nil -> LS.HTTP.EmailClass.classify(f.email, f.domain)
      k when is_atom(k) -> k
      k when is_binary(k) -> String.to_existing_atom(k)
    end
  rescue
    _ -> LS.HTTP.EmailClass.classify(f.email, f.domain)
  end

  defp kind_points(:named), do: @points.kind_on_domain
  defp kind_points(:role), do: @points.kind_on_domain
  defp kind_points(:sister), do: @points.kind_sister
  defp kind_points(:free_mail), do: @points.kind_free
  defp kind_points(_), do: 0

  defp kind_text(:named, d), do: "a person's mailbox on #{d}"
  defp kind_text(:role, d), do: "a role mailbox on #{d}"
  defp kind_text(:sister, d), do: "a sister domain of #{d}"
  defp kind_text(:free_mail, _), do: "the owner's free-mail box"
  defp kind_text(:third_party, _), do: "another organisation's address"
  defp kind_text(:placeholder, _), do: "a form placeholder"
  defp kind_text(_, _), do: "unclassified"

  defp seen(nil, _now), do: {0, "seen date unknown"}

  defp seen(at, now) do
    case days_ago(at, now) do
      nil -> {0, "seen date unknown"}
      d when d <= 30 -> {@points.seen_30, "seen on the site #{d} days ago"}
      d when d <= 90 -> {@points.seen_90, "seen on the site #{d} days ago"}
      d when d <= 180 -> {@points.seen_180, "last seen #{d} days ago"}
      d when d <= 365 -> {@points.seen_365, "last seen #{d} days ago"}
      d -> {0, "last seen #{d} days ago: re-verify before sending"}
    end
  end

  defp days_ago(%DateTime{} = at, now), do: max(div(DateTime.diff(now, at, :second), 86_400), 0)
  defp days_ago(%NaiveDateTime{} = at, now), do: days_ago(DateTime.from_naive!(at, "Etc/UTC"), now)

  defp days_ago(s, now) when is_binary(s) do
    case NaiveDateTime.from_iso8601(String.replace(s, " ", "T")) do
      {:ok, ndt} -> days_ago(ndt, now)
      _ -> nil
    end
  end

  defp days_ago(_, _), do: nil

  @doc """
  The same rule as ClickHouse SQL, for the one-shot backfill over
  `businesses` (2026-10-27): one row per published address with its score,
  verdict and evidence from the compiled row and, when the depth lane or
  discovery recorded one, its contact row. The address class is the SQL
  approximation (role regex, free-mail list, host ends with the domain);
  rows are re-scored by this module at the address's next sighting.
  `shard` of `total` by domain hash.
  """
  @spec backfill_sql(non_neg_integer(), pos_integer()) :: String.t()
  def backfill_sql(shard, total) when is_integer(shard) and is_integer(total) and shard >= 0 and shard < total do
    p = @points
    free = LS.HTTP.EmailClass.free_mail_sql_list()
    role = LS.HTTP.EmailClass.role_regex_sql()

    """
    INSERT INTO #{LS.Schema.Tables.email_checks()} (domain, email, kind, score, verdict, evidence, provider, source_page, last_seen, checked_at)
    SELECT domain, email, kind, toUInt8(score), verdict, evidence, provider, source_page, last_seen, now()
    FROM (
      SELECT domain, email, kind, provider, source_page, last_seen, has_mx, disposable,
             multiIf(disposable, 0, NOT has_mx, least(base, 15), least(base + mail, 100)) AS score,
             multiIf(disposable OR NOT has_mx, 'undeliverable', score >= #{@strong}, 'strong', score >= #{@good}, 'good', 'weak') AS verdict,
             arrayFilter(x -> x != '', [
               if(disposable, 'disposable mail host', ''),
               if(NOT has_mx AND NOT disposable, 'no MX record: mail cannot be delivered', ''),
               multiIf(source_page IN ('contact', 'legal', 'policy'), concat('published on the ', if(source_page = 'legal', 'imprint', source_page), ' page'),
                       source_page = 'homepage', 'published on the homepage',
                       source_page IN ('about', 'career'), concat('published on the ', source_page, ' page'),
                       source_page != '', concat('published on the ', source_page, ' page'), 'published on the site'),
               multiIf(kind = 'named', concat('a person''s mailbox on ', domain), kind = 'role', concat('a role mailbox on ', domain),
                       kind = 'sister', concat('a sister domain of ', domain), 'the owner''s free-mail box'),
               multiIf(last_seen IS NULL, 'seen date unknown', age_days <= 90, concat('seen on the site ', toString(age_days), ' days ago'),
                       age_days <= 365, concat('last seen ', toString(age_days), ' days ago'),
                       concat('last seen ', toString(age_days), ' days ago: re-verify before sending')),
               if(has_mx, concat('MX present', if(provider NOT IN ('', 'Other'), concat(' (', provider, ')'), '')), ''),
               if(has_mx AND dmarc, 'DMARC published', '')
             ]) AS evidence
      FROM (
        SELECT domain, email, kind, provider, source_page, last_seen, has_mx, dmarc, disposable,
               dateDiff('day', ifNull(last_seen, toDateTime(0)), now()) AS age_days,
               multiIf(source_page IN ('contact', 'legal', 'policy'), #{p.page_contact}, source_page = 'homepage', #{p.page_home},
                       source_page IN ('about', 'career'), #{p.page_about}, source_page != '', #{p.page_other}, #{p.page_home})
                 + multiIf(kind IN ('named', 'role'), #{p.kind_on_domain}, kind = 'sister', #{p.kind_sister}, #{p.kind_free})
                 + multiIf(last_seen IS NULL, 0, age_days <= 30, #{p.seen_30}, age_days <= 90, #{p.seen_90}, age_days <= 180, #{p.seen_180}, age_days <= 365, #{p.seen_365}, 0) AS base,
               #{p.mx} + if(provider NOT IN ('', 'Other'), #{p.provider}, 0) + if(dmarc, #{p.dmarc}, 0) AS mail
        FROM (
          SELECT b.domain AS domain, lower(e) AS email,
                 multiIf(splitByChar('@', lower(e))[2] IN (#{free}), 'free_mail',
                         endsWith(splitByChar('@', lower(e))[2], b.domain) OR endsWith(concat('.', splitByChar('@', lower(e))[2]), concat('.', b.domain)),
                           if(match(lower(e), #{role}), 'role', 'named'),
                         splitByChar('.', splitByChar('@', lower(e))[2])[1] = splitByChar('.', b.domain)[1], 'sister', 'other') AS kind,
                 b.dns_email_provider AS provider,
                 ifNull(c.source_page, 'homepage') AS source_page,
                 coalesce(c.last_seen, b.http_last_checked_at) AS last_seen,
                 notEmpty(b.dns_mx) AS has_mx,
                 b.dns_dmarc != '' AS dmarc,
                 0 AS disposable
          FROM #{LS.Schema.Tables.businesses()} AS b
          ARRAY JOIN b.http_emails AS e
          LEFT JOIN (
            SELECT domain, email, argMax(source_page, seen_at) AS source_page, max(seen_at) AS last_seen
            FROM #{LS.Schema.Tables.http_contacts()} WHERE cityHash64(domain) % #{total} = #{shard} GROUP BY domain, email
          ) AS c ON c.domain = b.domain AND c.email = lower(e)
          WHERE cityHash64(b.domain) % #{total} = #{shard} AND b.estimated_junk = '' AND notEmpty(b.http_emails)
        )
        WHERE kind != 'other'
      )
    )
    SETTINGS max_threads = 2, max_memory_usage = 3000000000, max_execution_time = 600, join_use_nulls = 1
    """
  end
end
