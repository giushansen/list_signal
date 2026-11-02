defmodule LS.Email.VerifierMailFactsTest do
  @moduledoc """
  2026-10-31: the live scorer's facts query named `is_disposable_email`, a
  column `businesses` does not have. Every query failed, the failure came
  back as an empty map, an empty map reads as "no MX", and every address
  re-sighted from 10-27 to 10-31 was written `undeliverable` over its
  verdict: 202,846 addresses on domains with MX, 151,840 businesses,
  52,809 named. VerifierTest could not see it, because a domain with no
  compiled row is expected to come out undeliverable too.

  Two guards: the query runs against the real schema and finds the MX of a
  row that has one, and facts that could not be read write nothing.
  """
  use ExUnit.Case, async: false

  alias LS.Clickhouse
  alias LS.Email.Verifier

  defp ch_up?, do: match?({:ok, _}, Clickhouse.query_raw("SELECT 1"))

  describe "the facts query reads the real product table (2026-10-31, 202,846 verdicts lost)" do
    @describetag :data_contract

    test "a business with MX is seen to have MX, and its address is not undeliverable" do
      if ch_up?() do
        d = "mx-facts-#{System.unique_integer([:positive])}.example"
        on_exit(fn -> Clickhouse.query_raw("ALTER TABLE businesses DELETE WHERE domain = '#{d}'") end)

        # Old stamps on purpose: a row stamped now() makes the harness look
        # freshly crawled, and the freshness contracts then demand a fresh
        # tech index the laptop does not build.
        {:ok, _} =
          Clickhouse.query_raw(
            "INSERT INTO businesses (domain, ctl_first_seen_at, compiled_at, http_last_checked_at, dns_mx, dns_email_provider, dns_dmarc) " <>
              "VALUES ('#{d}', '2026-01-01 00:00:00', '2026-01-01 00:00:00', '2026-01-01 00:00:00', ['10:mx.#{d}'], 'Google Workspace', 'v=DMARC1; p=none')"
          )

        assert {:ok, %{^d => facts}} = Verifier.mail_facts([d])
        assert facts.mx == true
        assert facts.dmarc == true
        assert facts.provider == "Google Workspace"

        [check] = Verifier.score_rows([%{domain: d, email: "hello@#{d}", source_page: "contact", seen_at: "2026-10-30 10:00:00"}])
        assert check.verdict in ["strong", "good"]
        refute "no MX record: mail cannot be delivered" in check.evidence
      end
    end
  end

  describe "facts that could not be read score nothing" do
    test "an unreadable facts query writes no verdict at all" do
      rows = [%{domain: "acme.com", email: "maria.lopez@acme.com", source_page: "about"}]
      assert Verifier.checks(rows, :error) == []
    end

    test "with MX known, a named contact-page address is rated on its evidence" do
      rows = [%{domain: "acme.com", email: "maria.lopez@acme.com", source_page: "about", seen_at: "2026-10-30 10:00:00"}]
      facts = %{"acme.com" => %{mx: true, provider: "Google Workspace", dmarc: true, spf: true}}
      [check] = Verifier.checks(rows, {:ok, facts})
      assert check.kind == "named"
      assert check.verdict in ["strong", "good"]
    end

    test "with no compiled row, the address is undeliverable for want of MX, as before" do
      rows = [%{domain: "acme.com", email: "maria.lopez@acme.com", source_page: "about"}]
      [check] = Verifier.checks(rows, {:ok, %{}})
      assert check.verdict == "undeliverable"
      assert hd(check.evidence) == "no MX record: mail cannot be delivered"
    end
  end
end
