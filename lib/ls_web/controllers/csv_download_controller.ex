defmodule LSWeb.CsvDownloadController do
  @moduledoc """
  Serves a purchased CSV at `/d/:token`.

  No session, no login: the buyer came from a cold email and has already paid.
  The token in the URL is the credential, so this module is the only place
  that decides whether a file may be handed over, and it writes down every
  time it does, because that record is the evidence in a chargeback.
  """
  use LSWeb, :controller
  require Logger

  alias LS.{Audit, CsvSales}
  alias LS.CsvSales.Order

  def show(conn, %{"token" => token}) do
    case CsvSales.get_by_token(token) do
      nil ->
        # Same response for "wrong token" and "no such order": a probe should
        # learn nothing from the difference.
        Audit.record_from_conn(conn, "csv_download_denied", %{metadata: %{reason: "unknown_token"}})
        not_found(conn)

      %Order{} = order ->
        cond do
          is_nil(order.paid_at) ->
            Audit.record_from_conn(conn, "csv_download_denied", %{
              email: order.email,
              metadata: %{reason: "unpaid", token: token}
            })

            conn
            |> put_status(:payment_required)
            |> text("This download unlocks once payment completes. If you have just paid, refresh in a moment.")

          not Order.downloadable?(order) ->
            Audit.record_from_conn(conn, "csv_download_denied", %{
              email: order.email,
              metadata: %{reason: "expired", token: token}
            })

            conn
            |> put_status(:gone)
            |> text("This download link has expired. Reply to your receipt and we will re-issue it.")

          true ->
            deliver(conn, order)
        end
    end
  end

  defp deliver(conn, %Order{} = order) do
    if File.exists?(order.file_path) do
      {:ok, updated} = CsvSales.record_download(order, client_ip(conn))

      Audit.record_from_conn(conn, "csv_downloaded", %{
        email: order.email,
        metadata: %{
          token: order.token,
          watermark: order.watermark,
          rows: order.row_count,
          download_number: updated.download_count
        }
      })

      Logger.info("[CSV] #{order.email} downloaded #{order.token} (##{updated.download_count})")

      send_download(conn, {:file, order.file_path},
        filename: filename_for(order),
        content_type: "text/csv"
      )
    else
      # The order exists and is paid but the file is gone: that is our fault,
      # so say so plainly rather than showing the buyer a 404.
      Logger.error("[CSV] file missing for paid order #{order.token}: #{order.file_path}")

      conn
      |> put_status(:internal_server_error)
      |> text("We could not find your file. Reply to your receipt and we will send it directly.")
    end
  end

  defp filename_for(%Order{description: nil}), do: "listsignal-export.csv"

  defp filename_for(%Order{description: description}) do
    slug =
      description
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 60)

    "listsignal-#{slug}.csv"
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> text("Download not found. Check the link in your receipt, or reply to it and we will help.")
  end

  defp client_ip(conn) do
    case get_req_header(conn, "cf-connecting-ip") do
      [ip | _] -> ip
      [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  rescue
    _ -> nil
  end
end
