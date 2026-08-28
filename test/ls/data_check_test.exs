defmodule LS.DataCheckTest do
  use ExUnit.Case, async: true

  alias LS.DataCheck

  @moduledoc """
  The data triple-check: quality, quantity, speed (2026-08-28).

  Bands are pure so every threshold is pinned without a ClickHouse. The h1
  incident is the reference failure: 45M hollow rows written while every
  process reported healthy, discovered by a human days later. The quality
  band exists so that shape change emails within the hour.
  """

  describe "quality bands (last hour vs trailing 24h, in points)" do
    test "a fill rate collapsing far below its norm is critical, drifting is a warning" do
      assert DataCheck.quality_band(:fill, 40.0, 85.0, 10_000) == :error
      assert DataCheck.quality_band(:fill, 70.0, 85.0, 10_000) == :warn
      assert DataCheck.quality_band(:fill, 80.0, 85.0, 10_000) == :ok
    end

    test "an error rate spiking far above its norm is critical" do
      assert DataCheck.quality_band(:error, 40.0, 5.0, 10_000) == :error
      assert DataCheck.quality_band(:error, 18.0, 5.0, 10_000) == :warn
      assert DataCheck.quality_band(:error, 8.0, 5.0, 10_000) == :ok
    end

    test "points, not ratios: 60->50 and 20->10 alarm equally" do
      assert DataCheck.quality_band(:fill, 50.0, 60.0, 10_000) ==
               DataCheck.quality_band(:fill, 10.0, 20.0, 10_000)
    end

    test "a small sample never fires: quantity owns 'almost nothing arrived'" do
      assert DataCheck.quality_band(:fill, 0.0, 85.0, 999) == :ok
      assert DataCheck.quality_band(:error, 100.0, 1.0, 12) == :ok
    end
  end

  describe "quantity bands (ratio to trailing hourly average)" do
    test "the CT diurnal swing is normal, a stall is critical" do
      assert DataCheck.quantity_band(5_000, 8_000) == :ok
      assert DataCheck.quantity_band(1_500, 8_000) == :warn
      assert DataCheck.quantity_band(500, 8_000) == :error
      assert DataCheck.quantity_band(0, 8_000) == :error
    end

    test "a flood is a warning too: 4x the norm means a loop or a duplicate source" do
      assert DataCheck.quantity_band(40_000, 8_000) == :warn
      assert DataCheck.quantity_band(15_000, 8_000) == :ok
    end

    test "a stream with no meaningful baseline stays quiet" do
      assert DataCheck.quantity_band(0, 0) == :ok
      assert DataCheck.quantity_band(200, 10) == :ok
    end
  end

  describe "speed bands (absolute, what a user experiences)" do
    test "under warn is ok, between is warn, at or past critical is error" do
      assert DataCheck.speed_band(120, 500, 2_500) == :ok
      assert DataCheck.speed_band(900, 500, 2_500) == :warn
      assert DataCheck.speed_band(2_500, 500, 2_500) == :error
    end
  end

  describe "alerts/1 feeds LS.Alerts in its shape" do
    defp snap do
      %{
        quality: [
          %{label: "country", kind: :fill, recent: 40.0, base: 85.0, band: :error},
          %{label: "MX records", kind: :fill, recent: 90.0, base: 91.0, band: :ok}
        ],
        quantity: [%{label: "discovery rows", recent: 500, base: 8_000, band: :error}],
        speed: [%{label: "shopify filter count", ms: 5_000, warn: 1_000, error: 4_000, band: :error}]
      }
    end

    test "every non-ok metric becomes an alert with severity, key, subject and line" do
      alerts = DataCheck.alerts(snap())
      assert length(alerts) == 3

      for a <- alerts do
        assert a.severity in [:warning, :critical]
        assert a.key =~ ~r/^data_(quality|quantity|speed):/
        assert is_binary(a.subject) and is_binary(a.line)
      end

      assert Enum.all?(alerts, &(&1.severity == :critical))
    end

    test "an all-green snapshot produces no alerts, and hostile input none either" do
      assert DataCheck.alerts(%{quality: [], quantity: [], speed: []}) == []
      assert DataCheck.alerts(nil) == []
      assert DataCheck.alerts(%{}) == []
    end
  end

  describe "the email section" do
    test "carries the color, the dot and the percentages for every band" do
      html = DataCheck.html_section(snap())

      assert html =~ "#dc2626"
      assert html =~ "#16a34a"
      assert html =~ "🔴"
      assert html =~ "🟢"
      assert html =~ "40.0%"
      assert html =~ "norm 85.0%"
      assert html =~ "500/h"
      assert html =~ "5000ms"
    end

    test "a broken snapshot renders as an empty string, never a crashed email" do
      assert DataCheck.html_section(nil) == ""
      assert DataCheck.html_section(%{bogus: true}) == ""
    end
  end
end
