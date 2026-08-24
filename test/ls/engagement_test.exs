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
        assert email.text_body =~ "Tell me the kind of company you're after"
        assert email.text_body =~ "put the list together with you"

        refute email.text_body =~ ~r/people come (here )?for/i,
               "the welcome must ASK what they want, not tell them what people want — " <>
                 "the whole point is discovering what paying customers actually need"
        # HTML exists only to hide long URLs behind words. It must still read
        # as a personal note: no images, no layout tables, no branded header.
        assert email.html_body =~ "<p", "the HTML twin should be paragraphs"
        refute email.html_body =~ "<img", "a founder's note has no images"
        refute email.html_body =~ "<table", "a founder's note is not a layout table"
        # The welcome deliberately has no link: its only call to action is a
        # reply, so the reply-to address is the thing that must be right.
        assert email.text_body =~ "Just reply with what you need."
        assert email.reply_to == {"", "will@listsignal.com"}
      end)
    end
  end

  describe "the search description (it must never misrepresent the search)" do
    test "multi-value filters keep their real AND/OR meaning" do
      # country IN (...) is OR; tech is AND (every one must be present).
      # Saying "or" where the query means "and" promises a list we did not build.
      or_body = Engagement.wall_body(1, %{"country" => "FR,GB,US"})
      assert or_body =~ "France, United Kingdom or United States"

      and_body = Engagement.wall_body(1, %{"tech" => "Klaviyo,Gorgias"})
      assert and_body =~ "Klaviyo and Gorgias"
    end

    test "an unknown filter is described, never silently dropped" do
      # 2026-08-24: the dashboard gained a "discovered" filter, the describer
      # did not know it, and emails quoted a NARROWER search than the customer
      # ran. Ugly beats wrong.
      body = Engagement.wall_body(1, %{"brand_new_filter" => "42"})
      assert body =~ "brand new filter: 42"
    end

    test "every filter the dashboard can produce has a phrasing" do
      # Guards against the same drift: if the explorer gains a filter and this
      # list is not updated, the fallback shows a raw key in a customer email.
      known =
        ~w(business_model tech shopify_app industry country language revenue employees
           domain_search has_email has_pricing has_catalog hiring exclude_junk
           min_products max_products min_price_avg max_price_avg min_seo_score
           max_seo_score min_job_count min_new_products_30d ats_platform
           discovered freshness)

      for key <- known do
        described = Engagement.wall_body(1, %{key => sample_value(key)})

        refute described =~ "#{String.replace(key, "_", " ")}:",
               "#{key} fell through to the raw-key fallback; give it a phrasing"
      end
    end
  end

  defp sample_value("discovered"), do: "24h"
  defp sample_value("freshness"), do: "7d"
  defp sample_value("country"), do: "FR"
  defp sample_value("revenue"), do: "<$1M"
  defp sample_value(k) do
    cond do
      String.starts_with?(k, "has_") or k in ~w(hiring exclude_junk) -> "true"
      String.starts_with?(k, "min_") or String.starts_with?(k, "max_") -> "10"
      true -> "Shopify"
    end
  end

  describe "links are words, not tracking URLs" do
    test "every HTML body hides its ref-tagged URL behind clickable text" do
      user = %LS.Accounts.User{id: 0, email: "copy@example.com", digest_subscribed: true}

      wall = Engagement.wall_html_body(23_424, %{"tech" => "WordPress"})
      digest = Engagement.digest_html_body(user, 1_240, %{"tech" => "WordPress"}, nil)

      for {body, label} <- [{wall, "See export plans"}, {digest, "Get the full list"}] do
        assert body =~ ~s(>#{label}<), "the CTA must be a clickable phrase"

        # The ref code belongs in href, never in the visible text.
        visible = String.replace(body, ~r/<[^>]+>/, "")
        refute visible =~ "ref=", "customers must not see our attribution plumbing"
        refute visible =~ "https://", "no raw URLs in the rendered HTML"
      end
    end
  end

  describe "the copy itself (it must not read like a machine wrote it)" do
    test "no em-dashes and no '--' separators in any customer-facing body" do
      user = %LS.Accounts.User{id: 0, email: "copy@example.com", digest_subscribed: true}
      filters = %{"tech" => "Shopify"}

      bodies = [
        Engagement.wall_body(1_847, filters),
        Engagement.digest_body(user, 1_240, filters, %{tech: "Klaviyo", added: 340, removed: 89})
      ]

      for body <- bodies do
        # The owner has flagged em-dashes twice as the thing that makes copy
        # read machine-written. They are banned from anything a customer sees;
        # code comments are free to use them.
        refute body =~ "\u2014", "em-dash in customer copy"
        refute body =~ "\u2013", "en-dash in customer copy"
        refute body =~ "\n--", "the '--' signature separator reads as machine-written"
      end
    end

    test "each body offers a way to talk to a human" do
      user = %LS.Accounts.User{id: 0, email: "copy@example.com", digest_subscribed: true}
      filters = %{"tech" => "Shopify"}

      assert Engagement.wall_body(10, filters) =~ "reply and I'll send the first 25 rows free"
      assert Engagement.digest_body(user, 10, filters, nil) =~ "reply and I'll send the first 25 rows free"
    end

    test "paragraphs are not hard-wrapped mid-sentence" do
      # Manual breaks inside a paragraph render as stray returns in real mail
      # clients, which is what made these read like machine output. The tell
      # is a line that stops mid-sentence and continues in lower case on the
      # next one; a bullet or sign-off ends cleanly and must not be flagged.
      user = %LS.Accounts.User{id: 0, email: "copy@example.com", digest_subscribed: true}

      bodies = [
        Engagement.welcome_body(5_200),
        Engagement.wall_body(1_847, %{"tech" => "Shopify"}),
        Engagement.digest_body(user, 1_240, %{"tech" => "Shopify"}, nil)
      ]

      for body <- bodies do
        lines = body |> String.split("\n") |> Enum.map(&String.trim/1)

        lines
        |> Enum.zip(tl(lines) ++ [""])
        |> Enum.each(fn {line, next} ->
          continues? = next != "" and String.match?(next, ~r/^[a-z]/)

          refute line != "" and not String.match?(line, ~r/[.:?!]$/) and continues?,
                 "line looks hand-wrapped mid-sentence: #{inspect(line)} -> #{inspect(next)}"
        end)
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
        assert email.text_body =~ "ref=email-unlock-export", "the digest's CTA must be attributable in Umami"
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
