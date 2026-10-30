defmodule LS.Email.PlaceholderRejectionTest do
  @moduledoc """
  2026-10-30: the backfill of 10-27 had rated placeholder addresses as
  deliverable: youremail@mail.com and esempio2@email.com as good (free
  mail), your@email.com as strong, 32-character Sentry keys on the
  business's own sentry.<host> subdomain as a person's mailbox, and
  noreply@ as a role mailbox, about 250 K rows a campaign would have
  mailed. The SQL form of the rule knew the free-mail list and nothing
  else. The rejection now lives in one place, in Elixir and in its SQL
  twin, and these pin both.
  """
  use ExUnit.Case, async: true

  alias LS.Clickhouse
  alias LS.Email.Score
  alias LS.HTTP.EmailClass

  @facts %{domain: "acme.com", mx: true, provider: "Google Workspace", spf: true, dmarc: true, source_page: "contact", last_seen: ~U[2026-10-29 12:00:00Z], now: ~U[2026-10-30 12:00:00Z]}

  describe "classify/2" do
    test "placeholders in other languages and with a digit suffix are placeholders, on any host" do
      for e <- ~w(esempio2@email.com youremail@mail.com your@email.com beispiel@acme.com
                  max.mustermann@acme.com jean.dupont@gmail.com test3@acme.com user1@acme.com
                  mail@gmail.com info@yahoo.com email@outlook.com) do
        assert EmailClass.classify(e, "acme.com") == :placeholder, e
      end
    end

    test "a generic local on the business's own domain is still a role mailbox" do
      assert EmailClass.classify("email@acme.com", "acme.com") == :role
      assert EmailClass.classify("mail@acme.com", "acme.com") == :role
      assert EmailClass.classify("info@acme.com", "acme.com") == :role
    end

    test "nobody reads noreply@, bounce@ or notifications@" do
      for e <- ~w(noreply@acme.com no-reply@acme.com donotreply@acme.com do-not-reply@acme.com
                  bounces@acme.com notifications@acme.com mailer-daemon@acme.com noreply-sales@acme.com) do
        assert EmailClass.classify(e, "acme.com") == :unattended, e
      end
    end

    test "a Sentry or ingest key is a tracking identifier even on the business's own subdomain" do
      assert EmailClass.classify("8081a58cdf874ec59ece24c964280b00@sentry.1check.in", "1check.in") == :tracking
      assert EmailClass.classify("ae47bc0e8f2246f1b9c1f7e6ac55be41@o1092249.ingest.sentry.io", "123ink.gr") == :tracking
      assert EmailClass.classify("460ff4620fa44cba8df530afde949785@sentry.wixpress.com", "acaitopfrozen.com") == :tracking
    end

    test "a throwaway host is disposable; a real free-mail owner is still kept" do
      assert EmailClass.classify("owner@mailinator.com", "acme.com") == :disposable
      assert EmailClass.classify("acmeshop@yopmail.com", "acme.com") == :disposable
      assert EmailClass.classify("acmeshop@gmail.com", "acme.com") == :free_mail
      assert EmailClass.classify("jane@acme.com", "acme.com") == :named
    end

    test "none of the new kinds is sellable" do
      for k <- [:unattended, :tracking, :disposable, :placeholder], do: refute(k in EmailClass.sellable())
    end
  end

  describe "score/1" do
    test "unattended and tracking are rejected with the reason; disposable is undeliverable at zero" do
      assert %{score: 0, verdict: "rejected", evidence: ["an unattended mailbox"]} = Score.score(Map.put(@facts, :email, "noreply@acme.com"))
      assert %{score: 0, verdict: "rejected", evidence: ["a tracking identifier, not a mailbox"]} = Score.score(Map.put(@facts, :email, "8081a58cdf874ec59ece24c964280b00@sentry.acme.com"))
      assert %{score: 0, verdict: "undeliverable", evidence: ["disposable mail host"]} = Score.score(Map.put(@facts, :email, "owner@mailinator.com"))
      assert %{score: 0, verdict: "rejected"} = Score.score(Map.put(@facts, :email, "esempio2@email.com"))
    end
  end

  describe "the SQL twin" do
    test "the fold's sellable rule and the backfill both carry the rejection" do
      assert EmailClass.sellable_sql() =~ "a form placeholder, not a mailbox"
      sql = Score.backfill_sql(0, 32)
      assert sql =~ "AS why"
      assert sql =~ "why != '', 'rejected'"
      assert sql =~ "WHERE kind != 'other' OR why != ''"
    end

    test "ClickHouse gives the same reasons as classify/2" do
      if match?({:ok, _}, Clickhouse.query_raw("SELECT 1")) do
        cases = [
          {"jane@acme.com", ""},
          {"info@acme.com", ""},
          {"acmeshop@gmail.com", ""},
          {"esempio2@email.com", "a form placeholder, not a mailbox"},
          {"youremail@mail.com", "a form placeholder, not a mailbox"},
          {"your@email.com", "a form placeholder, not a mailbox"},
          {"mail@gmail.com", "a form placeholder, not a mailbox"},
          {"max.mustermann@acme.com", "a form placeholder, not a mailbox"},
          {"name@company.com", "a form placeholder, not a mailbox"},
          {"jane@acme.co.uk", ""},
          {"hello@acme.com", ""},
          {"noreply@acme.com", "an unattended mailbox"},
          {"no-reply@acme.com", "an unattended mailbox"},
          {"8081a58cdf874ec59ece24c964280b00@sentry.1check.in", "a tracking identifier, not a mailbox"},
          {"owner@mailinator.com", "disposable mail host"}
        ]

        for {email, want} <- cases do
          {:ok, [[got]]} = Clickhouse.query_raw("SELECT #{EmailClass.rejected_reason_sql("'#{email}'", "'acme.com'")}")
          assert got == want, email
        end
      end
    end
  end
end
