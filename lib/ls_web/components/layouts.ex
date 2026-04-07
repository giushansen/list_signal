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
          <title>ListSignal — Shopify Store Intelligence, Instantly</title>
        <% end %>
        <%= if assigns[:page_description] do %>
          <meta name="description" content={@page_description} />
        <% end %>
        <meta property="og:site_name" content="ListSignal" />
        <meta property="og:type" content="website" />
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
        <title>Dashboard — ListSignal</title>
        <link rel="icon" type="image/png" sizes="32x32" href="/favicon-32x32.png" />
        <link rel="icon" type="image/x-icon" href="/favicon.ico" />
        <link rel="apple-touch-icon" sizes="180x180" href="/apple-touch-icon.png" />
        <link rel="stylesheet" href="/assets/app.css" />
        <script defer phx-track-static src="/assets/app.js"></script>
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
      <div :if={Phoenix.Flash.get(@flash, :info)} class="fixed top-4 right-4 z-50">
        <div class="bg-emerald-600/90 text-white px-4 py-2 rounded shadow text-sm max-w-sm"
          phx-click={Phoenix.LiveView.JS.push("lv:clear-flash", value: %{key: "info"})}
          role="alert">
          <%= Phoenix.Flash.get(@flash, :info) %>
        </div>
      </div>
      <div :if={Phoenix.Flash.get(@flash, :error)} class="fixed top-4 right-4 z-50">
        <div class="bg-red-600/90 text-white px-4 py-2 rounded shadow text-sm max-w-sm"
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
