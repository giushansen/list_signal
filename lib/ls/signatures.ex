defmodule LS.Signatures do
  @moduledoc "Loads CSV scoring signatures into ETS at startup."
  require Logger

  @signature_files %{
    ctl_tld: "lib/ls/ctl/signatures/tld.csv",
    ctl_issuer: "lib/ls/ctl/signatures/issuer.csv",
    ctl_subdomain: "lib/ls/ctl/signatures/subdomain.csv",
    dns_txt: "lib/ls/dns/signatures/txt.csv",
    dns_mx: "lib/ls/dns/signatures/mx.csv",
    http_tech: "lib/ls/http/signatures/tech.csv",
    http_tools: "lib/ls/http/signatures/tools.csv",
    http_cdn: "lib/ls/http/signatures/cdn.csv",
    http_blocked: "lib/ls/http/signatures/blocked.csv",
    http_server: "lib/ls/http/signatures/server.csv",
    http_content_type: "lib/ls/http/signatures/content_type.csv",
    http_response_time: "lib/ls/http/signatures/response_time.csv",
    bgp_asn_org: "lib/ls/bgp/signatures/asn_org.csv",
    bgp_country: "lib/ls/bgp/signatures/country.csv",
    bgp_prefix: "lib/ls/bgp/signatures/prefix.csv"
  }

  def load_all do
    Enum.each(@signature_files, fn {type, filepath} ->
      load_signature(type, filepath)
    end)
    Logger.info("✅ Loaded #{map_size(@signature_files)} signature tables")
  end

  defp load_signature(type, filepath) do
    table = table_name(type)
    :ets.new(table, [:bag, :public, :named_table, read_concurrency: true])
    case File.read(filepath) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.reject(&String.starts_with?(&1, "#"))
        |> Enum.each(fn line ->
          case String.split(line, ",", parts: 4) do
            [p, st, pts, c] ->
              :ets.insert(table, {String.trim(p) |> String.downcase(),
                String.trim(st) |> String.to_atom(),
                String.to_integer(String.trim(pts)),
                String.trim(c)})
            _ -> :ok
          end
        end)
      {:error, reason} ->
        Logger.warning("⚠️  Signatures #{filepath}: #{inspect(reason)}")
    end
  end

  def score(type, text) when is_atom(type) and is_binary(text) do
    table = table_name(type)
    lower = String.downcase(text)
    case :ets.info(table) do
      :undefined -> %{}
      _ ->
        :ets.tab2list(table)
        |> Enum.filter(fn {pattern, _, _, _} -> String.contains?(lower, pattern) end)
        |> Enum.reduce(%{}, fn {_, score_type, points, _}, acc ->
          Map.update(acc, score_type, points, &(&1 + points))
        end)
    end
  end
  def score(_, _), do: %{}

  def detect_http_tech(body, headers) when is_binary(body) do
    header_str = headers
    |> Enum.map(fn {k, v} -> "#{k}: #{v}" end)
    |> Enum.join(" ")
    combined = String.downcase(body <> " " <> header_str)

    tech = :ets.tab2list(table_name(:http_tech))
    |> Enum.filter(fn {p, _, _, _} -> String.contains?(combined, p) end)
    |> Enum.map(fn {_, _, _, c} -> c end)
    |> Enum.uniq()

    tools = :ets.tab2list(table_name(:http_tools))
    |> Enum.filter(fn {p, _, _, _} -> String.contains?(combined, p) end)
    |> Enum.map(fn {_, _, _, c} -> c end)
    |> Enum.uniq()

    %{tech: tech, tools: tools}
  end
  def detect_http_tech(_, _), do: %{tech: [], tools: []}

  def table_name(type), do: :"sig_#{type}"
end
