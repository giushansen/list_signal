defmodule LSWeb.Layouts do
  @moduledoc """
  Layout components for ListSignal.
  - public_root/public: Marketing/SEO pages (CDN-cacheable, no LiveView)
  - root/app: Internal dashboard & authenticated app (LiveView)
  """
  use LSWeb, :html

  def public_root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="scroll-smooth">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="robots" content="index, follow" />
        <%= if assigns[:page_title] do %>
          <title><%= @page_title %> — ListSignal</title>
        <% else %>
          <title>ListSignal — Domain Intelligence, Checked in Real Time</title>
        <% end %>
        <%= if assigns[:page_description] do %>
          <meta name="description" content={@page_description} />
        <% end %>
        <meta property="og:site_name" content="ListSignal" />
        <meta property="og:type" content="website" />
        <%= if assigns[:conn] do %>
          <link rel="canonical" href={"https://listsignal.com" <> @conn.request_path} />
          <meta property="og:url" content={"https://listsignal.com" <> @conn.request_path} />
        <% end %>
        <link rel="icon" type="image/png" sizes="32x32" href="/favicon-32x32.png" />
        <link rel="icon" type="image/x-icon" href="/favicon.ico" />
        <link rel="apple-touch-icon" sizes="180x180" href="/apple-touch-icon.png" />
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
        <link href="https://fonts.googleapis.com/css2?family=Sora:wght@400;500;600;700;800&family=DM+Sans:ital,wght@0,400;0,500;0,600;0,700;1,400&display=swap" rel="stylesheet" />
        <link rel="stylesheet" href="/assets/app.css" />
        <%= if assigns[:json_ld] do %>
          <script type="application/ld+json"><%= raw(@json_ld) %></script>
        <% end %>
        <.umami />
      </head>
      <body class="bg-ls-dark text-white antialiased">
        <.public_nav current_path={assigns[:conn] && @conn.request_path} />
        {@inner_content}
        <.footer />
      </body>
    </html>
    """
  end

  def public(assigns) do
    ~H"""
    {@inner_content}
    """
  end

  @doc """
  The one and only public navbar.

  Rendered by `public_root/1` so every marketing/SEO page gets the exact same
  header. Pages must not ship their own `<nav>` — a per-page navbar is how we
  ended up with five different variants where /features had no Log in link and
  /privacy had no Features or Pricing link.
  """
  attr :current_path, :string, default: nil

  def public_nav(assigns) do
    ~H"""
    <nav class="fixed top-0 left-0 right-0 z-50 border-b border-white/[0.07] bg-ls-dark/85 backdrop-blur-xl" aria-label="Main">
      <div class="mx-auto max-w-[1200px] px-6 py-4 flex items-center justify-between">
        <a href="/" class="flex items-center gap-2 font-display text-[21px] font-bold tracking-tight">
          <span class="flex h-[30px] w-[30px] items-center justify-center rounded-lg bg-accent text-[13px] font-extrabold text-white relative overflow-hidden">
            LS<span class="absolute inset-0 rounded-lg bg-gradient-to-br from-white/20 to-transparent"></span>
          </span>
          ListSignal
        </a>
        <ul class="flex items-center gap-4 md:gap-8">
          <li :for={{href, label} <- nav_links()} class="hidden md:block">
            <a href={href} class={"text-sm font-medium transition-colors hover:text-white #{if @current_path == href, do: "text-white", else: "text-white/60"}"}>
              {label}
            </a>
          </li>
          <li :for={{href, label} <- right_nav_links()} class="hidden md:block">
            <a href={href} class={"text-sm font-medium transition-colors hover:text-white #{if @current_path == href, do: "text-white", else: "text-white/60"}"}>
              {label}
            </a>
          </li>
          <li>
            <a href="/users/log-in" class="text-sm font-medium text-white/60 hover:text-white transition-colors">Sign in</a>
          </li>
          <li>
            <a href="/signup" data-umami-event="signup_cta" data-umami-event-source="nav"
               class="rounded-lg bg-accent px-4 md:px-5 py-2 text-sm font-semibold text-white hover:bg-accent-hover transition-all hover:-translate-y-px">Start Free</a>
          </li>
        </ul>
      </div>
    </nav>
    """
  end

  @doc "Left (product) links in the public navbar. Single source of truth (also used by tests)."
  def nav_links do
    [
      {"/new-stores", "Shopify"},
      {"/saas", "SaaS businesses"},
      {"/apps", "Apps&Tech"}
    ]
  end

  @doc "Right-side navbar links, rendered just left of Sign in."
  def right_nav_links do
    [
      {"/features", "Features"},
      {"/pricing", "Pricing"}
    ]
  end

  def footer(assigns) do
    ~H"""
    <footer class="border-t border-white/[0.08] bg-ls-dark text-white/70" itemscope itemtype="https://schema.org/WPFooter">
      <div class="max-w-6xl mx-auto px-6 py-14">
        <%!-- Top: brand + tagline --%>
        <div class="mb-10 text-center">
          <a href="/" class="inline-flex items-center gap-2 mb-3" itemprop="url">
            <div class="flex h-9 w-9 items-center justify-center rounded-lg bg-emerald-500 text-xs font-extrabold text-white">LS</div>
            <span class="text-xl font-semibold text-white" itemprop="name">ListSignal</span>
          </a>
          <p class="text-sm text-white/50 max-w-xl mx-auto" itemprop="description">
            Real-time Shopify store intelligence and tech-stack discovery for sales teams, founders, and researchers.
          </p>
        </div>

        <%!-- Link columns --%>
        <nav class="grid grid-cols-2 md:grid-cols-5 gap-8 mb-10" aria-label="Footer">
          <%!-- Product --%>
          <div>
            <h3 class="text-[12px] font-semibold text-white uppercase tracking-wider mb-4">Product</h3>
            <ul class="space-y-2.5 text-sm">
              <li><a href="/" class="hover:text-white transition">Home</a></li>
              <li><a href="/features" class="hover:text-white transition">Features</a></li>
              <li><a href="/pricing" class="hover:text-white transition">Pricing</a></li>
              <li><a href="/search" class="hover:text-white transition">Search Stores</a></li>
              <li><a href="/new-stores" class="hover:text-white transition">New Stores Feed</a></li>
              <li><a href="/users/register" class="hover:text-white transition">Sign Up Free</a></li>
              <li><a href="/users/log-in" class="hover:text-white transition">Log In</a></li>
            </ul>
          </div>

          <%!-- Directory --%>
          <div>
            <h3 class="text-[12px] font-semibold text-white uppercase tracking-wider mb-4">Directory</h3>
            <ul class="space-y-2.5 text-sm">
              <li><a href="/apps" class="hover:text-white transition">All Shopify Apps</a></li>
              <li><a href="/countries" class="hover:text-white transition">Stores by Country</a></li>
              <li><a href="/top/shopify" class="hover:text-white transition">Top Shopify Stores</a></li>
              <li><a href="/top/ecommerce" class="hover:text-white transition">Top Ecommerce</a></li>
              <li><a href="/top/saas" class="hover:text-white transition">Top SaaS</a></li>
              <li><a href="/top/fashion" class="hover:text-white transition">Top Fashion</a></li>
              <li><a href="/top/beauty" class="hover:text-white transition">Top Beauty</a></li>
            </ul>
          </div>

          <%!-- Technologies --%>
          <div>
            <h3 class="text-[12px] font-semibold text-white uppercase tracking-wider mb-4">Technologies</h3>
            <ul class="space-y-2.5 text-sm">
              <li><a href="/tech/shopify" class="hover:text-white transition">Shopify Sites</a></li>
              <li><a href="/tech/woocommerce" class="hover:text-white transition">WooCommerce</a></li>
              <li><a href="/tech/klaviyo" class="hover:text-white transition">Klaviyo</a></li>
              <li><a href="/tech/cloudflare" class="hover:text-white transition">Cloudflare</a></li>
              <li><a href="/tech/google-analytics" class="hover:text-white transition">Google Analytics</a></li>
              <li><a href="/tech/meta-pixel" class="hover:text-white transition">Meta Pixel</a></li>
              <li><a href="/tech/stripe" class="hover:text-white transition">Stripe</a></li>
            </ul>
          </div>

          <%!-- Tools --%>
          <div>
            <h3 class="text-[12px] font-semibold text-white uppercase tracking-wider mb-4">Free Tools</h3>
            <ul class="space-y-2.5 text-sm">
              <li><a href="/tools/shopify-checker" class="hover:text-white transition">Shopify Checker</a></li>
              <li><a href="/tools/tech-lookup" class="hover:text-white transition">Tech Stack Lookup</a></li>
              <li><a href="/api/tools/lookup" class="hover:text-white transition">Lookup API</a></li>
              <li><a href="/api/tech/suggest" class="hover:text-white transition">Tech Suggest API</a></li>
              <li><a href="/sitemap.xml" class="hover:text-white transition">Sitemap</a></li>
              <li><a href="/llms.txt" class="hover:text-white transition">llms.txt</a></li>
            </ul>
          </div>

          <%!-- Compare --%>
          <div>
            <h3 class="text-[12px] font-semibold text-white uppercase tracking-wider mb-4">Compare</h3>
            <ul class="space-y-2.5 text-sm">
              <li><a href="/alternatives/builtwith" class="hover:text-white transition">vs BuiltWith</a></li>
              <li><a href="/alternatives/wappalyzer" class="hover:text-white transition">vs Wappalyzer</a></li>
              <li><a href="/alternatives/storeleads" class="hover:text-white transition">vs Store Leads</a></li>
              <li><a href="/alternatives/myip-ms" class="hover:text-white transition">vs MyIP.ms</a></li>
              <li><a href="/compare/shopify-vs-woocommerce" class="hover:text-white transition">Shopify vs Woo</a></li>
              <li><a href="/compare/klaviyo-vs-mailchimp" class="hover:text-white transition">Klaviyo vs MC</a></li>
            </ul>
          </div>
        </nav>

        <%!-- Popular countries — internal linking for SEO --%>
        <div class="border-t border-white/[0.06] pt-8 mb-8">
          <h3 class="text-[12px] font-semibold text-white uppercase tracking-wider mb-4 text-center">Browse Stores by Country</h3>
          <div class="flex flex-wrap justify-center gap-x-4 gap-y-2 text-[13px] text-white/50">
            <a href="/store/united-states" class="hover:text-white transition">🇺🇸 United States</a>
            <a href="/store/united-kingdom" class="hover:text-white transition">🇬🇧 United Kingdom</a>
            <a href="/store/canada" class="hover:text-white transition">🇨🇦 Canada</a>
            <a href="/store/australia" class="hover:text-white transition">🇦🇺 Australia</a>
            <a href="/store/germany" class="hover:text-white transition">🇩🇪 Germany</a>
            <a href="/store/france" class="hover:text-white transition">🇫🇷 France</a>
            <a href="/store/netherlands" class="hover:text-white transition">🇳🇱 Netherlands</a>
            <a href="/store/spain" class="hover:text-white transition">🇪🇸 Spain</a>
            <a href="/store/italy" class="hover:text-white transition">🇮🇹 Italy</a>
            <a href="/store/japan" class="hover:text-white transition">🇯🇵 Japan</a>
            <a href="/store/singapore" class="hover:text-white transition">🇸🇬 Singapore</a>
            <a href="/store/brazil" class="hover:text-white transition">🇧🇷 Brazil</a>
            <a href="/store/mexico" class="hover:text-white transition">🇲🇽 Mexico</a>
            <a href="/store/india" class="hover:text-white transition">🇮🇳 India</a>
          </div>
        </div>

        <%!-- Bottom: legal --%>
        <div class="border-t border-white/[0.06] pt-6 flex flex-col md:flex-row items-center justify-between gap-4 text-sm text-white/45">
          <div class="text-center md:text-left" itemprop="copyrightHolder" itemscope itemtype="https://schema.org/Organization">
            <p>
              © 2026 <span itemprop="name">ListSignal</span>. All rights reserved.
            </p>
            <p class="mt-1 text-white/40">
              ListSignal is a <span class="text-emerald-400/90 font-medium" itemprop="parentOrganization">Keybloc Pte Ltd</span> company,
              <span itemprop="address" itemscope itemtype="https://schema.org/PostalAddress">
                registered in <span itemprop="addressCountry">Singapore</span>
              </span>.
            </p>
          </div>
          <div class="flex items-center gap-5">
            <a href="/privacy" class="hover:text-white transition">Privacy Policy</a>
            <a href="/terms" class="hover:text-white transition">Terms of Service</a>
            <a href="/sitemap.xml" class="hover:text-white transition">Sitemap</a>
          </div>
        </div>
      </div>
    </footer>
    """
  end

  @doc """
  Umami analytics tag, rendered in every page `<head>`.

  No-ops until `config :ls, :umami` has a `website_id` (so dev/test/CI stay
  clean and CSV buyers' one-off pages never phone home). The id is public — it
  ships in the script itself — so it lives in config, not in the secrets env.
  Self-hosted + cookieless, so no consent banner is required.
  """
  def umami(assigns) do
    cfg = Application.get_env(:ls, :umami, [])

    assigns =
      assigns
      |> assign(:umami_id, cfg[:website_id])
      |> assign(:umami_src, cfg[:src] || "https://stats.listsignal.com/script.js")

    ~H"""
    <script :if={@umami_id} defer src={@umami_src} data-website-id={@umami_id}></script>
    """
  end

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <meta name="robots" content="noindex, nofollow" />
        <title>Dashboard — ListSignal</title>
        <link rel="icon" type="image/png" sizes="32x32" href="/favicon-32x32.png" />
        <link rel="icon" type="image/x-icon" href="/favicon.ico" />
        <link rel="apple-touch-icon" sizes="180x180" href="/apple-touch-icon.png" />
        <link rel="stylesheet" href="/assets/app.css" />
        <script defer phx-track-static src="/assets/app.js"></script>
        <.umami />
      </head>
      <body class="bg-[#0a0e17] text-gray-200 antialiased">
        {@inner_content}
      </body>
    </html>
    """
  end

  def app(assigns) do
    ~H"""
    <div>
      <%!-- phx-hook="AutoClearFlash" is what makes these disappear on their
           own. This layout used to hand-roll the markup without it, so every
           flash sat there until the user clicked it. The id is required: a
           hook without one is silently ignored by LiveView. --%>
      <div :if={Phoenix.Flash.get(@flash, :info)} id="flash-info" phx-hook="AutoClearFlash" class="fixed top-4 right-4 z-50">
        <div class="bg-emerald-600/90 text-white px-4 py-2 rounded shadow text-sm max-w-sm cursor-pointer"
          phx-click={Phoenix.LiveView.JS.push("lv:clear-flash", value: %{key: "info"})}
          role="alert">
          <%= Phoenix.Flash.get(@flash, :info) %>
        </div>
      </div>
      <div :if={Phoenix.Flash.get(@flash, :error)} id="flash-error" phx-hook="AutoClearFlash" class="fixed top-4 right-4 z-50">
        <div class="bg-red-600/90 text-white px-4 py-2 rounded shadow text-sm max-w-sm cursor-pointer"
          phx-click={Phoenix.LiveView.JS.push("lv:clear-flash", value: %{key: "error"})}
          role="alert">
          <%= Phoenix.Flash.get(@flash, :error) %>
        </div>
      </div>
      {@inner_content}
    </div>
    """
  end
end
