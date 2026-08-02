defmodule LS.FeedbackTest do
  @moduledoc """
  Feedback exists so the owner can contact the customer about a record. The
  invariants: domain and reporter always captured, empty text still sends,
  and nothing about it can crash the LiveView that called it.
  """
  use LS.DataCase, async: false

  alias LS.{Audit, Feedback}

  test "a report with text is audited with domain and reporter" do
    assert :ok = Feedback.report("gymshark.com", "customer@example.com", "Wrong country shown")

    [event] = Audit.history("customer@example.com")
    assert event.event == "feedback"
    assert event.metadata["domain"] == "gymshark.com"
    assert event.metadata["text"] == "Wrong country shown"
  end

  test "an empty report still carries the two facts that matter" do
    # No text is fine: domain + reporter is already enough to follow up.
    assert :ok = Feedback.report("acme.io", "silent@example.com", "")

    [event] = Audit.history("silent@example.com")
    assert event.metadata["domain"] == "acme.io"
    assert event.metadata["text"] == ""
  end

  test "nil text and oversized text never raise" do
    assert :ok = Feedback.report("a.com", "x@example.com", nil)
    assert :ok = Feedback.report("b.com", "x@example.com", String.duplicate("y", 50_000))

    events = Audit.history("x@example.com")
    assert length(events) == 2
    # Truncated, not rejected: a long rant is still a report.
    assert String.length(Enum.at(events, 1).metadata["text"]) == 2000
  end
end
