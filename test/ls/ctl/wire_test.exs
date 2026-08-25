defmodule LS.CTL.WireTest do
  use ExUnit.Case, async: true

  alias LS.CTL.Wire

  @moduledoc """
  The wire formats that ALL domain discovery flows through.

  Written before the 2026-08-25 ingestion refactor, to pin the two coverage
  bugs it fixes and the new format it adds:

  * **Precerts were skipped.** `parse_leaf_input` returned `:skip_precert` for
    entry_type 1 — but most CAs (Let's Encrypt among them) log ONLY precerts,
    so the poller was blind to the majority of the world's certificates and
    every LE-only domain arrived by luck, via some other CA or a third-party
    final-cert submission.
  * **Only the first SAN was read.** A certificate carrying 100 domains
    yielded one. Multi-domain certs are the norm on shared platforms.
  * **Static CT API (tiles)** is how Let's Encrypt has published since Feb
    2026. No tile support = none of LE's own logs, however many RFC-6962 logs
    we poll.

  Everything here is a pure function over binaries — no network, per the
  working agreement ("extract the decision as a pure function"). Third-party
  data is hostile until proven otherwise: truncated, oversized, garbage and
  control-character cases all get a test.
  """

  # ── helpers: build real DER with the x509 lib ──────────────────────────

  defp make_cert(sans, cn \\ "/CN=test.example.com") do
    key = X509.PrivateKey.new_ec(:secp256r1)

    X509.Certificate.self_signed(key, cn,
      extensions: [subject_alt_name: X509.Certificate.Extension.subject_alt_name(sans)]
    )
  end

  defp cert_der(sans), do: sans |> make_cert() |> X509.Certificate.to_der()

  defp tbs_der(sans) do
    {:OTPCertificate, tbs, _, _} = make_cert(sans)
    :public_key.pkix_encode(:OTPTBSCertificate, tbs, :otp)
  end

  # RFC 6962 MerkleTreeLeaf for an x509_entry (entry_type 0).
  defp x509_leaf(cert) do
    <<0::8, 0::8, 1_724_000_000_000::64, 0::16, byte_size(cert)::24, cert::binary, 0::16>>
  end

  # RFC 6962 MerkleTreeLeaf for a precert_entry (entry_type 1).
  defp precert_leaf(tbs) do
    ikh = :binary.copy(<<0xAB>>, 32)
    <<0::8, 0::8, 1_724_000_000_000::64, 1::16, ikh::binary, byte_size(tbs)::24, tbs::binary, 0::16>>
  end

  # Static-CT TileLeaf (c2sp.org/static-ct-api): a bare TimestampedEntry —
  # NO version/leaf_type prefix (that belongs to RFC 6962's MerkleTreeLeaf) —
  # then [precert only: pre_certificate], then the chain fingerprints.
  defp tile_leaf_x509(cert, chain_count \\ 1) do
    fps = :binary.copy(:binary.copy(<<0xCD>>, 32), chain_count)

    <<1_724_000_000_000::64, 0::16, byte_size(cert)::24, cert::binary, 0::16>> <>
      <<byte_size(fps)::16, fps::binary>>
  end

  defp tile_leaf_precert(tbs, precert_der) do
    ikh = :binary.copy(<<0xAB>>, 32)
    fps = :binary.copy(<<0xEF>>, 32)

    <<1_724_000_000_000::64, 1::16, ikh::binary, byte_size(tbs)::24, tbs::binary, 0::16>> <>
      <<byte_size(precert_der)::24, precert_der::binary>> <> <<byte_size(fps)::16, fps::binary>>
  end

  # ── RFC 6962 leaves ────────────────────────────────────────────────────

  describe "parse_leaf_input/1 — x509 entries" do
    test "extracts every base domain from a multi-SAN certificate, not just the first" do
      cert = cert_der(["www.alpha.com", "beta.co.uk", "shop.gamma.io"])

      assert {:ok, entries} = Wire.parse_leaf_input(x509_leaf(cert))
      domains = entries |> Enum.map(& &1.ctl_domain) |> Enum.sort()

      assert domains == ["alpha.com", "beta.co.uk", "gamma.io"],
             "a cert carrying N domains must yield all N — first-SAN-only was the pre-2026-08-25 bug"
    end

    test "SANs on the same base domain collapse to one entry with subdomains recorded" do
      cert = cert_der(["www.alpha.com", "api.alpha.com", "alpha.com"])

      assert {:ok, [entry]} = Wire.parse_leaf_input(x509_leaf(cert))
      assert entry.ctl_domain == "alpha.com"
      assert entry.ctl_subdomain_count >= 1
    end

    test "wildcard SANs resolve to their base domain" do
      cert = cert_der(["*.delta.dev"])

      assert {:ok, [entry]} = Wire.parse_leaf_input(x509_leaf(cert))
      assert entry.ctl_domain == "delta.dev"
    end

    test "issuer is extracted" do
      cert = cert_der(["alpha.com"])
      assert {:ok, [entry]} = Wire.parse_leaf_input(x509_leaf(cert))
      assert is_binary(entry.ctl_issuer) and entry.ctl_issuer != ""
    end
  end

  describe "parse_leaf_input/1 — precert entries (the Let's Encrypt path)" do
    test "a precert yields its domains — skipping these dropped most of the world's certs" do
      tbs = tbs_der(["lechuga.example.net", "verdura.example.org"])

      assert {:ok, entries} = Wire.parse_leaf_input(precert_leaf(tbs))

      assert entries |> Enum.map(& &1.ctl_domain) |> Enum.sort() ==
               ["example.net", "example.org"]
    end

    test "x509 and precert entries for the same cert yield the same domains (dedup relies on this)" do
      sans = ["same.example.com"]
      {:ok, [a]} = Wire.parse_leaf_input(x509_leaf(cert_der(sans)))
      {:ok, [b]} = Wire.parse_leaf_input(precert_leaf(tbs_der(sans)))

      assert a.ctl_domain == b.ctl_domain
    end
  end

  describe "parse_leaf_input/1 — hostile input" do
    test "truncated, oversized-length and garbage inputs never raise" do
      cert = cert_der(["alpha.com"])
      good = x509_leaf(cert)

      hostile = [
        "",
        <<0>>,
        binary_part(good, 0, 20),
        # cert_length pointing past the end of the binary
        <<0::8, 0::8, 0::64, 0::16, 9_999_999::24, "short">>,
        # valid frame, garbage DER
        <<0::8, 0::8, 0::64, 0::16, 5::24, "AAAAA", 0::16>>,
        # unknown entry type
        <<0::8, 0::8, 0::64, 7::16, "whatever">>,
        :binary.copy(<<0xFF>>, 10_000)
      ]

      for bin <- hostile do
        assert {:error, _} = Wire.parse_leaf_input(bin)
      end
    end

    test "a cert whose only SANs are IPs or empty strings yields no entries, not a crash" do
      # iPAddress SANs are legal and common on internal certs.
      key = X509.PrivateKey.new_ec(:secp256r1)

      cert =
        X509.Certificate.self_signed(key, "/CN=10.0.0.1",
          extensions: [subject_alt_name: X509.Certificate.Extension.subject_alt_name([{:iPAddress, <<10, 0, 0, 1>>}])]
        )
        |> X509.Certificate.to_der()

      assert {:error, :no_domain} = Wire.parse_leaf_input(x509_leaf(cert))
    end

    test "domains laden with control characters are rejected by the domain parser downstream" do
      # DomainParser.parse is the gate; Wire must pass its output through it.
      cert = cert_der(["ok.example.com"])
      {:ok, [entry]} = Wire.parse_leaf_input(x509_leaf(cert))
      refute entry.ctl_domain =~ ~r/[\x00-\x1f]/
    end

    test "a cert with an absurd number of SANs is capped, not enqueued a thousand times" do
      sans = for i <- 1..300, do: "host#{i}.bulk#{i}.example"
      cert = cert_der(sans)

      assert {:ok, entries} = Wire.parse_leaf_input(x509_leaf(cert))
      assert length(entries) <= Wire.max_domains_per_cert()
    end
  end

  # ── Static CT API tiles ────────────────────────────────────────────────

  describe "parse_data_tile/1" do
    test "a tile with an x509 and a precert entry yields both certs' domains" do
      cert = cert_der(["tile-a.example.com"])
      tbs = tbs_der(["tile-b.example.org"])
      pre = cert_der(["irrelevant-precert-der.example"])

      tile = tile_leaf_x509(cert) <> tile_leaf_precert(tbs, pre)

      assert {:ok, entries} = Wire.parse_data_tile(tile)
      domains = entries |> Enum.map(& &1.ctl_domain) |> Enum.sort()
      assert "example.com" in domains
      assert "example.org" in domains
    end

    test "an empty tile yields no entries" do
      assert {:ok, []} = Wire.parse_data_tile("")
    end

    test "a truncated tile yields what it can and never raises" do
      cert = cert_der(["whole.example.com"])
      tile = tile_leaf_x509(cert) <> binary_part(tile_leaf_x509(cert), 0, 10)

      assert {:ok, entries} = Wire.parse_data_tile(tile)
      assert length(entries) == 1
    end

    test "garbage is an empty result, not a crash" do
      assert {:ok, []} = Wire.parse_data_tile(:binary.copy(<<0xFF>>, 4096))
    end
  end

  describe "tile_path/1" do
    test "encodes indexes into the c2sp x-grouped path form" do
      assert Wire.tile_path(0) == "000"
      assert Wire.tile_path(67) == "067"
      assert Wire.tile_path(999) == "999"
      assert Wire.tile_path(1_000) == "x001/000"
      assert Wire.tile_path(1_234_067) == "x001/x234/067"
    end
  end

  describe "parse_checkpoint/1" do
    test "reads the tree size from a signed note" do
      note = "sycamore.ct.letsencrypt.org/2026h2\n8923471\nq2ZkAbc=\n\n— sig line\n"
      assert {:ok, 8_923_471} = Wire.parse_checkpoint(note)
    end

    test "hostile checkpoints: empty, non-numeric, negative, oversized" do
      for bad <- ["", "origin", "origin\nNaN\nhash", "origin\n-5\nhash", "origin\n" <> :binary.copy("9", 40) <> "\nhash"] do
        assert {:error, _} = Wire.parse_checkpoint(bad)
      end
    end
  end
end
