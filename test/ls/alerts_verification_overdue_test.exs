defmodule LS.AlertsVerificationOverdueTest do
  @moduledoc """
  INCIDENT 2026-09-15. The owner opened the warehouse by hand, found every
  registry verification source 27 days old, and asked why no alert had ever
  fired. Nothing could have fired:

    * `verify_error` needs a run row whose status is "error";
    * `verify_stuck` needs a task still holding the scheduler;
    * the data QUANTITY check watches three streams — domains_current,
      businesses and biz_enrichment — and no verification table at all.

  A source that quietly stops being scheduled produces none of those signals.
  The pipeline going silent looked exactly like the pipeline being healthy,
  and would have kept looking that way indefinitely.

  These pin the check that makes absence visible. If it is ever removed
  because "DataCheck covers quantity", read the list above again: it does
  not cover this, and the failure stays invisible until somebody reads the
  table by hand.
  """
  use ExUnit.Case, async: true

  alias LS.Alerts

  @day 86_400
  @weekly 7 * @day
  @monthly 30 * @day

  # evaluate/1 walks every check, and the fleet checks have no catch-all
  # clause — they are never absent in production. A neutral map says "the
  # fleet is fine", so anything these tests see comes from the source list.
  defp base(extra \\ %{}) do
    Map.merge(
      %{
        known_workers: [],
        per_worker: [],
        worker_health: %{},
        node_resources: [],
        reputation_ages: %{}
      },
      extra
    )
  end

  defp fresh(source, age_s, cadence_s),
    do: %{source: source, age_s: age_s, cadence_s: cadence_s}

  defp overdue(sources), do: Alerts.evaluate(base(%{verification_freshness: sources}))

  describe "a source is judged against its own cadence" do
    test "fresh inside the cadence is silent" do
      assert Alerts.verify_freshness_band(1 * @day, @weekly) == :ok
      assert Alerts.verify_freshness_band(6 * @day, @weekly) == :ok
      assert Alerts.verify_freshness_band(27 * @day, @monthly) == :ok
    end

    test "the two-day grace absorbs a long pass and a restart, not a skipped run" do
      # The scheduler ticks every 30 min and runs one source at a time, so a
      # genuine slip is minutes: Sirene's full pass took 14.
      assert Alerts.verify_freshness_band(@weekly + 1 * @day, @weekly) == :ok
      assert Alerts.verify_freshness_band(@weekly + 2 * @day + 60, @weekly) == :warning
      assert Alerts.verify_freshness_band(@monthly + 3 * @day, @monthly) == :warning
    end

    test "twice the cadence is critical" do
      assert Alerts.verify_freshness_band(15 * @day, @weekly) == :critical
      assert Alerts.verify_freshness_band(61 * @day, @monthly) == :critical
    end

    test "a source that has never completed a run is critical immediately" do
      # The worst case and the quietest: no row at all means no error row,
      # so every other check is structurally blind to it.
      assert Alerts.verify_freshness_band(nil, @weekly) == :critical
      assert Alerts.verify_freshness_band(nil, @monthly) == :critical
    end

    test "a source the scheduler does not manage is never banded" do
      # inpi and companies_house_accounts wrote once on 2026-08-19 and are not
      # in LS.Verification.sources/0. Whether to schedule them is a decision
      # about bandwidth and disk, not something an alert may imply.
      assert Alerts.verify_freshness_band(27 * @day, nil) == :ok
      assert Alerts.verify_freshness_band(nil, nil) == :ok
    end
  end

  describe "the 2026-09-15 state, replayed" do
    test "27 days into a 30-day cadence stays silent, because it is not yet late" do
      # The honest reading of the incident: on the day the owner asked, the
      # registries were within cadence. What was broken is that nothing would
      # have spoken up three days later either.
      assert overdue([
               fresh("sec_edgar", 27 * @day, @monthly),
               fresh("companies_house", 27 * @day, @monthly),
               fresh("sirene", 27 * @day, @monthly),
               fresh("wikidata", 6 * @day, @weekly),
               fresh("yc", 7 * @day, @weekly)
             ]) == []
    end

    test "the same sources three days past due raise one alert each" do
      alerts =
        overdue([
          fresh("sec_edgar", 33 * @day, @monthly),
          fresh("companies_house", 33 * @day, @monthly),
          fresh("sirene", 6 * @day, @monthly),
          fresh("wikidata", 6 * @day, @weekly),
          fresh("yc", 7 * @day, @weekly)
        ])

      assert Enum.map(alerts, & &1.key) |> Enum.sort() ==
               ["verify_overdue:companies_house", "verify_overdue:sec_edgar"]

      assert Enum.all?(alerts, &(&1.severity == :warning))
      assert Enum.all?(alerts, &(&1.subject =~ "Verification overdue"))
    end

    test "the alert line names the source, its age and its cadence" do
      [alert] = overdue([fresh("sec_edgar", 33 * @day, @monthly)])

      assert alert.line =~ "sec_edgar"
      assert alert.line =~ "33d"
      assert alert.line =~ "30d"
    end

    test "a never-run source says so plainly, and is critical" do
      [alert] = overdue([fresh("sec_edgar", nil, @monthly)])

      assert alert.severity == :critical
      assert alert.line =~ "never completed a run"
    end

    test "one key per source, so a cooldown on one never silences another" do
      alerts =
        overdue([fresh("sec_edgar", nil, @monthly), fresh("companies_house", nil, @monthly)])

      assert length(Enum.uniq_by(alerts, & &1.key)) == 2
    end
  end

  describe "the check is wired in, not just defined" do
    test "a healthy fleet with no freshness data raises nothing" do
      assert Alerts.evaluate(base()) == []
    end

    test "gather/0 supplies the metric and evaluate/1 runs the check" do
      # A pure function nobody calls is the same as no check at all. That is
      # the shape of the original bug, one level down.
      src = File.read!("lib/ls/alerts.ex")
      assert src =~ "verification_freshness: Metrics.verification_freshness()"
      assert src =~ "|> verification_overdue(m)"
      Code.ensure_loaded!(LS.Metrics)
      assert function_exported?(LS.Metrics, :verification_freshness, 0)
    end

    test "every scheduled source has a cadence, or it can never be judged overdue" do
      # A source in sources/0 with no @every entry compares `age > nil`, which
      # is always false under Elixir term ordering: it would never come due
      # and never read as overdue, silently, forever.
      for source <- LS.Verification.sources() do
        assert is_integer(LS.Verification.Scheduler.cadence_s(source)),
               "#{source} is scheduled but has no cadence: it can never run again, and never alert"
      end
    end
  end
end
