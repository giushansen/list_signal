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

  @type kind :: :named | :role | :free_mail | :sister | :third_party | :placeholder

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

    "(on_domain = 1 OR splitByChar('@', email)[2] IN (#{free}) OR " <>
      "splitByChar('.', splitByChar('@', email)[2])[1] = splitByChar('.', domain)[1])"
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
          # The business's own domain is never a placeholder domain, whatever
          # the list says (a test site called acme.com is still its own site).
          registrable(host) == site -> if role?(local), do: :role, else: :named
          host in @free_mail -> :free_mail
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
    local in @placeholder_locals or String.contains?(local, "xxx") or
      Regex.match?(~r/^(your|my|enter|insert|type)[-_.]?(e-?mail|name|address)/, local)
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
