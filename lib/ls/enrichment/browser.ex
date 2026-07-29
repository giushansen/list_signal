defmodule LS.Enrichment.Browser do
  @moduledoc """
  Client for the camoufox/nodriver browser sidecar.

  The sidecar is a small Python service (`devops/listsignal/browser_sidecar.py`)
  running on nodes that declare the `enrichment` lane. Camoufox is a hardened
  Firefox build that presents a realistic fingerprint, driven in nodriver mode
  so automation is not detectable — which is the point: we only reach for it
  when plain HTTP was refused (WAF) or the page needs JavaScript.

  Elixir stays the orchestrator and Python does browsers; the seam is one HTTP
  call to `127.0.0.1`, so a crashing browser can never take a worker down.

  Set `LS_BROWSER_URL` to enable (e.g. `http://127.0.0.1:8900`). When unset,
  `available?/0` is false and the enrichment lane runs HTTP-only.
  """

  require Logger

  # Renders can legitimately take a while (JS, redirects); the sidecar enforces
  # its own budget, this is only the outer guard.
  @timeout 45_000

  @doc "Is a browser sidecar configured on this node?"
  @spec available?() :: boolean()
  def available?, do: url() != nil

  @doc """
  Render `path` on `domain` and return the final HTML plus Core Web Vitals.

      {:ok, %{html: "<html>…", perf: %{lcp_ms: 1840, cls: 0.02, ttfb_ms: 310},
              status: 200, final_url: "https://…"}}

  Login pages are followed through at most 3 redirects and 6s by the sidecar
  (SSO chains otherwise wander off to identity providers forever).
  """
  @spec render(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def render(domain, path \\ "/") do
    case url() do
      nil ->
        {:error, :not_configured}

      base ->
        body = Jason.encode!(%{domain: domain, path: path})

        case Req.post("#{base}/render", body: body,
               headers: [{"content-type", "application/json"}], receive_timeout: @timeout) do
          {:ok, %{status: 200, body: %{"html" => html} = payload}} ->
            {:ok, %{
              html: html,
              status: payload["status"],
              final_url: payload["final_url"],
              perf: %{
                lcp_ms: non_negative(payload["lcp_ms"]),
                cls: non_negative(payload["cls"]),
                ttfb_ms: non_negative(payload["ttfb_ms"])
              }
            }}

          {:ok, %{status: s}} ->
            {:error, {:http, s}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp url, do: System.get_env("LS_BROWSER_URL")

  # Browser timings can come back negative (clock-skewed navigation entries).
  # The perf_* columns are unsigned, so a raw -5 fails the TabSeparated parse
  # and takes the WHOLE insert batch down with it. Garbage timing = no timing.
  defp non_negative(n) when is_number(n) and n >= 0, do: n
  defp non_negative(_), do: nil
end
