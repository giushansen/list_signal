defmodule LSWeb.SearchController do
  @moduledoc """
  Fallback for non-JS form submissions. The main search flow happens
  inline on the landing page via JS calling /api/tools/lookup.
  """
  use LSWeb, :controller
  require Logger

  def search(conn, %{"q" => q}) when is_binary(q) do
    query = q |> String.trim() |> String.downcase()
              |> String.replace(~r/^https?:\/\//, "") |> String.replace(~r/\/.*$/, "")

    Logger.info("[SEARCH] query=#{query}")

    cond do
      String.contains?(query, ".") ->
        # It's a domain — run the lookup synchronously, then redirect
        Logger.info("[SEARCH] Detected domain: #{query}, running lookup...")
        case LS.Tools.Lookup.lookup(query) do
          {:ok, data} ->
            slug = query |> String.replace(".", "-")
            if data[:is_shopify] do
              redirect(conn, to: "/shopify/#{slug}")
            else
              redirect(conn, to: "/website/#{slug}")
            end
          {:error, reason} ->
            Logger.warning("[SEARCH] Lookup failed for #{query}: #{reason}")
            slug = query |> String.replace(".", "-")
            redirect(conn, to: "/website/#{slug}")
        end
      query != "" ->
        slug = query |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
        redirect(conn, to: "/tech/#{slug}")
      true ->
        redirect(conn, to: "/")
    end
  end

  def search(conn, _params), do: redirect(conn, to: "/")
end
