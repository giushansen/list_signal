defmodule LS.EngagementTest do
  @moduledoc """
  Three emails and a hard promise: never spam. The invariants under test are
  exactly the ones that would break that promise if they regressed —
  unsubscribe honoured durably, one digest a week, the wall email once ever,
  and the digest anchored on the user's REAL last search.
  """
  use LS.DataCase, async: false

  import Swoosh.TestAssertions

  alias LS.{Accounts, Audit, Engagement, Repo}
  alias LS.Accounts.User

  defp user!(email, attrs \\ %{}) do
    {:ok, user} = Accounts.register_user(%{email: email})

    user
    |> Ecto.Changeset.change(
      Map.merge(%{confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second)}, attrs)
    )
    |> Repo.update!()
  end

  # The digest only sends when there is something to say. Seed one fresh
  # matching business so "quiet week = silence" (correct product behaviour)
  # does not make these tests indeterminate.
  defp seed_fresh_business! do
    d = "digest-probe.test"
    LS.Clickhouse.query_raw("INSERT INTO businesses (domain, first_seen, as_of, http_tech) VALUES ('#{d}', now(), now(), 'Shopify')")
    on_exit(fn -> LS.Clickhouse.query_raw("ALTER TABLE businesses DELETE WHERE domain = '#{d}'") end)
    :ok
  end

  defp searched!(email, filters, hours_ago) do
    Audit.record("search", %{email: email, metadata: %{filters: filters}})

    # Backdate: the wall trigger is "searched 18-48h ago".
    ts = DateTime.utc_now() |> DateTime.add(-hours_ago * 3600, :second)

    from(a in LS.Audit.Event, where: a.email == ^email, order_by: [desc: a.inserted_at], limit: 1)
    |> Repo.one!()
    |> Ecto.Changeset.change(inserted_at: DateTime.truncate(ts, :second))
    |> Repo.update!()
  end

  describe "welcome (sent on first confirmation)" do
    test "is plain text, from the founder, and asks the one question" do
      user = user!("new@example.com")
      assert :ok = Engagement.send_welcome(user)

      assert_email_sent(fn email ->
        assert email.subject == "What list are you trying to build?"
        assert {_, "will@listsignal.com"} = email.from
        assert email.text_body =~ "What list are you trying to build?"
        assert email.text_body =~ "I can build it with you"

        refute email.text_body =~ ~r/people come (here )?for/i,
               "the welcome must ASK what they want, not tell them what people want — " <>
                 "the whole point is discovering what paying customers actually need"
        assert email.html_body == nil, "plain text outperforms designed HTML; keep it plain"
      end)
    end
  end

  describe "the copy itself (it must not read like a machine wrote it)" do
    test "no em-dashes and no '--' separators in any customer-facing body" do
      user = %LS.Accounts.User{id: 0, email: "copy@example.com", digest_subscribed: true}
      filters = %{"tech" => "Shopify"}

      bodies = [
        Engagement.wall_body(1_847, filters),
        Engagement.digest_body(user, 1_240, filters, ["Klaviyo: 340 added it, 89 dropped it"])
      ]

      for body <- bodies do
        refute body =~ "\u2014", "em-dash reads as machine-written; the owner asked for none"
        refute body =~ "\u2013", "en-dash reads as machine-written"
        refute body =~ "\n--", "the '--' signature separator reads as machine-written"
      end
    end

    test "each body offers a way to talk to a human" do
      user = %LS.Accounts.User{id: 0, email: "copy@example.com", digest_subscribed: true}
      filters = %{"tech" => "Shopify"}

      assert Engagement.wall_body(10, filters) =~ "reply to this email"
      assert Engagement.digest_body(user, 10, filters, []) =~ "Reply and I can build it with you"
    end

    test "paragraphs are not hard-wrapped mid-sentence" do
      # Manual line breaks inside a paragraph render as stray returns in real
      # mail clients, which is what made these read like machine output.
      user = %LS.Accounts.User{id: 0, email: "copy@example.com", digest_subscribed: true}

      for body <- [
            Engagement.wall_body(1_847, %{"tech" => "Shopify"}),
            Engagement.digest_body(user, 1_240, %{"tech" => "Shopify"}, [])
          ] do
        for line <- String.split(body, "\n") do
          trimmed = String.trim(line)

          # A short line is fine (blank, link, sign-off). A long line that does
          # NOT end a sentence means the paragraph was broken by hand.
          if String.length(trimmed) in 40..90 and not String.contains?(trimmed, "http") do
            assert String.match?(trimmed, ~r/[.:?!]$/) or String.length(trimmed) > 90,
                   "line looks hand-wrapped mid-sentence: #{inspect(trimmed)}"
          end
        end
      end
    end
  end

  describe "the wall email" do
    test "goes to a free user who searched yesterday, quoting their search — once, ever" do
      user = user!("walled@example.com")
      searched!("walled@example.com", %{"tech" => "Shopify"}, 24)

      Engagement.send_wall_emails()

      assert_email_sent(fn email ->
        assert email.subject =~ "businesses"
        assert email.text_body =~ "(Shopify)", "the search must read back in words, not as a filter map"
        assert email.text_body =~ "25 rows"
      end)

      assert Repo.reload!(user).wall_email_sent_at != nil

      # Second run: silence. Once means once.
      Engagement.send_wall_emails()
      refute_email_sent()
    end

    test "never goes to paying users or to too-recent searches" do
      user!("payer@example.com", %{plan: "pro"})
      searched!("payer@example.com", %{"tech" => "Shopify"}, 24)

      user!("justnow@example.com")
      searched!("justnow@example.com", %{"tech" => "Shopify"}, 1)

      Engagement.send_wall_emails()
      refute_email_sent()
    end
  end

  describe "last_search/1 (the digest's anchor)" do
    test "returns the LAST search, not the first" do
      user!("searcher@example.com")
      searched!("searcher@example.com", %{"tech" => "Klaviyo"}, 30)
      searched!("searcher@example.com", %{"business_model" => "SaaS"}, 20)

      assert Engagement.last_search("searcher@example.com") == %{"business_model" => "SaaS"}
    end

    test "returns nil for users who never searched — no digest about nothing" do
      user!("idle@example.com")
      assert Engagement.last_search("idle@example.com") == nil
    end
  end

  describe "unsubscribe (the promise that matters most)" do
    test "the emailed token unsubscribes durably and is honoured by the sender" do
      user = user!("leaver@example.com")
      searched!("leaver@example.com", %{"tech" => "Shopify"}, 24)
      # With fresh data present, the refute below proves the OPT-OUT is what
      # silences the digest — not an accidentally quiet week.
      seed_fresh_business!()

      token = Engagement.unsubscribe_token(user)
      assert {:ok, _} = Engagement.unsubscribe(token)
      assert Repo.reload!(user).digest_subscribed == false

      # The digest run must now skip them entirely.
      Engagement.send_digests()
      refute_email_sent()

      # Idempotent: clicking an unsubscribe link twice must not error.
      assert {:ok, _} = Engagement.unsubscribe(token)
    end

    test "a garbage token fails closed without touching anyone" do
      assert {:error, :invalid} = Engagement.unsubscribe("not-a-token")
    end

    test "the digest body carries the unsubscribe link" do
      _user = user!("reader@example.com")
      searched!("reader@example.com", %{"tech" => "Shopify"}, 24)
      seed_fresh_business!()

      Engagement.send_digests()

      assert_email_sent(fn email ->
        assert email.text_body =~ "/digest/unsubscribe/"
        assert Enum.any?(email.headers, fn {k, _} -> k == "List-Unsubscribe" end),
               "one-click unsubscribe header is what keeps us out of spam folders"
      end)
    end
  end

  describe "digest cadence" do
    test "at most one per week, and the send is recorded" do
      user = user!("weekly@example.com")
      searched!("weekly@example.com", %{"tech" => "Shopify"}, 24)
      seed_fresh_business!()

      Engagement.send_digests()
      assert_email_sent()
      assert Repo.reload!(user).digest_last_sent_at != nil

      # Immediately again: capped.
      Engagement.send_digests()
      refute_email_sent()
    end
  end
end
