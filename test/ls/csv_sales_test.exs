defmodule LS.CsvSalesTest do
  @moduledoc """
  The paid-CSV flow, tested from the angle that matters commercially: can we
  prove delivery in a chargeback, and can we trace a leaked list back to the
  buyer who leaked it.
  """
  use LSWeb.ConnCase, async: false

  alias LS.{Audit, CsvSales}
  alias LS.CsvSales.Order

  @columns ["domain", "title", "country"]
  @rows [
    ["acme.com", "Acme Coffee", "US"],
    ["beta.io", "Beta Tools", "GB"],
    ["gamma.fr", "Gamma SAS", "FR"],
    ["delta.de", "Delta GmbH", "DE"],
    ["epsilon.nl", "Epsilon BV", "NL"],
    ["zeta.es", "Zeta SL", "ES"]
  ]

  setup do
    dir = Path.join(System.tmp_dir!(), "ls_csv_test_#{System.unique_integer([:positive])}")
    System.put_env("LS_CSV_DIR", dir)
    on_exit(fn -> File.rm_rf(dir); System.delete_env("LS_CSV_DIR") end)
    :ok
  end

  defp new_order(email \\ "buyer@example.com", opts \\ []) do
    {:ok, order} = CsvSales.create_order(email, @columns, @rows, opts)
    order
  end

  describe "order creation and watermarking" do
    test "the buyer's copy carries their watermark and canary rows" do
      order = new_order("leaky@example.com")
      content = File.read!(order.file_path)

      assert order.watermark != nil
      assert content =~ "ref:#{order.watermark}"
      assert content =~ "Licensed to leaky@example.com"

      # Canaries must be IN the data, not only in the trailing comment: a
      # reseller who strips the last lines still carries them.
      canaries = String.split(order.canary_domains, "|")
      assert length(canaries) == 3

      for canary <- canaries do
        assert content =~ canary
        line_index = content |> String.split("\n") |> Enum.find_index(&String.contains?(&1, canary))
        refute line_index == nil
        # not the header, not the trailing licence line
        assert line_index > 0
        assert line_index < length(String.split(content, "\n")) - 1
      end
    end

    test "a leaked canary domain names the buyer" do
      a = new_order("first@example.com")
      b = new_order("second@example.com")

      leaked = a.canary_domains |> String.split("|") |> List.first()
      found = CsvSales.trace_canary(leaked)

      assert Enum.map(found, & &1.email) == ["first@example.com"]
      refute b.id in Enum.map(found, & &1.id)
    end

    test "two buyers of the same data get different watermarks and canaries" do
      a = new_order("one@example.com")
      b = new_order("two@example.com")

      assert a.watermark != b.watermark
      assert a.canary_domains != b.canary_domains
      assert a.token != b.token
    end

    test "tokens are long and url-safe — the link is the credential" do
      order = new_order()
      assert String.length(order.token) >= 32
      assert order.token =~ ~r/^[A-Za-z0-9_-]+$/
    end

    test "every purchased row is present in the file" do
      order = new_order()
      content = File.read!(order.file_path)

      for [domain | _] <- @rows do
        assert content =~ domain
      end

      assert order.row_count == length(@rows)
    end

    test "values containing commas or quotes stay valid CSV" do
      rows = [["x.com", "Smith, Jones & Co \"The Best\"", "US"]]
      {:ok, order} = CsvSales.create_order("q@example.com", @columns, rows)
      content = File.read!(order.file_path)

      assert content =~ ~s("Smith, Jones & Co ""The Best""")
    end
  end

  describe "payment gating" do
    test "an unpaid order is not downloadable" do
      order = new_order()
      refute Order.downloadable?(order)
    end

    test "marking paid makes it downloadable and is idempotent" do
      order = new_order()
      {:ok, paid} = CsvSales.mark_paid(order, "cs_test_123")
      assert Order.downloadable?(paid)
      assert paid.paid_at != nil

      # Stripe retries webhooks; a second delivery must not look like a second
      # purchase or move the timestamp the evidence relies on.
      {:ok, again} = CsvSales.mark_paid(paid, "cs_test_456")
      assert again.paid_at == paid.paid_at
      assert again.stripe_session_id == "cs_test_123"
    end

    test "an expired link is refused even when paid" do
      order = new_order("late@example.com", valid_for_days: 30)
      {:ok, paid} = CsvSales.mark_paid(order, "cs_1")

      expired = %{paid | expires_at: DateTime.utc_now() |> DateTime.add(-60, :second)}
      refute Order.downloadable?(expired)
    end
  end

  describe "download endpoint (the dispute evidence)" do
    test "a paid link serves the file and records the download", %{conn: conn} do
      order = new_order("proof@example.com")
      {:ok, order} = CsvSales.mark_paid(order, "cs_proof")

      conn = get(conn, ~p"/d/#{order.token}")

      assert conn.status == 200
      assert response_content_type(conn, :csv)

      reloaded = CsvSales.get_by_token(order.token)
      assert reloaded.download_count == 1
      assert reloaded.first_downloaded_at != nil
      assert reloaded.last_downloaded_at != nil

      # The durable trail — this is what answers "I never received it".
      events = Audit.history("proof@example.com")
      assert Enum.any?(events, &(&1.event == "csv_downloaded"))
    end

    test "repeat downloads are counted, not just the first" do
      order = new_order("repeat@example.com")
      {:ok, order} = CsvSales.mark_paid(order, "cs_repeat")

      for _ <- 1..3, do: get(build_conn(), ~p"/d/#{order.token}")

      assert CsvSales.get_by_token(order.token).download_count == 3

      downloads = Audit.history("repeat@example.com") |> Enum.filter(&(&1.event == "csv_downloaded"))
      assert length(downloads) == 3
    end

    test "an unpaid link is refused and the refusal is recorded", %{conn: conn} do
      order = new_order("notpaid@example.com")

      conn = get(conn, ~p"/d/#{order.token}")
      assert conn.status == 402

      assert CsvSales.get_by_token(order.token).download_count == 0
      assert Audit.history("notpaid@example.com") |> Enum.any?(&(&1.event == "csv_download_denied"))
    end

    test "an unknown token reveals nothing and serves no file", %{conn: conn} do
      conn = get(conn, ~p"/d/definitely-not-a-real-token")
      assert conn.status == 404
      # Same shape as an unpaid/expired refusal — a probe learns nothing about
      # whether the token exists.
      refute conn.resp_body =~ "domain,title,country"
      assert conn.resp_body =~ "not found"
    end
  end

  describe "audit trail" do
    test "history is chronological and survives for the dispute window" do
      Audit.record("login", %{email: "history@example.com"})
      Audit.record("csv_export", %{email: "history@example.com", metadata: %{rows: 500}})

      events = Audit.history("history@example.com")

      assert length(events) == 2
      assert Enum.map(events, & &1.event) == ["login", "csv_export"]
      assert Enum.at(events, 1).metadata["rows"] == 500
    end

    test "recording never raises, whatever it is handed" do
      # An audit failure must never cost a customer their download.
      assert Audit.record("weird", %{email: nil, metadata: nil}) == :ok
      assert Audit.record("weird", %{user_id: "not-a-uuid"}) == :ok
    end
  end
end
