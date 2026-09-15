defmodule LS.Verification.SilentZeroRunTest do
  @moduledoc """
  INCIDENT 2026-09-15 (cause dated 2026-08-19). `LS.Verification.HTTP.download/3`
  sends `accept-encoding: gzip` on every request, but a streamed download
  (`into:` with `decode_body: false`) writes the raw transport bytes and Req
  never inflates them. The INPI ratios CSV is served gzipped, so 391 MB of
  gzip was written to a file named `ratios_inpi_bce.csv`. The line parser then
  read binary, every row failed `Sirene.parse_ratio/2`, and the run finished
  with `records: 0` and status `ok`.

  Filed as a success it raised nothing: `verify_error` only fires on a run
  that says "error". `verification_inpi_ratios` sat empty for 27 days, which
  means no Sirene fact has ever carried a French revenue figure — the whole
  point of staging that file. The owner found it by reading the warehouse by
  hand.

  Two defects, two guards, both pinned here:

    * the download must inflate what it asked to be compressed;
    * a run that downloads bytes and parses nothing must not report success.
  """
  use ExUnit.Case, async: true

  alias LS.Verification.HTTP
  alias LS.Verification.Sources.Sirene
  alias LS.Verification.{CSV, Store}

  # The real header and a real row, byte for byte from the live INPI export
  # (note the UTF-8 BOM the export really carries — String.trim/1 eats it,
  # which is why the parser is fine once the bytes are actually CSV).
  @header "﻿siren;date_cloture_exercice;chiffre_d_affaires;marge_brute;ebe;ebit;resultat_net;" <>
            "taux_d_endettement;ratio_de_liquidite;ratio_de_vetuste;autonomie_financiere;" <>
            "poids_bfr_exploitation_sur_ca;couverture_des_interets;caf_sur_ca;capacite_de_remboursement;" <>
            "marge_ebe;resultat_courant_avant_impots_sur_ca;poids_bfr_exploitation_sur_ca_jours;" <>
            "rotation_des_stocks_jours;credit_clients_jours;credit_fournisseurs_jours;type_bilan;confidentiality"
  @row "316742980;2024-12-31;10418682;10418682;560326;246497;34645705;229.975;283.486;1.458;29.927;" <>
         "81.646;24403.248;641.355;8.416;5.378;331.415;293.926;0.0;95.18;96.109;C;Public"

  describe "a gzipped download is inflated before anything reads it" do
    setup do
      dir = Path.join(System.tmp_dir!(), "inpi_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, dir: dir}
    end

    test "the 2026-08-19 shape: gzip bytes on disk parse as nothing", %{dir: dir} do
      # What the run actually wrote. Proving the failure, so the fix below is
      # measured against the real thing and not a guess about it.
      raw = Path.join(dir, "raw.csv")
      File.write!(raw, :zlib.gzip(@header <> "\n" <> @row <> "\n"))

      assert <<0x1F, 0x8B, _::binary>> = File.read!(raw), "the file on disk was gzip, not CSV"

      first_line = File.stream!(raw, [], :line) |> Enum.take(1) |> hd()
      refute match?({:ok, %{"siren" => _}}, CSV.header_index(first_line, ";")),
             "a gzip header must not yield usable column names"
    end

    test "inflating it gives back the real CSV, and the parser was never the problem", %{dir: dir} do
      src = Path.join(dir, "payload.gz")
      dest = Path.join(dir, "ratios.csv")
      File.write!(src, :zlib.gzip(@header <> "\n" <> @row <> "\n"))

      HTTP.gunzip_file!(src, dest)

      lines = File.stream!(dest, [], :line) |> Stream.map(&String.trim_trailing(&1, "\n"))
      {:ok, idx} = lines |> Enum.take(1) |> hd() |> CSV.header_index(";")

      assert Map.has_key?(idx, "siren"), "the BOM must not survive into the column names"

      assert Sirene.parse_ratio(@row, idx) == %{
               siren: "316742980",
               closing: "2024-12-31",
               revenue_eur: 10_418_682.0,
               kind: "C"
             }
    end

    test "inflate streams, so a payload larger than memory is not read whole", %{dir: dir} do
      # The real file is 391 MB in and 900 MB out on a box where ClickHouse
      # already holds 6 GB. Rows here are cheap; what is pinned is that the
      # helper handles a payload spanning many read chunks.
      body = Enum.map_join(1..20_000, "", fn i -> "#{100_000_000 + i};2024-12-31;1000;\n" end)
      src = Path.join(dir, "big.gz")
      dest = Path.join(dir, "big.csv")
      File.write!(src, :zlib.gzip(@header <> "\n" <> body))

      HTTP.gunzip_file!(src, dest)

      assert File.stat!(dest).size == byte_size(@header <> "\n" <> body)
      assert File.stream!(dest, [], :line) |> Enum.count() == 20_001
    end
  end

  describe "content-encoding decides, not the magic bytes" do
    test "gzip is detected in either header shape" do
      assert HTTP.gzip_encoded?(%{headers: %{"content-encoding" => ["gzip"]}})
      assert HTTP.gzip_encoded?(%{headers: [{"content-encoding", "gzip"}]})
      assert HTTP.gzip_encoded?(%{headers: [{"Content-Encoding", "GZIP"}]})
      assert HTTP.gzip_encoded?(%{headers: %{"content-encoding" => ["x-gzip"]}})
    end

    test "anything else is left alone" do
      refute HTTP.gzip_encoded?(%{headers: %{}})
      refute HTTP.gzip_encoded?(%{headers: [{"content-type", "application/gzip"}]})
      refute HTTP.gzip_encoded?(%{headers: %{"content-encoding" => ["br"]}})
      refute HTTP.gzip_encoded?(nil)
    end

    test "a .gz artifact is a payload, not a transport encoding" do
      # Companies House and Sirene download archives. A server does not gzip
      # an archive again, and if a source ever fetches a .gz on purpose it
      # must receive the bytes untouched — hence content-encoding, not magic.
      refute HTTP.gzip_encoded?(%{headers: [{"content-type", "application/x-gzip"}]}),
             "content-type must never trigger inflate"
    end
  end

  describe "a run that parsed nothing is not a success" do
    test "the INPI run as it was recorded is now an error" do
      # started 22:27, finished 22:33, 391,510,608 bytes, 0 records, status ok.
      assert Store.effective_status(:ok, %{bytes: 391_510_608, records: 0}) == :error
    end

    test "a real run is untouched" do
      assert Store.effective_status(:ok, %{bytes: 391_510_608, records: 1_601_506}) == :ok
      assert Store.effective_status(:ok, %{bytes: 2_967_708, records: 2_967_708}) == :ok
    end

    test "an API source reporting no bytes is not caught by this" do
      # wikidata queries SPARQL and yc scrapes JSON; both record bytes: 0, and
      # a genuinely empty upstream is a different thing from a broken parse.
      assert Store.effective_status(:ok, %{bytes: 0, records: 0}) == :ok
      assert Store.effective_status(:ok, %{}) == :ok
    end

    test "an explicit failure stays a failure" do
      assert Store.effective_status(:error, %{bytes: 100, records: 50}) == :error
    end

    test "keyword stats work too, since the callers pass both shapes" do
      assert Store.effective_status(:ok, bytes: 500, records: 0) == :error
      assert Store.effective_status(:ok, bytes: 500, records: 5) == :ok
    end
  end
end
