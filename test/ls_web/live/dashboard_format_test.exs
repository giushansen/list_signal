defmodule LSWeb.DashboardFormatTest do
  use ExUnit.Case, async: true

  @moduledoc """
  2026-08-25: the discovery tab showed "1.2e4/m" in the workers box — queue
  rates are floats and LiveView's default rendering uses scientific notation
  above 1e4. Rates must round-trip to plain comma-grouped integers.
  """

  test "float rates render as plain numbers, never scientific notation" do
    assert LSWeb.DashboardLive.format_int(round(1.2e4)) == "12,000"
    assert LSWeb.DashboardLive.format_int(round(2857.1)) == "2,857"
    assert LSWeb.DashboardLive.format_int(round(0.0)) == "0"
    assert LSWeb.DashboardLive.format_int(round(1.5e6)) == "1,500,000"
    refute LSWeb.DashboardLive.format_int(round(1.2e4)) =~ "e"
  end
end
