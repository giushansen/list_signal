defmodule LS.CTL.Wire do
  @moduledoc """
  Pure parsers for the two certificate-transparency wire formats, from bytes
  to `[%{ctl_domain, ...}]` — every domain ListSignal discovers passes through
  here.

  ## Why this replaced the parsing inside the poller (2026-08-25)

  Two coverage bugs and a missing format were silently narrowing discovery:

  * **Precerts were skipped** (`entry_type 1 → :skip_precert`). Most CAs log
    certificates as precerts only — Let's Encrypt, the largest CA, logs
    nothing else — so the majority of the world's certificates were invisible
    and an LE-only domain was discovered only if some third party submitted
    the final cert somewhere.
  * **Only the first SAN was read.** Multi-domain certificates are the norm
    (shared platforms bundle dozens), and every domain after the first was
    dropped.
  * **The Static CT API** (`c2sp.org/static-ct-api`, tile-based) is how Let's
    Encrypt publishes since it shut its RFC-6962 logs in Feb 2026, and how
    several newer operators publish exclusively.

  All functions are pure over binaries so the whole surface is testable
  without a network (`test/ls/ctl/wire_test.exs`). CT entries are third-party
  data — hostile until proven otherwise; nothing here may raise.
  """

  alias LS.CTL.DomainParser

  # A certificate carrying hundreds of SANs is a shared-hosting artifact, not
  # hundreds of leads; the platform filter will learn the pattern, but cap the
  # blast radius of any single hostile cert regardless.
  @max_domains_per_cert 25
  @san_oid {2, 5, 29, 17}

  @doc "Ceiling on distinct base domains extracted from one certificate."
  def max_domains_per_cert, do: @max_domains_per_cert

  # ── RFC 6962 (get-entries `leaf_input`) ────────────────────────────────

  @doc """
  Parse one RFC 6962 MerkleTreeLeaf into `{:ok, [cert_data]}` — one element
  per distinct base domain in the certificate.

  Handles BOTH entry types: `0` (final certificate) and `1` (precertificate,
  whose TBSCertificate carries the same SANs).
  """
  @spec parse_leaf_input(binary()) :: {:ok, [map()]} | {:error, atom()}
  def parse_leaf_input(<<_v::8, _lt::8, _ts::64, 0::16, len::24, cert::binary-size(len), _::binary>>) do
    entries_from_cert_der(cert)
  end

  def parse_leaf_input(<<_v::8, _lt::8, _ts::64, 1::16, _ikh::binary-size(32), len::24, tbs::binary-size(len), _::binary>>) do
    entries_from_tbs_der(tbs)
  end

  def parse_leaf_input(_), do: {:error, :invalid_format}

  # ── Static CT API data tiles ───────────────────────────────────────────

  @doc """
  Parse a data tile (concatenated TileLeaf structures, up to 256) into
  `{:ok, [cert_data]}`.

  Unlike `leaf_input`, tile entries have NO version/leaf_type prefix, and a
  precert entry is followed by the full precertificate DER and a fingerprint
  list that must be skipped to reach the next entry. A truncated tail yields
  the entries before it — never an exception — because a partial read of a
  CDN object must not cost the whole tile.
  """
  @spec parse_data_tile(binary()) :: {:ok, [map()]}
  def parse_data_tile(bin) when is_binary(bin), do: {:ok, walk_tile(bin, [])}

  defp walk_tile(<<_ts::64, 0::16, len::24, cert::binary-size(len), ext_len::16, _ext::binary-size(ext_len), fp_len::16, _fps::binary-size(fp_len), rest::binary>>, acc) do
    walk_tile(rest, collect(entries_from_cert_der(cert), acc))
  end

  defp walk_tile(<<_ts::64, 1::16, _ikh::binary-size(32), len::24, tbs::binary-size(len), ext_len::16, _ext::binary-size(ext_len), pre_len::24, _pre::binary-size(pre_len), fp_len::16, _fps::binary-size(fp_len), rest::binary>>, acc) do
    walk_tile(rest, collect(entries_from_tbs_der(tbs), acc))
  end

  # Truncated or malformed remainder: keep what we have.
  defp walk_tile(_rest, acc), do: Enum.reverse(acc) |> List.flatten()

  defp collect({:ok, entries}, acc), do: [entries | acc]
  defp collect({:error, _}, acc), do: acc

  @doc """
  The c2sp path form of a tile index: decimal, grouped in threes, every group
  but the last prefixed `x`. `1234067 → "x001/x234/067"`.
  """
  @spec tile_path(non_neg_integer()) :: String.t()
  def tile_path(n) when is_integer(n) and n >= 0 do
    digits = Integer.to_string(n)
    padded = String.pad_leading(digits, ceil(byte_size(digits) / 3) * 3, "0")

    padded
    |> chunk3()
    |> then(fn groups ->
      {init, [last]} = Enum.split(groups, -1)
      Enum.map_join(init, "", &("x" <> &1 <> "/")) <> last
    end)
  end

  defp chunk3(s), do: for(<<g::binary-size(3) <- s>>, do: g)

  @doc """
  Tree size from a checkpoint (a signed note: origin, size, root hash, then
  signatures). Only the size is needed; the size line must be a plain decimal
  of sane length — a log cannot have 10^16 entries, so anything longer is
  garbage, not growth.
  """
  @spec parse_checkpoint(binary()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def parse_checkpoint(note) when is_binary(note) do
    case String.split(note, "\n") do
      [origin, size_line, _hash | _] when origin != "" ->
        if size_line =~ ~r/^\d{1,15}$/ do
          {:ok, String.to_integer(size_line)}
        else
          {:error, :bad_tree_size}
        end

      _ ->
        {:error, :bad_checkpoint}
    end
  end

  def parse_checkpoint(_), do: {:error, :bad_checkpoint}

  # ── certificate → cert_data ────────────────────────────────────────────

  defp entries_from_cert_der(der) do
    case X509.Certificate.from_der(der) do
      {:ok, cert} ->
        sans = san_names(cert)
        names = if sans == [], do: List.wrap(subject_cn(cert)), else: sans
        build_entries(names, issuer_cn(cert))

      {:error, _} ->
        {:error, :invalid_x509_cert}
    end
  end

  # A precert's TBSCertificate has no outer Certificate wrapper, so the X509
  # lib can't read it; decode the plain ASN.1 and take the SAN extension.
  # SAN-only is fine here: the CA/B forum has required SANs since 2015, and a
  # precert is by definition a modern cert.
  defp entries_from_tbs_der(der) do
    tbs = :public_key.der_decode(:TBSCertificate, der)
    exts = elem(tbs, 10)

    sans =
      case is_list(exts) && List.keyfind(exts, @san_oid, 1) do
        {:Extension, @san_oid, _critical, value} when is_binary(value) ->
          :public_key.der_decode(:SubjectAltName, value)
          |> Enum.flat_map(fn
            {:dNSName, name} -> [to_string(name)]
            _ -> []
          end)

        _ ->
          []
      end

    build_entries(sans, tbs_issuer_cn(tbs))
  rescue
    _ -> {:error, :invalid_tbs}
  end

  # names → one cert_data per distinct base domain, subdomains folded in.
  defp build_entries(names, issuer) do
    parsed =
      names
      |> Enum.filter(&is_binary/1)
      |> Enum.flat_map(fn name ->
        case DomainParser.parse(name) do
          {:ok, base, tld} ->
            # An all-digit TLD means the "name" was an IP address (a CN of
            # 10.0.0.1 parses as domain "0.1", tld "1") — junk, not a lead.
            if tld =~ ~r/^\d+$/, do: [], else: [{base, tld, clean_name(name)}]
          :error -> []
        end
      end)

    case parsed do
      [] ->
        {:error, :no_domain}

      _ ->
        entries =
          parsed
          |> Enum.group_by(fn {base, _, _} -> base end)
          |> Enum.take(@max_domains_per_cert)
          |> Enum.map(fn {base, group} ->
            {_, tld, _} = hd(group)
            {count, list} = subdomains(base, Enum.map(group, fn {_, _, full} -> full end))

            %{
              ctl_domain: base,
              ctl_tld: tld,
              ctl_issuer: issuer,
              ctl_subdomain_count: count,
              ctl_subdomains: list
            }
          end)

        {:ok, entries}
    end
  end

  defp clean_name(name), do: name |> String.downcase() |> String.replace(~r/^\*\./, "") |> String.trim()

  defp subdomains(base, full_names) do
    parts =
      full_names
      |> Enum.flat_map(fn full ->
        case String.replace_suffix(full, "." <> base, "") do
          ^full -> []
          prefix -> String.split(prefix, ".")
        end
      end)
      |> Enum.uniq()
      |> Enum.take(50)

    {length(parts), Enum.join(parts, "|")}
  end

  # ── name extraction (full certs via the X509 lib) ──────────────────────

  defp san_names(cert) do
    case X509.Certificate.extension(cert, :subject_alt_name) do
      {:Extension, @san_oid, _, san_value} when is_list(san_value) ->
        Enum.flat_map(san_value, fn
          {:dNSName, name} -> [to_string(name)]
          _ -> []
        end)

      _ ->
        []
    end
  end

  defp subject_cn(cert), do: cert |> X509.Certificate.subject() |> rdn_cn()
  defp issuer_cn(cert), do: (cert |> X509.Certificate.issuer() |> rdn_cn()) || "Unknown"

  defp rdn_cn({:rdnSequence, attrs}) do
    Enum.find_value(attrs, fn attr_list ->
      Enum.find_value(attr_list, fn
        {:AttributeTypeAndValue, {2, 5, 4, 3}, {:utf8String, v}} -> to_string(v)
        {:AttributeTypeAndValue, {2, 5, 4, 3}, {:printableString, v}} -> to_string(v)
        _ -> nil
      end)
    end)
  end

  defp rdn_cn(_), do: nil

  # Plain-ASN.1 issuer: attribute values arrive still DER-encoded.
  defp tbs_issuer_cn(tbs) do
    case elem(tbs, 4) do
      {:rdnSequence, attrs} ->
        Enum.find_value(attrs, "Unknown", fn attr_list ->
          Enum.find_value(attr_list, fn
            {:AttributeTypeAndValue, {2, 5, 4, 3}, der} when is_binary(der) ->
              case :public_key.der_decode(:X520CommonName, der) do
                {:utf8String, v} -> to_string(v)
                {:printableString, v} -> to_string(v)
                _ -> nil
              end

            _ ->
              nil
          end)
        end)

      _ ->
        "Unknown"
    end
  rescue
    _ -> "Unknown"
  end
end
