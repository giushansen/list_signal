defmodule LS.DNS.Vendors do
  @moduledoc """
  Vendors a domain's DNS gives away, as one rule list that produces both the
  Elixir functions and the ClickHouse expressions (data model v2, 2026-10-01).

  Two product columns come out of it:

    * `dns_email_provider`: who hosts the mailboxes, from the MX hosts. One
      value per domain. "Other" when MX records exist but match no known
      provider, "" when there is no MX at all.
    * `dns_tech`: every other vendor visible in DNS: email senders from SPF
      includes, security gateways in MX, SaaS tools from their TXT
      verification records, CNAME targets. Mailbox providers are not
      repeated here.

  The rule list is the single source: `email_provider/1` and `tech/3` run on
  the worker's lists, `email_provider_sql/1` and `tech_sql/3` run inside the
  compactor fold over the stored `dns_mx`, `dns_txt` and `dns_cname` strings,
  so a backfill is a full rebuild and nothing else. Both sides match case
  insensitively on substrings; a test asserts they agree.
  """

  # {provider, [mx substrings]}. Order matters only for a domain with two
  # providers' MX records at once, which is a migration in progress.
  @providers [
    {"Google Workspace", ["aspmx.l.google.com", "googlemail.com", "aspmx2.googlemail", "google.com"]},
    {"Microsoft 365", ["mail.protection.outlook.com", "outlook.com", "eo.outlook.com"]},
    {"Zoho Mail", ["zoho.com", "zoho.eu", "zoho.in", "zohomail"]},
    {"Proton Mail", ["protonmail.ch", "proton.me"]},
    {"Fastmail", ["messagingengine.com", "fastmail.com"]},
    {"iCloud Mail", ["icloud.com"]},
    {"Yandex 360", ["mx.yandex.net", "yandex.ru"]},
    {"OVH Mail", ["mail.ovh.net", "mx.ovh.net"]},
    {"IONOS Mail", ["ionos.", "kundenserver.de", "1and1.com"]},
    {"GoDaddy Mail", ["secureserver.net"]},
    {"Rackspace Email", ["emailsrvr.com"]},
    {"Cloudflare Email Routing", ["mx.cloudflare.net"]},
    {"Gandi Mail", ["gandi.net"]},
    {"Infomaniak Mail", ["infomaniak.ch"]},
    {"Hostinger Mail", ["hostinger.com", "titan.email"]},
    {"Mimecast", ["mimecast.com", "mimecast-offshore"]},
    {"Proofpoint", ["pphosted.com", "ppe-hosted.com"]},
    {"Barracuda", ["barracudanetworks.com"]},
    {"Cisco Email Security", ["iphmx.com"]},
    {"Hornetsecurity", ["hornetsecurity.com", "antispameurope"]},
    {"Sophos Email", ["sophos.com"]}
  ]

  # {vendor, [substrings matched in TXT, MX and CNAME together]}.
  @tech [
    {"Mailchimp", ["servers.mcsv.net", "mailchimp"]},
    {"SendGrid", ["sendgrid.net"]},
    {"Salesforce", ["_spf.salesforce.com", "spf.pardot.com", "exacttarget.com", "pardot"]},
    {"Marketo", ["mktomail.com", "marketo"]},
    {"HubSpot", ["hubspot-developer-verification", "_spf.hubspot", "hubspot"]},
    {"Klaviyo", ["klaviyo"]},
    {"Brevo", ["spf.sendinblue.com", "sendinblue", "brevo"]},
    {"Mailgun", ["mailgun.org"]},
    {"Amazon SES", ["amazonses.com"]},
    {"SparkPost", ["sparkpostmail.com"]},
    {"Mailjet", ["mailjet.com"]},
    {"Constant Contact", ["constantcontact.com"]},
    {"ActiveCampaign", ["activecampaign", "emsend"]},
    {"ConvertKit", ["convertkit"]},
    {"MailerLite", ["mailerlite"]},
    {"Campaign Monitor", ["createsend.com", "cmail"]},
    {"Omnisend", ["omnisend"]},
    {"Customer.io", ["customeriomail", "customer.io"]},
    {"Intercom", ["intercom"]},
    {"Zendesk", ["zendesk.com"]},
    {"Freshdesk", ["freshdesk", "freshemail"]},
    {"Help Scout", ["helpscout"]},
    {"Front", ["frontapp.com"]},
    {"Postmark", ["mtasv.net", "postmarkapp"]},
    {"Atlassian", ["atlassian-domain-verification", "atlassian"]},
    {"Meta Business", ["facebook-domain-verification"]},
    {"DocuSign", ["docusign"]},
    {"Stripe", ["stripe-verification"]},
    {"Zoom", ["zoom_verify", "zoom-verification"]},
    {"Adobe", ["adobe-idp-site-verification", "adobe-sign-verification"]},
    {"Apple Business", ["apple-domain-verification"]},
    {"Miro", ["miro-verification"]},
    {"Notion", ["notion-domain-verification"]},
    {"Canva", ["canva-site-verification"]},
    {"Loom", ["loom-site-verification", "loom-verification"]},
    {"Dropbox", ["dropbox-domain-verification"]},
    {"OpenAI", ["openai-domain-verification"]},
    {"Webex", ["webexdomainverification", "cisco-ci-domain-verification"]},
    {"Zapier", ["zapier-domain-verification"]},
    {"1Password", ["1password-site-verification"]},
    {"OneTrust", ["onetrust-domain-verification"]},
    {"Pinterest", ["pinterest-site-verification"]},
    {"Yandex", ["yandex-verification"]},
    {"LogMeIn", ["logmein-verification-code"]},
    {"Statuspage", ["status-page-domain-verification"]},
    {"Postman", ["postman-domain-verification"]},
    {"MongoDB Atlas", ["mongodb-site-verification"]},
    {"Twilio", ["twilio-domain-verification"]},
    {"Mixpanel", ["mixpanel-domain-verify"]},
    {"Box", ["box-domain-verification"]},
    {"Citrix", ["citrix-verification-code"]},
    {"Shopify", ["shopify-verification-code", "shops.myshopify.com"]},
    {"Squarespace", ["squarespace"]},
    {"Wix", ["wixdns.net"]},
    {"Webflow", ["proxy-ssl.webflow.com"]},
    {"Vercel", ["cname.vercel-dns.com"]},
    {"Netlify", ["netlify.app"]},
    {"GitHub Pages", ["github.io"]},
    {"Cloudflare Pages", ["pages.dev"]},
    {"Mimecast", ["mimecast.com"]},
    {"Proofpoint", ["pphosted.com"]},
    {"Barracuda", ["barracudanetworks.com"]}
  ]

  @doc "The provider list, `{name, patterns}`."
  def providers, do: @providers

  @doc "The vendor list, `{name, patterns}`."
  def tech_rules, do: @tech

  # ── Elixir side ──────────────────────────────────────────────────────────

  @doc "Mailbox provider from the MX host list (or pipe string)."
  @spec email_provider([String.t()] | String.t() | nil) :: String.t()
  def email_provider(nil), do: ""
  def email_provider(""), do: ""
  def email_provider(mx) when is_binary(mx), do: email_provider(String.split(mx, "|", trim: true))
  def email_provider([]), do: ""

  def email_provider(mx) when is_list(mx) do
    hay = mx |> Enum.join("|") |> String.downcase()

    Enum.find_value(@providers, "Other", fn {name, pats} ->
      if Enum.any?(pats, &String.contains?(hay, &1)), do: name
    end)
  end

  @doc "Vendors from TXT, MX and CNAME records (lists or pipe strings)."
  @spec tech(term(), term(), term()) :: [String.t()]
  def tech(txt, mx, cname) do
    hay = [txt, mx, cname] |> Enum.map(&to_hay/1) |> Enum.join("|")

    @tech
    |> Enum.filter(fn {_, pats} -> Enum.any?(pats, &String.contains?(hay, &1)) end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
  end

  defp to_hay(nil), do: ""
  defp to_hay(v) when is_binary(v), do: String.downcase(v)
  defp to_hay(v) when is_list(v), do: v |> Enum.join("|") |> String.downcase()

  # ── SQL side ─────────────────────────────────────────────────────────────

  @doc "ClickHouse expression for the provider, over a pipe-joined MX column."
  def email_provider_sql(mx_col) do
    arms =
      Enum.map_join(@providers, ", ", fn {name, pats} ->
        "multiSearchAnyCaseInsensitive(#{mx_col}, #{array_lit(pats)}), '#{name}'"
      end)

    "multiIf(#{arms}, #{mx_col} != '', 'Other', '')"
  end

  @doc "ClickHouse expression for the vendor array, over the TXT, MX and CNAME columns."
  def tech_sql(txt_col, mx_col, cname_col) do
    hay = "lower(concat(#{txt_col}, '|', #{mx_col}, '|', #{cname_col}))"

    # One rule per element: a vendor is present when any of its patterns is.
    # multiSearchAny over the pattern list is one pass per vendor; 60 vendors
    # over a few hundred bytes is microseconds.
    elems =
      Enum.map_join(@tech, ", ", fn {name, pats} ->
        "if(multiSearchAny(#{hay}, #{array_lit(pats)}), '#{name}', '')"
      end)

    "arrayDistinct(arrayFilter(x -> x != '', [#{elems}]))"
  end

  defp array_lit(pats), do: "[" <> Enum.map_join(pats, ", ", &"'#{String.replace(&1, "'", "")}'") <> "]"
end
