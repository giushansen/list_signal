defmodule LS.HTTP.Fingerprint do
  @moduledoc """
  What the detectors saw, kept per crawl row so a detection can be
  reproduced and debugged without the page (2026-09-06).

  Raw HTML is not stored (1.75M pages a day). The technology and app
  detectors read script sources, meta generator tags, a few headers and
  markup markers; this keeps exactly those, as a small JSON object capped
  at 2 KB: the distinct hosts of `src=` attributes, the generator meta,
  the server and x-powered-by headers, the HTML byte size and the count of
  script tags. Given a row's fingerprint and its `pipeline_version`, a
  claimed "started showing Klaviyo" can be checked against the evidence
  the crawler actually had, and a signature change can be replayed over
  stored fingerprints instead of re-crawling. Pure; hostile input yields
  "" and never raises.
  """

  @max_hosts 40
  @max_bytes 2_048

  @doc "JSON fingerprint for a fetch result (`%{body, headers}`), or \"\"."
  @spec build(map() | nil) :: String.t()
  def build(%{} = resp) do
    body = resp[:body] || ""
    headers = resp[:headers] || []
    html = binary_part(body, 0, min(byte_size(body), 600_000))

    fp = %{
      "hosts" => src_hosts(html),
      "gen" => generator(html),
      "server" => header(headers, "server"),
      "powered" => header(headers, "x-powered-by"),
      "bytes" => byte_size(body),
      "scripts" => length(Regex.scan(~r/<script[\s>]/i, html))
    }

    json = Jason.encode!(fp)

    if byte_size(json) > @max_bytes,
      do: Jason.encode!(%{fp | "hosts" => Enum.take(fp["hosts"], 12)}) |> String.slice(0, @max_bytes),
      else: json
  rescue
    _ -> ""
  end

  def build(_), do: ""

  @doc false
  def src_hosts(html) when is_binary(html) do
    ~r/\ssrc=["']?(?:https?:)?\/\/([a-z0-9.-]{3,120})/i
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.map(fn [h] -> String.downcase(h) end)
    |> Enum.uniq()
    |> Enum.take(@max_hosts)
  end

  def src_hosts(_), do: []

  defp generator(html) do
    case Regex.run(~r/<meta[^>]+name=["']generator["'][^>]+content=["']([^"']{1,80})/i, html) do
      [_, g] -> g
      _ ->
        case Regex.run(~r/<meta[^>]+content=["']([^"']{1,80})["'][^>]+name=["']generator["']/i, html) do
          [_, g] -> g
          _ -> ""
        end
    end
  end

  defp header(headers, name) when is_list(headers) do
    Enum.find_value(headers, "", fn
      {k, v} when is_binary(k) and is_binary(v) -> if String.downcase(k) == name, do: String.slice(v, 0, 60)
      _ -> nil
    end)
  end

  defp header(_, _), do: ""
end
