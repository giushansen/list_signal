defmodule LSWeb.Layouts do
  @moduledoc "Layout components for ListSignal."
  use LSWeb, :html

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <title>ListSignal</title>
        <style>
          body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                 background: #0f172a; color: #e2e8f0; margin: 0; padding: 20px; }
          .container { max-width: 1200px; margin: 0 auto; }
          h1 { color: #38bdf8; margin-bottom: 4px; }
          .subtitle { color: #64748b; margin-bottom: 24px; }
          .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 16px; margin-bottom: 24px; }
          .card { background: #1e293b; border-radius: 12px; padding: 20px; border: 1px solid #334155; }
          .card h3 { color: #94a3b8; font-size: 12px; text-transform: uppercase; letter-spacing: 1px; margin: 0 0 8px 0; }
          .card .value { font-size: 28px; font-weight: 700; color: #f1f5f9; }
          .card .sub { color: #64748b; font-size: 13px; margin-top: 4px; }
          .workers { margin-top: 24px; }
          .workers table { width: 100%; border-collapse: collapse; }
          .workers th { text-align: left; color: #64748b; font-size: 12px; text-transform: uppercase;
                        padding: 8px 12px; border-bottom: 1px solid #334155; }
          .workers td { padding: 8px 12px; border-bottom: 1px solid #1e293b; }
          .badge { display: inline-block; padding: 2px 8px; border-radius: 9999px; font-size: 12px; }
          .badge-green { background: #064e3b; color: #34d399; }
          .badge-yellow { background: #451a03; color: #fbbf24; }
          .badge-red { background: #450a0a; color: #f87171; }
          .alert { padding: 12px 16px; border-radius: 8px; margin-bottom: 16px; }
          .alert-warn { background: #451a03; border: 1px solid #92400e; color: #fbbf24; }
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
