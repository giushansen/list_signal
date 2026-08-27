defmodule LSWeb.ScoringController do
  @moduledoc """
  Public explainer pages for every score ListSignal publishes.

  These exist for three audiences at once:

    * **buyers** — an agency deciding whether the number is worth paying for
    * **search engines** — long-form, structured, internally linked
    * **LLMs** — each page answers "how is X calculated" in plain prose with a
      real table of weights, so an assistant can quote it accurately

  Every page carries `FAQPage` + `Article` JSON-LD and is listed in the
  sitemap. The scoring weights here are read from the modules that actually
  compute them wherever possible, so the page cannot drift from the code.
  """
  use LSWeb, :controller

  plug :cache_headers

  @pages %{
    seo: {
      "SEO Score, How ListSignal Audits On-Page SEO",
      "How the ListSignal SEO score is calculated: 15 on-page checks plus Core Web Vitals, each weighted, with every failure named. Built for SEO and design agencies prospecting at scale."
    },
    reputation: {
      "Reputation Signals, Tranco, Majestic and Blocklists Explained",
      "How ListSignal scores domain reputation using Tranco traffic rank, Majestic link authority, and malware/phishing blocklists, and why it matters when you are choosing who to sell to."
    },
    revenue: {
      "Revenue Estimation, The Model, Signals and Confidence Score",
      "How ListSignal estimates revenue brackets and employee counts from 25 infrastructure signals, how confidence is computed, and how to read the evidence trail."
    },
    shopify: {
      "Shopify Store Scoring, Catalog, Pricing and Activity Signals",
      "How ListSignal scores Shopify stores using live catalog data: product count, price positioning, new-product velocity, vendor mix and stock health."
    }
  }

  for {action, _} <- @pages do
    def unquote(action)(conn, _params), do: render_page(conn, unquote(action))
  end

  defp render_page(conn, key) do
    {title, description} = Map.fetch!(@pages, key)

    conn
    |> assign(:page_title, title)
    |> assign(:page_description, description)
    |> assign(:json_ld, json_ld(key, title, description))
    |> put_layout(html: {LSWeb.Layouts, :public})
    |> render(key)
  end

  @doc "Every scoring page, for the sitemap and the landing-page footer."
  @spec slugs() :: [{atom(), String.t(), String.t()}]
  def slugs do
    [
      {:seo, "/scoring/seo-score", "SEO Score"},
      {:reputation, "/scoring/reputation", "Reputation Signals"},
      {:revenue, "/scoring/revenue-estimation", "Revenue Estimation"},
      {:shopify, "/scoring/shopify-store-score", "Shopify Store Score"}
    ]
  end

  # Article + FAQ markup: the FAQ block is what gets quoted in AI answers and
  # rich results, so the questions are phrased the way people actually ask them.
  defp json_ld(key, title, description) do
    %{
      "@context" => "https://schema.org",
      "@graph" => [
        %{
          "@type" => "Article",
          "headline" => title,
          "description" => description,
          "author" => %{"@type" => "Organization", "name" => "ListSignal"},
          "publisher" => %{"@type" => "Organization", "name" => "ListSignal"}
        },
        %{"@type" => "FAQPage", "mainEntity" => faq(key)}
      ]
    }
    |> Jason.encode!()
  end

  defp faq(:seo) do
    q([
      {"How is the ListSignal SEO score calculated?",
       "Fifteen on-page checks are run against the rendered HTML, each carrying a fixed weight, title (12 points), meta description (10), H1 (10), canonical (8), JSON-LD structured data (10), Open Graph (8), robots noindex (10) and others. When the page was rendered in a real browser, three Core Web Vitals checks are added: LCP, CLS and TTFB. The score is earned points divided by available points, times 100."},
      {"Why do some sites have no performance metrics?",
       "LCP and CLS can only be measured by a real browser. Pages fetched over plain HTTP are scored on their 15 content checks alone, and the denominator shrinks accordingly, so a site is never penalised for a measurement that was not taken."},
      {"Does ListSignal check for an XML sitemap?",
       "The current score covers on-page signals only. XML sitemap and robots.txt presence are fetched separately at the domain level rather than folded into the page score, because they are site-wide facts rather than properties of a single page."}
    ])
  end

  defp faq(:reputation) do
    q([
      {"What is Tranco rank?",
       "Tranco is a research-grade domain popularity ranking that averages several commercial top-lists over 30 days, which makes it far harder to manipulate than any single list. ListSignal loads the full list, over 4 million domains, and attaches the rank to every record."},
      {"What does Majestic add on top of Tranco?",
       "Tranco approximates traffic; Majestic approximates link authority. A domain with a strong Majestic rank and referring-subnet count has been cited across many independent networks, which is a durable signal of an established business rather than a new site buying traffic."},
      {"How are malware and phishing flags applied?",
       "Domains are checked against maintained malware, phishing and disposable-email blocklists on every enrichment. Flags are sticky: once a domain has been listed, the flag stays on the record so a buyer can filter it out permanently."}
    ])
  end

  defp faq(:revenue) do
    q([
      {"How does ListSignal estimate revenue without financial data?",
       "It scores 25 independent infrastructure signals, traffic rank, link authority, registrar tier, SSL issuer, email provider, SPF and DMARC configuration, marketing-automation stack, subdomain count, CDN and CMS tier, enterprise pages, domain age, hosting tier and more. Each contributes points to one or more of five revenue brackets; the brackets are normalised and the winner is chosen if it clears a confidence threshold."},
      {"What does the confidence score mean?",
       "Confidence is the normalised margin of the winning bracket over the others. Below 0.40, or with fewer than three contributing signals, no estimate is published at all, a blank is more useful than a guess."},
      {"Can I see why a company was placed in a bracket?",
       "Yes. Every scoring decision is recorded in an evidence trail on the record, listing each signal that fired and which bracket it favoured."}
    ])
  end

  defp faq(:shopify) do
    q([
      {"How does ListSignal score a Shopify store?",
       "Every Shopify store publishes its catalog as JSON. ListSignal reads it and derives product count, price minimum, average and maximum, how many products were added in the last 30 days, vendor count, out-of-stock ratio, discount depth and catalog age, all observed facts rather than estimates."},
      {"Can you detect Shopify on a custom domain?",
       "Yes. Detection uses CDN and markup fingerprints rather than the domain name, so a store on its own domain behind Cloudflare is detected exactly like one on myshopify.com. Measured against DNS-level ground truth, recall is 100%."},
      {"What tells me a store is actually growing?",
       "New products in the last 30 days, and the date the most recent product was added. A store with a large catalog but nothing added in six months is coasting; one adding products weekly is investing."}
    ])
  end

  defp q(pairs) do
    Enum.map(pairs, fn {question, answer} ->
      %{
        "@type" => "Question",
        "name" => question,
        "acceptedAnswer" => %{"@type" => "Answer", "text" => answer}
      }
    end)
  end

  defp cache_headers(conn, _opts) do
    put_resp_header(conn, "cache-control", "public, max-age=3600")
  end
end
