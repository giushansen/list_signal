defmodule LS.HTTP.EmailClass do
  @moduledoc """
  What kind of address is this, for the business it was found on? Pure.

  Measured 2026-10-26 on live rows through the connector: of twelve ICP
  businesses (US agencies, small Shopify stores) not one had a named
  address, and the hour's change feed carried form placeholders scraped as
  real addresses (`name@company.com`, `name@email.com`, `john@mydomain.com`,
  `your.email@yourfacility.org`), third-party addresses with no label
  (`press@gymshark.com` on an unrelated store) and sister-domain addresses
  mixed in with the rest. Every address is classified at write time and
  only the sellable kinds reach `http_emails`:

    * `:named`      a person's mailbox on the business's own domain
    * `:role`       info@, hello@, sales@... on the business's own domain
    * `:free_mail`  gmail, outlook, yahoo...: for a small business that is
                    the owner's own mailbox, which is what a buyer wants
    * `:sister`     the same name under another suffix (acme.co for
                    acme.com): the same organisation
    * `:third_party` someone else's domain: a payment provider, the agency
                    that built the site, a parent company. Not sold.
    * `:placeholder` a form hint, never a mailbox. Dropped.
    * `:unattended` noreply@, bounce@, notifications@: a mailbox nobody
                    reads. Dropped (2026-10-30).
    * `:tracking`   a Sentry or ingest key scraped as an address
                    (`<32 hex>@sentry.<host>`). Dropped (2026-10-30).
    * `:disposable` a throwaway mail host. Dropped (2026-10-30).

  2026-10-30: the backfill of 10-27 had scored `youremail@mail.com`,
  `esempio2@email.com`, `your@email.com` and Sentry keys on the business's
  own subdomain as `good` or `strong`, about 250 K rows, because the SQL
  form of this rule knew the free-mail list and nothing else, and the live
  path let the generic locals through on free hosts. The rejection rules
  now live here once, in Elixir and in `rejected_reason_sql/1`, so the fold,
  the backfill and the live scorer agree.

  `email_pattern/1` reads the shape of the named addresses: `{first}`,
  `{first}.{last}`, `{f}{last}`, `{first}{last}` or `{first}_{last}`,
  with how many addresses support it. No names are matched against it;
  that is as far as the local part alone can say.
  """

  @sellable [:named, :role, :free_mail, :sister]

  @role_parts ~w(info hello hi hey contact contacts sales support help team office press media pr
                 careers jobs hr jobs recruiting recruitment billing accounts accounting finance
                 marketing partnerships partners partner legal privacy dpo compliance security
                 webmaster service services customerservice customer-service customercare care cs
                 orders order bookings booking reservations reservation enquiries enquiry inquiries
                 inquiry mail email office admin administrator general welcome newsletter news
                 feedback ideas questions ask shop store sales-team team-sales success onboarding
                 invoices invoice noreply no-reply donotreply do-not-reply notifications alerts
                 abuse postmaster hostmaster root sysadmin it tech technical dev developers api
                 social community events editor editorial studio design wholesale trade b2b
                 export import ventas contacto soporte kontakt vertrieb bestellung buchhaltung
                 contatto vendite assistenza bonjour contato vendas suporte
                 discover success welcome start grow learn explore connect chat talk book buy join
                 apply hire enquire aloha hola hallo ciao howdy go now yes love care wow)

  @free_mail ~w(gmail.com googlemail.com yahoo.com yahoo.co.uk yahoo.fr yahoo.de yahoo.es yahoo.it
                yahoo.ca yahoo.com.au yahoo.com.br ymail.com rocketmail.com hotmail.com hotmail.co.uk
                hotmail.fr hotmail.de hotmail.es hotmail.it outlook.com outlook.fr outlook.de live.com
                live.co.uk live.fr live.de live.nl msn.com icloud.com me.com mac.com aol.com
                protonmail.com proton.me pm.me gmx.com gmx.de gmx.net gmx.at gmx.ch web.de t-online.de
                freenet.de yandex.com yandex.ru mail.ru bk.ru inbox.ru list.ru qq.com 163.com 126.com
                sina.com foxmail.com naver.com daum.net hanmail.net orange.fr wanadoo.fr free.fr
                laposte.net sfr.fr bbox.fr bluewin.ch sunrise.ch btinternet.com sky.com virginmedia.com
                comcast.net att.net verizon.net sbcglobal.net cox.net charter.net bell.net rogers.com
                shaw.ca telus.net bigpond.com optusnet.com.au xtra.co.nz ziggo.nl kpnmail.nl home.nl
                telenet.be skynet.be libero.it tiscali.it virgilio.it alice.it tin.it uol.com.br
                bol.com.br terra.com.br globo.com zoho.com zohomail.com hey.com fastmail.com
                tutanota.com tuta.io mailbox.org posteo.de mail.com email.com usa.com)

  @placeholder_locals ~w(name your yourname your.name yourname your.email youremail your-email
                         e-mail emailaddress email.address address johndoe jane.doe john.doe
                         firstname firstname.lastname first.last first_last lastname
                         user username someone somebody myemail my.email test tester
                         example sample demo xxx xxxx abc placeholder enter.email enteremail
                         insert.email insertemail type.email typeemail you yours yourmail your.mail
                         nome seuemail seu.email votre.email votreemail ihre.email ihreemail)

  @placeholder_domains ~w(company.com email.com mydomain.com domain.com yourdomain.com
                          yourcompany.com your-company.com yourcompany.co institution.com
                          yourfacility.org facility.org site.com website.com yoursite.com
                          yourwebsite.com abc.com test.com testing.com xyz.com acme.com
                          placeholder.com sample.com address.com emailaddress.com mail.com
                          example.com example.org example.net example.co.uk e-mail.com
                          emailprovider.com provider.com yourbusiness.com business.com
                          domain.co domain.tld tld.com companyname.com company.co
                          email.address your.domain yourdomain.co yourname.com name.com)

  # Placeholder locals in the other languages the crawl meets, bare or with
  # a digit suffix (esempio2@, test3@). "email", "mail" and "info" are real
  # role mailboxes on a business's own domain; on a free host they are a
  # form hint (mail@gmail.com), see `generic_on_free?/1`.
  @placeholder_prefixes ~w(esempio exemple beispiel ejemplo exemplo voorbeeld example sample
                           test demo user usuario utente benutzer utilisateur name nome nom
                           nombre your yours yourname myemail mustermann jdoe tucorreo tuemail
                           correo votremail votre_email ihremail deine-email deineemail)
  @placeholder_people ~w(max.mustermann jean.dupont mario.rossi juan.perez john.smith jane.smith
                         j.doe prenom.nom vorname.nachname nom.prenom first.name last.name)
  @generic_locals ~w(email e-mail mail info contact test user name admin post)

  # Nobody reads these. A campaign that writes to noreply@ burns a send.
  @unattended_re ~r/^(no-?reply|noreply|do-?not-?reply|donotreply|mailer-daemon|bounces?|notifications?|alerts?|no_reply|auto-?reply|autoresponder)([-_.+][a-z0-9]*)?$/

  # Throwaway hosts seen on business sites. Short on purpose: a business
  # publishing a disposable address is rare, and every name here is one a
  # customer would recognise as such.
  @disposable ~w(mailinator.com guerrillamail.com guerrillamail.net sharklasers.com 10minutemail.com
                 10minutemail.net yopmail.com yopmail.fr trashmail.com trashmail.de trash-mail.com
                 getnada.com nada.email dispostable.com maildrop.cc throwawaymail.com temp-mail.org
                 tempmail.com tempmail.net tempmailo.com fakeinbox.com mohmal.com emailondeck.com
                 mintemail.com tempr.email discard.email spamgourmet.com mailnesia.com mailcatch.com
                 inboxkitten.com burnermail.io 33mail.com tempail.com luxusmail.org crazymailing.com
                 mailsac.com mailtemp.net moakt.com tmpmail.org tmpmail.net emailfake.com
                 fakemail.net mytemp.email tempinbox.com jetable.org guerrillamailblock.com
                 spam4.me mail-temporaire.fr yopmail.net cool.fr.nf jetable.fr.nf nospam.ze.tc
                 nomail.xl.cx mega.zik.dj speed.1s.fr courriel.fr.nf moncourrier.fr.nf monemail.fr.nf
                 monmail.fr.nf)

  @type kind :: :named | :role | :free_mail | :sister | :third_party | :placeholder | :unattended | :tracking | :disposable

  @doc "The kinds that may be published in `http_emails`."
  def sellable, do: @sellable

  @doc """
  The same rule as SQL over an `http_contacts` row (`domain`, `email`,
  `on_domain`), for the compaction fold: an address written by the depth
  lane is published only if it is on the domain, a free-mail owner, or a
  sister domain. Before 2026-10-26 every contact row reached
  `http_emails`, third parties included (press@gymshark.com on an
  unrelated store).
  """
  @spec sellable_sql() :: String.t()
  def sellable_sql do
    free = Enum.map_join(@free_mail, ", ", &"'#{&1}'")

    # Shape pinned by worker_child_rows_test: starts with "(on_domain = 1 OR".
    "(on_domain = 1 OR splitByChar('@', email)[2] IN (#{free}) OR " <>
      "splitByChar('.', splitByChar('@', email)[2])[1] = splitByChar('.', domain)[1]) " <>
      "AND #{rejected_reason_sql("email", "domain")} = ''"
  end

  @doc """
  A ClickHouse expression over an address expression: the reason the
  address can never be a contact, or '' when it may be one. The SQL twin of
  the rejecting branches of `classify/2`, so the compaction fold (what
  reaches `http_emails`), the backfill (`LS.Email.Score.backfill_sql/3`)
  and the live scorer refuse the same addresses. Reasons, in the order
  tested: "a form placeholder, not a mailbox", "an unattended mailbox",
  "a tracking identifier, not a mailbox", "disposable mail host".
  """
  @spec rejected_reason_sql(String.t(), String.t() | nil) :: String.t()
  def rejected_reason_sql(expr, domain_expr \\ nil) do
    local = "splitByChar('@', lower(#{expr}))[1]"
    host = "splitByChar('@', lower(#{expr}))[2]"
    # The business's own domain is never a placeholder host (acme.com is on
    # the list; jane@acme.com on acme.com is a person), same as classify/2.
    own = if domain_expr, do: " AND NOT (#{host} = #{domain_expr} OR endsWith(#{host}, concat('.', #{domain_expr})))", else: ""
    free = free_mail_sql_list()
    placeholder_hosts = Enum.map_join(@placeholder_domains, ", ", &"'#{&1}'")
    disposable = Enum.map_join(@disposable, ", ", &"'#{&1}'")
    generic = Enum.map_join(@generic_locals, ", ", &"'#{&1}'")

    "multiIf(" <>
      "#{local} IN (#{placeholder_locals_sql_list()}) OR match(#{local}, #{placeholder_local_regex_sql()}) " <>
      "OR ((#{host} IN (#{placeholder_hosts}) OR startsWith(#{host}, 'example.'))#{own}) " <>
      "OR (#{host} IN (#{free}) AND #{local} IN (#{generic})), 'a form placeholder, not a mailbox', " <>
      "match(#{local}, #{unattended_regex_sql()}), 'an unattended mailbox', " <>
      "match(#{local}, '^[0-9a-f]{20,}$') OR #{host} LIKE '%sentry%' OR #{host} LIKE '%.ingest.%', 'a tracking identifier, not a mailbox', " <>
      "#{host} IN (#{disposable}), 'disposable mail host', '')"
  end

  @doc "The placeholder locals as a quoted SQL list."
  def placeholder_locals_sql_list, do: Enum.map_join(@placeholder_locals ++ @placeholder_people, ", ", &"'#{&1}'")

  @doc "A ClickHouse regex literal for the placeholder local shapes (word plus optional digits, your-email forms, xxx)."
  def placeholder_local_regex_sql do
    prefixes = @placeholder_prefixes |> Enum.map(&Regex.escape/1) |> Enum.join("|")
    "'^((#{prefixes})[0-9]*|(your|my|enter|insert|type)[-_.]?(e-?mail|name|address).*|.*xxx.*)$'"
  end

  @doc "A ClickHouse regex literal for unattended mailboxes (noreply@, bounce@...)."
  def unattended_regex_sql, do: "'#{Regex.source(@unattended_re)}'"

  @doc "The free-mail hosts as a quoted SQL list."
  @spec free_mail_sql_list() :: String.t()
  def free_mail_sql_list, do: Enum.map_join(@free_mail, ", ", &"'#{&1}'")

  @doc "A ClickHouse regex literal matching a role mailbox's local part, for SQL filters."
  @spec role_regex_sql() :: String.t()
  def role_regex_sql do
    parts = @role_parts |> Enum.map(&Regex.escape/1) |> Enum.join("|")
    "'^(#{parts})[-_.+]?[a-z0-9]*@'"
  end

  @doc """
  The predicate behind `has_named_email` on every surface (2026-10-27):
  at least one address on the company's own domain whose local part is
  not a role mailbox. Approximate in SQL, the role list without the
  sister-domain or free-mail reasoning of `classify/2`, and the same
  text in the dashboard, the CSV, the API and the MCP so the four agree.
  """
  @spec named_email_sql() :: String.t()
  def named_email_sql do
    "arrayExists(e -> NOT match(e, #{role_regex_sql()}) AND endsWith(splitByChar('@', e)[2], domain), http_emails)"
  end

  @doc "Classify one address for the business at `domain`."
  @spec classify(String.t(), String.t()) :: kind()
  def classify(email, domain) when is_binary(email) and is_binary(domain) do
    email = email |> String.trim() |> String.downcase()
    site = registrable(domain)

    case String.split(email, "@") do
      [local, host] when local != "" and host != "" ->
        host = String.trim_trailing(host, ".")

        cond do
          placeholder_local?(local) -> :placeholder
          Regex.match?(@unattended_re, local) -> :unattended
          tracking?(local, host) -> :tracking
          # The business's own domain is never a placeholder domain, whatever
          # the list says (a test site called acme.com is still its own site).
          registrable(host) == site -> if role?(local), do: :role, else: :named
          host in @disposable -> :disposable
          host in @free_mail -> if generic_on_free?(local), do: :placeholder, else: :free_mail
          placeholder_domain?(host) -> :placeholder
          sister?(registrable(host), site) -> :sister
          true -> :third_party
        end

      _ ->
        :placeholder
    end
  end

  def classify(_, _), do: :placeholder

  @doc "Keep the sellable addresses, classified, in the order given."
  @spec sellable_emails([String.t()], String.t()) :: [String.t()]
  def sellable_emails(emails, domain) when is_list(emails) and is_binary(domain) do
    emails
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.uniq()
    |> Enum.filter(&(classify(&1, domain) in @sellable))
  end

  def sellable_emails(_, _), do: []

  @doc """
  The naming pattern behind the named addresses, with its support.

      iex> LS.HTTP.EmailClass.email_pattern(["phillip@x.com", "joseph@x.com", "info@x.com"])
      {"{first}", 2}

  Nil when fewer than one named address agrees; ties go to the shape with
  more support, then to the more specific one.
  """
  @spec email_pattern([String.t()]) :: {String.t(), pos_integer()} | nil
  def email_pattern(emails) when is_list(emails) do
    emails
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.map(&local_part/1)
    |> Enum.reject(&(is_nil(&1) or role?(&1)))
    |> Enum.map(&shape/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {shape, n} -> {-n, specificity(shape)} end)
    |> List.first()
  end

  def email_pattern(_), do: nil

  # ── private ───────────────────────────────────────────────────────────────

  defp placeholder_local?(local) do
    local in @placeholder_locals or local in @placeholder_people or String.contains?(local, "xxx") or
      Regex.match?(~r/^(your|my|enter|insert|type)[-_.]?(e-?mail|name|address)/, local) or
      Regex.match?(placeholder_prefix_re(), local)
  end

  defp placeholder_prefix_re do
    prefixes = @placeholder_prefixes |> Enum.map(&Regex.escape/1) |> Enum.join("|")
    ~r/^(#{prefixes})[0-9]*$/
  end

  # mail@gmail.com, info@yahoo.com: a form hint on a free host, never the owner.
  defp generic_on_free?(local), do: (local |> String.split("+") |> hd()) in @generic_locals

  # A Sentry or ingest key scraped as an address: 32 hex characters at a
  # sentry.<host> or oNNN.ingest.<host> address, on the business's own
  # subdomain or anyone else's.
  defp tracking?(local, host) do
    Regex.match?(~r/^[0-9a-f]{20,}$/, local) or String.contains?(host, "sentry") or String.contains?(host, ".ingest.")
  end

  defp placeholder_domain?(host), do: host in @placeholder_domains or String.starts_with?(host, "example.")

  defp role?(local) do
    base = local |> String.split("+") |> hd()
    base in @role_parts or Regex.match?(~r/^(info|contact|sales|support|hello|team|office|admin|press|careers|jobs|hr|billing|help|service|customer|order|booking|enquir|inquir|marketing|partner|legal|privacy|no-?reply|donotreply|newsletter|webmaster|postmaster)[-_.]?[a-z0-9]*$/, base)
  end

  defp sister?(a, b) when is_binary(a) and is_binary(b) do
    la = label(a)
    lb = label(b)
    la != "" and la == lb and a != b
  end

  defp sister?(_, _), do: false

  # The registrable part: "shop.acme.co.uk" -> "acme.co.uk", "acme.com" -> "acme.com".
  defp registrable(host) do
    parts = host |> String.downcase() |> String.trim_trailing(".") |> String.split(".")

    case parts do
      [_] -> host
      [_, _] -> Enum.join(parts, ".")
      _ ->
        if two_level_suffix?(Enum.take(parts, -2)),
          do: parts |> Enum.take(-3) |> Enum.join("."),
          else: parts |> Enum.take(-2) |> Enum.join(".")
    end
  end

  @two_level ~w(co.uk org.uk ac.uk gov.uk com.au net.au org.au co.nz com.br com.mx com.ar co.jp
                co.kr com.sg com.hk com.tw co.za co.in com.cn com.tr com.ua co.il com.pl com.pe
                com.co com.ve com.ec com.uy com.py com.bo com.gt com.sv com.hn com.ni com.pa
                com.do com.pr com.my com.ph com.vn co.th co.id com.ng com.eg com.sa com.qa)
  defp two_level_suffix?([a, b]), do: "#{a}.#{b}" in @two_level
  defp two_level_suffix?(_), do: false

  defp label(host), do: host |> String.split(".") |> hd()

  defp local_part(email) do
    case String.split(email, "@") do
      [local, _] when local != "" -> local |> String.split("+") |> hd()
      _ -> nil
    end
  end

  # The shape of a local part. Anything with digits or over 30 characters
  # is not a naming pattern.
  defp shape(local) do
    cond do
      String.length(local) > 30 or Regex.match?(~r/[0-9]/, local) -> nil
      Regex.match?(~r/^[a-z]+\.[a-z]+$/, local) -> "{first}.{last}"
      Regex.match?(~r/^[a-z]+_[a-z]+$/, local) -> "{first}_{last}"
      Regex.match?(~r/^[a-z]+-[a-z]+$/, local) -> "{first}-{last}"
      Regex.match?(~r/^[a-z]{1}[a-z]{3,}$/, local) and String.length(local) >= 9 -> "{first}{last}"
      Regex.match?(~r/^[a-z]{2,8}$/, local) -> "{first}"
      Regex.match?(~r/^[a-z]+$/, local) -> "{first}{last}"
      true -> nil
    end
  end

  defp specificity("{first}.{last}"), do: 0
  defp specificity("{first}_{last}"), do: 1
  defp specificity("{first}-{last}"), do: 2
  defp specificity("{first}{last}"), do: 3
  defp specificity("{first}"), do: 4
  defp specificity(_), do: 9
end
