defmodule LS.FeedbackTest do
  @moduledoc """
  A customer flag becomes an immediate operator email AND an audit row that
  survives the mailbox. Invariants: the email carries the four fields the owner
  asked for (datetime, customer, domain, reason), the audit captures domain +
  reporter + reason, an empty reason still sends, hostile input can't inject
  into the email, and nothing can crash the LiveView that called it.
  """
  use LS.DataCase, async: false

  alias LS.{Audit, Feedback}

  @at ~U[2026-08-24 09:30:00Z]

  describe "flag_html/4 — the email body (pure)" do
    test "carries datetime, customer, domain and the reason" do
      html = Feedback.flag_html("acme.com", "buyer@corp.com", "revenue looks way off", @at)
      assert html =~ "2026-08-24 09:30:00 UTC"
      assert html =~ "buyer@corp.com"
      assert html =~ "acme.com"
      assert html =~ "revenue looks way off"
      assert html =~ "flagged a domain"
    end

    test "an empty reason still produces a complete report" do
      html = Feedback.flag_html("acme.com", "buyer@corp.com", "", @at)
      assert html =~ "none given"
      assert html =~ "acme.com" and html =~ "buyer@corp.com" and html =~ "2026-08-24 09:30:00 UTC"
    end

    test "hostile input is HTML-escaped (no injection into the email)" do
      html = Feedback.flag_html("<b>x</b>.com", "a@b.com", "<script>alert(1)</script>", @at)
      refute html =~ "<script>alert(1)</script>"
      refute html =~ "<b>x</b>.com"
      assert html =~ "&lt;script&gt;"
    end
  end

  describe "report/3 — audit + immediate send" do
    test "a report with text is audited with domain and reporter" do
      assert :ok = Feedback.report("gymshark.com", "customer@example.com", "Wrong country shown")
      [event] = Audit.history("customer@example.com")
      assert event.event == "feedback"
      assert event.metadata["domain"] == "gymshark.com"
      assert event.metadata["text"] == "Wrong country shown"
      assert event.metadata["flagged_at"] =~ ~r/^\d{4}-\d{2}-\d{2}T/
    end

    test "an empty report still carries the facts that matter" do
      assert :ok = Feedback.report("acme.io", "silent@example.com", "")
      [event] = Audit.history("silent@example.com")
      assert event.metadata["domain"] == "acme.io"
      assert event.metadata["text"] == ""
    end

    test "nil text and oversized text never raise; text is truncated not rejected" do
      assert :ok = Feedback.report("a.com", "x@example.com", nil)
      assert :ok = Feedback.report("b.com", "x@example.com", String.duplicate("y", 50_000))
      events = Audit.history("x@example.com")
      assert length(events) == 2
      assert String.length(Enum.at(events, 1).metadata["text"]) == 2000
    end
  end
end
