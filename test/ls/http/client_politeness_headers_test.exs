defmodule LS.HTTP.ClientPolitenessHeadersTest do
  @moduledoc """
  2026-11-03: the client sends the validators of the last read so an
  unchanged page costs a 304, and reads Retry-After so a refusal sets the
  pause. Pure parts of LS.HTTP.Client, tested without a socket.
  """
  use ExUnit.Case, async: true

  alias LS.HTTP.Client

  test "validators become If-None-Match and If-Modified-Since, empty ones are dropped" do
    assert Client.conditional_headers({"\"abc\"", "Mon, 02 Nov 2026 07:02:00 GMT"}) ==
             [{"if-none-match", "\"abc\""}, {"if-modified-since", "Mon, 02 Nov 2026 07:02:00 GMT"}]

    assert Client.conditional_headers({"", "Mon, 02 Nov 2026 07:02:00 GMT"}) == [{"if-modified-since", "Mon, 02 Nov 2026 07:02:00 GMT"}]
    assert Client.conditional_headers({"\"abc\"", ""}) == [{"if-none-match", "\"abc\""}]
    assert Client.conditional_headers({"", ""}) == []
    assert Client.conditional_headers(nil) == []
    assert Client.conditional_headers({nil, nil}) == []
  end

  test "Retry-After in seconds is read; a date, garbage or a negative is nil" do
    assert Client.retry_after_ms([{"retry-after", "30"}]) == 30_000
    assert Client.retry_after_ms([{"content-type", "text/html"}, {"retry-after", " 7 "}]) == 7_000
    assert Client.retry_after_ms([{"retry-after", "Wed, 21 Oct 2026 07:28:00 GMT"}]) == nil
    assert Client.retry_after_ms([{"retry-after", "-5"}]) == nil
    assert Client.retry_after_ms([{"retry-after", ""}]) == nil
    assert Client.retry_after_ms([]) == nil
    assert Client.retry_after_ms(nil) == nil
  end

  test "a redirect hop takes a budget slot: the client asks the node budget before following" do
    src = File.read!("lib/ls/http/client.ex")
    assert src =~ ":ok <- hop_slot()"
    assert src =~ "NodeBudget.count(:hop)"
  end

  test "a pause is checked before a budget slot is taken, and a long one is a refusal, not a sleep" do
    # 2026-11-03, 30 min into the ny1 trial: a 503 with Retry-After 249 paused
    # a key and the next task slept 249 s on it after taking a slot.
    src = File.read!("lib/ls/http/client.ex")
    assert src =~ "@max_pause_sleep_ms 10_000"
    [before_budget, _] = String.split(src, "case LS.HTTP.NodeBudget.take(LS.HTTP.NodeBudget.lane_limit(lane), lane) do", parts: 2)
    assert before_budget =~ "case IPRateLimiter.penalty_wait(ip) do"
    assert src =~ "when retries_left > 0 and wait_ms <= horizon"
  end

  test "a 429, a 430 and a 503 pause the key" do
    src = File.read!("lib/ls/http/client.ex")
    assert src =~ "if response.status in [429, 430, 503], do: IPRateLimiter.penalize(ip, retry_after_ms(response.headers))"
  end
end
