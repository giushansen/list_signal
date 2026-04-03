defmodule LSWeb.Router do
  use LSWeb, :router

  pipeline :public do
    plug :accepts, ["html"]
    plug :put_root_layout, html: {LSWeb.Layouts, :public_root}
    plug :put_secure_browser_headers
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {LSWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", LSWeb do
    pipe_through :public

    get "/", PageController, :home
    get "/search", SearchController, :search
    get "/pricing", PageController, :pricing
    get "/features", PageController, :features

    get "/store/:slug", StoreController, :show
    get "/shopify/:slug", StoreController, :show_shopify
    get "/website/:slug", StoreController, :show_website
    get "/tech/:slug", TechController, :show
    get "/compare/:slug", CompareController, :show
    get "/top/:slug", TopController, :show

    get "/apps", DirectoryController, :apps
    get "/countries", DirectoryController, :countries

    get "/alternatives/:competitor", AlternativesController, :show

    get "/tools/shopify-checker", ToolsController, :shopify_checker
    get "/tools/tech-lookup", ToolsController, :tech_lookup
    get "/api/tools/lookup", ToolsController, :api_lookup
    get "/api/tech/suggest", ToolsController, :api_tech_suggest

    get "/new-stores", FeedController, :new_stores

    get "/privacy", LegalController, :privacy
    get "/terms", LegalController, :terms

    get "/sitemap.xml", SitemapController, :index
  end

  scope "/admin", LSWeb do
    pipe_through :browser
    live "/", DashboardLive, :index
  end

  if Mix.env() in [:dev, :test] do
    import Phoenix.LiveDashboard.Router
    scope "/dev" do
      pipe_through :browser
      live_dashboard "/phoenix", metrics: LSWeb.Telemetry
    end
  end
end
