defmodule LSWeb.TechUnknownSlugTest do
  use LSWeb.ConnCase, async: false

  @moduledoc """
  An unknown /tech/<slug> is a free 404 (2026-09-07). It used to fall
  through to a capitalised guess and an ILIKE scan of the whole table, and
  every invented slug was a new cache key: a crawler walking 145 invented
  slugs in 25 minutes put 415 concurrent 20-minute scans on ClickHouse,
  load 120 on the master, every query timing out, and "Search unavailable"
  on a customer's dashboard.
  """

  test "a slug the directory does not know is 404 without touching ClickHouse", %{conn: conn} do
    conn = get(conn, "/tech/acupuncture-traditional-chinese-medicine-in-toronto")
    assert conn.status == 404
  end

  test "the fallbacks that scanned the table are gone" do
    src = File.read!("lib/ls_web/controllers/tech_controller.ex")
    refute src =~ "stores_by_tech_full_ilike"
    refute src =~ "Enum.map(&String.capitalize/1)"
    assert src =~ "nil -> conn |> put_status(:not_found)"
  end
end
