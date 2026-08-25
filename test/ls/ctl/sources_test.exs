defmodule LS.CTL.SourcesTest do
  use ExUnit.Case, async: true

  alias LS.CTL.Sources

  @moduledoc """
  Source selection: which CT logs we ingest, decided from Chrome's log list
  instead of a hardcoded module attribute.

  2026-08-24/25 found the hand-maintained list wrong twice in two days: four
  frozen 2026h1 shards polled for zero rows, then Sectigo Mammoth/Sabre
  retired under us while Let's Encrypt's tiled logs (most of the world's
  certificates) were invisible because only RFC-6962 was supported. Selection
  is now a pure function of (Chrome JSON, today) so this suite can pin it.
  """

  # A trimmed but structurally-faithful Chrome all_logs_list.json.
  @chrome %{
    "operators" => [
      %{
        "name" => "Google",
        "logs" => [
          %{
            "description" => "Google 'Argon2026h2' log",
            "url" => "https://ct.googleapis.com/logs/us1/argon2026h2/",
            "state" => %{"usable" => %{"timestamp" => "2025-01-01T00:00:00Z"}},
            "temporal_interval" => %{
              "start_inclusive" => "2026-07-01T00:00:00Z",
              "end_exclusive" => "2027-01-01T00:00:00Z"
            }
          },
          %{
            "description" => "Google 'Argon2026h1' log",
            "url" => "https://ct.googleapis.com/logs/us1/argon2026h1/",
            "state" => %{"usable" => %{"timestamp" => "2025-01-01T00:00:00Z"}},
            "temporal_interval" => %{
              "start_inclusive" => "2026-01-01T00:00:00Z",
              "end_exclusive" => "2026-07-01T00:00:00Z"
            }
          }
        ],
        "tiled_logs" => [
          %{
            "description" => "Google 'ParcelYard2026h2' log",
            "submission_url" => "https://parcelyard2026h2.prod.certificate.transparency.goog/",
            "monitoring_url" =>
              "https://storage.googleapis.com/parcelyard2026h2.prod.certificate.transparency.goog/",
            "state" => %{"qualified" => %{"timestamp" => "2026-05-01T00:00:00Z"}},
            "temporal_interval" => %{
              "start_inclusive" => "2026-07-01T00:00:00Z",
              "end_exclusive" => "2027-01-01T00:00:00Z"
            }
          }
        ]
      },
      %{
        "name" => "Let's Encrypt",
        "logs" => [
          %{
            "description" => "Let's Encrypt 'Oak2026h1' log",
            "url" => "https://oak.ct.letsencrypt.org/2026h1/",
            "state" => %{"retired" => %{"timestamp" => "2026-02-28T00:00:00Z"}},
            "temporal_interval" => %{
              "start_inclusive" => "2026-01-01T00:00:00Z",
              "end_exclusive" => "2026-07-01T00:00:00Z"
            }
          }
        ],
        "tiled_logs" => [
          %{
            "description" => "Let's Encrypt 'Sycamore2026h2'",
            "submission_url" => "https://sycamore.ct.letsencrypt.org/2026h2/",
            "monitoring_url" => "https://mon.sycamore.ct.letsencrypt.org/2026h2/",
            "state" => %{"usable" => %{"timestamp" => "2026-06-01T00:00:00Z"}},
            "temporal_interval" => %{
              "start_inclusive" => "2026-07-01T00:00:00Z",
              "end_exclusive" => "2027-01-01T00:00:00Z"
            }
          }
        ]
      },
      %{
        "name" => "Sectigo",
        "logs" => [
          %{
            "description" => "Sectigo 'Mammoth2026h2'",
            "url" => "https://mammoth2026h2.ct.sectigo.com/",
            "state" => %{"rejected" => %{"timestamp" => "2026-08-01T00:00:00Z"}},
            "temporal_interval" => %{
              "start_inclusive" => "2026-07-01T00:00:00Z",
              "end_exclusive" => "2027-01-01T00:00:00Z"
            }
          }
        ]
      }
    ]
  }

  @today ~D[2026-08-25]

  describe "desired/2" do
    test "selects usable RFC-6962 logs covering today, with the /ct/v1 API base" do
      sources = Sources.desired(@chrome, @today)
      argon = Enum.find(sources, &(&1.name =~ "Argon2026h2"))

      assert argon.protocol == :rfc6962
      assert argon.url == "https://ct.googleapis.com/logs/us1/argon2026h2/ct/v1"
    end

    test "selects tiled logs by monitoring_url — Let's Encrypt is only reachable this way" do
      sources = Sources.desired(@chrome, @today)
      syc = Enum.find(sources, &(&1.name =~ "Sycamore"))

      assert syc.protocol == :static_ct
      assert syc.url == "https://mon.sycamore.ct.letsencrypt.org/2026h2"
    end

    test "qualified tiled logs count as ingestible (they hold certs before Chrome flips them usable)" do
      assert Enum.any?(Sources.desired(@chrome, @today), &(&1.name =~ "ParcelYard"))
    end

    test "a frozen shard is excluded even while its state is still 'usable' — the 2026-08-24 zero-inflow bug" do
      refute Enum.any?(Sources.desired(@chrome, @today), &(&1.name =~ "2026h1"))
    end

    test "rejected and retired logs are excluded — Mammoth kept polling after Sectigo pulled it" do
      names = Enum.map(Sources.desired(@chrome, @today), & &1.name)
      refute Enum.any?(names, &(&1 =~ "Mammoth"))
      refute Enum.any?(names, &(&1 =~ "Oak"))
    end

    test "every source carries the tuning the poller needs" do
      for s <- Sources.desired(@chrome, @today) do
        assert s.batch_size > 0
        assert s.min_workers >= 1 and s.max_workers >= s.min_workers
        assert is_integer(s.target_lag) and s.target_lag > 0
        assert String.starts_with?(s.url, "https://")
      end
    end

    test "google RFC-6962 logs keep their 32-entry batch cap" do
      argon = Sources.desired(@chrome, @today) |> Enum.find(&(&1.name =~ "Argon"))
      assert argon.batch_size == 32
    end

    test "static tiles batch in full 256-entry tiles" do
      syc = Sources.desired(@chrome, @today) |> Enum.find(&(&1.name =~ "Sycamore"))
      assert syc.batch_size == 256
    end

    test "hostile JSON shapes return [] rather than raising" do
      for bad <- [%{}, %{"operators" => nil}, %{"operators" => [%{"logs" => [%{"state" => "usable"}]}]}, nil] do
        assert Sources.desired(bad, @today) == []
      end
    end
  end

  describe "reconcile/2 — the auto add/ditch decision" do
    defp src(name), do: %{name: name, url: "https://#{name}/ct/v1", protocol: :rfc6962}

    test "starts what Chrome added, stops what Chrome pulled, leaves the rest alone" do
      running = [src("argon"), src("mammoth")]
      desired = [src("argon"), src("sycamore")]

      assert %{start: [%{name: "sycamore"}], stop: ["mammoth"]} = Sources.reconcile(running, desired)
    end

    test "no drift means no action — reconcile must be idempotent" do
      running = [src("argon")]
      assert %{start: [], stop: []} = Sources.reconcile(running, running)
    end

    test "an empty desired list stops nothing — a failed or empty fetch must never dismantle ingestion" do
      running = [src("argon"), src("xenon")]
      assert %{start: [], stop: []} = Sources.reconcile(running, [])
    end
  end
end
