defmodule LS.Reputation.TLDFilter do
  @moduledoc "Filters second-level TLDs that are registries, not businesses."

  @registry_domains MapSet.new([
    "uk.com", "us.com", "eu.com", "cn.com", "de.com", "br.com", "ru.com",
    "sa.com", "za.com", "se.com", "no.com", "kr.com", "jp.com", "hu.com",
    "it.com", "uk.net", "se.net", "eu.org",
    "ddns.net", "dyndns.org", "no-ip.org", "no-ip.com", "no-ip.biz",
    "hopto.org", "sytes.net", "zapto.org", "myftp.org", "myftp.biz",
    "serveftp.com", "servegame.com", "redirectme.net",
    "myftpupload.com", "synology.me",
    "co.uk", "co.za", "co.in", "co.jp", "co.kr", "co.nz", "co.il",
    "com.au", "com.br", "com.cn", "com.hk", "com.mx", "com.sg", "com.tw",
    "com.ar", "com.co", "com.tr", "com.ua", "com.vn", "com.ng", "com.pk",
    "org.uk", "org.au", "org.nz", "org.br", "org.il", "org.za",
    "net.au", "net.br", "net.cn", "net.in",
    "ac.uk", "gov.uk", "gov.br", "gov.au", "gov.in",
    "edu.au", "edu.br", "edu.cn",
    "adv.br", "ind.br", "inf.br", "eng.br", "mus.br", "bio.br",
    "art.br", "eti.br", "eco.br", "esp.br", "etc.br",
    "pp.ua", "my.id", "web.id", "or.id", "go.id", "ac.id",
    "herokuapp.com", "azurewebsites.net", "cloudfront.net",
    "netlify.app", "vercel.app", "pages.dev", "fly.dev",
    "onrender.com", "railway.app", "web.app", "firebaseapp.com",
    "github.io", "gitlab.io", "bitbucket.io",
    "blogspot.com", "wordpress.com", "tumblr.com",
    "squarespace.com", "wixsite.com", "weebly.com",
    "shopify.com", "myshopify.com",
    "godaddysites.com", "godaddywebsitebuilder.com"
  ])

  def is_registry?(domain) when is_binary(domain) do
    d = domain |> String.downcase() |> String.trim_leading("www.")
    MapSet.member?(@registry_domains, d) or looks_like_tld?(d)
  end

  defp looks_like_tld?(domain) do
    parts = String.split(domain, ".")
    case parts do
      [first, _] when byte_size(first) <= 2 -> true
      _ -> false
    end
  end
end
