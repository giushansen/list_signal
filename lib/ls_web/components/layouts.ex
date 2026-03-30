defmodule LSWeb.Layouts do
  @moduledoc """
  Layout components for ListSignal.
  - public_root/public: Marketing/SEO pages (CDN-cacheable, no LiveView)
  - root/app: Internal dashboard (LiveView)
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
          <title>ListSignal — Shopify Store Intelligence, Instantly</title>
        <% end %>
        <%= if assigns[:page_description] do %>
          <meta name="description" content={@page_description} />
        <% end %>
        <meta property="og:site_name" content="ListSignal" />
        <meta property="og:type" content="website" />
        <link rel="icon" type="image/svg+xml" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'><rect width='32' height='32' rx='6' fill='%2310B981'/><text x='16' y='23' text-anchor='middle' fill='white' font-weight='800' font-size='16' font-family='system-ui'>LS</text></svg>" />
        <link rel="icon" type="image/x-icon" href="/favicon.ico" />
        <link rel="apple-touch-icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 180 180'><rect width='180' height='180' rx='36' fill='%2310B981'/><text x='90' y='125' text-anchor='middle' fill='white' font-weight='800' font-size='90' font-family='system-ui'>LS</text></svg>" />
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
        <link href="https://fonts.googleapis.com/css2?family=Sora:wght@400;500;600;700;800&family=DM+Sans:ital,wght@0,400;0,500;0,600;0,700;1,400&display=swap" rel="stylesheet" />
        <link rel="stylesheet" href="/assets/app.css" />
        <%= if assigns[:json_ld] do %>
          <script type="application/ld+json"><%= raw(@json_ld) %></script>
        <% end %>
      </head>
      <body class="bg-ls-dark text-white antialiased">
        {@inner_content}
      </body>
    </html>
    """
  end

  def public(assigns) do
    ~H"""
    {@inner_content}
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
        <title>ListSignal Admin</title>
        <link rel="icon" type="image/svg+xml" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'><rect width='32' height='32' rx='6' fill='%2310B981'/><text x='16' y='23' text-anchor='middle' fill='white' font-weight='800' font-size='16' font-family='system-ui'>LS</text></svg>" />
        <link rel="icon" type="image/x-icon" href="/favicon.ico" />
        <style>
          body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                 background: #0f172a; color: #e2e8f0; margin: 0; padding: 20px; }
          .container { max-width: 1200px; margin: 0 auto; }
        </style>
        <script defer phx-track-static src="/assets/app.js"></script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  def app(assigns) do
    ~H"""
    <div class="container">
      {@inner_content}
    </div>
    """
  end
end
