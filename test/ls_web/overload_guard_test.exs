defmodule LSWeb.Plugs.OverloadGuardTest do
  @moduledoc """
  The guard's own failure modes matter more than its success case.

  v1 counted requests in flight and decremented in register_before_send. That
  decrement does not run when a request times out, so on 2026-08-19 a burst of
  timeouts leaked the counter past its ceiling and the site returned 503 to
  EVERY visitor until restarted — a transient spike turned into an indefinite
  outage by the very thing meant to prevent one.

  So the properties under test are: it must fail OPEN, it must be
  self-correcting, and it must not shed under normal memory.
  """
  use LSWeb.ConnCase, async: false

  alias LSWeb.Plugs.OverloadGuard

  @key {OverloadGuard, :memory_state}

  setup do
    saved = :persistent_term.get(@key, nil)
    on_exit(fn -> if saved, do: :persistent_term.put(@key, saved), else: :persistent_term.erase(@key) end)
    :ok
  end

  defp publish(bytes, limit, age_s \\ 0) do
    :persistent_term.put(@key, {bytes, limit, System.monotonic_time(:second) - age_s})
  end

  describe "failing open (the v1 catastrophe)" do
    test "no reading at all means serve, never shed" do
      :persistent_term.erase(@key)
      refute OverloadGuard.over_threshold?()
    end

    test "a stale reading means serve — a dead sampler must not take the site down" do
      # v1's equivalent state (a leaked counter) shed everything forever.
      publish(100 * 1024 * 1024 * 1024, 8 * 1024 * 1024 * 1024, 120)

      refute OverloadGuard.over_threshold?(),
             "a stale reading must fail open; monitoring failure must not become an outage"
    end

    test "a zero limit means serve" do
      publish(5_000_000_000, 0)
      refute OverloadGuard.over_threshold?()
    end
  end

  describe "self-correction (why memory, not a counter)" do
    test "shedding stops on its own once memory falls" do
      limit = 8 * 1024 * 1024 * 1024

      publish(round(limit * 0.95), limit)
      assert OverloadGuard.over_threshold?()

      # No reconciliation, no decrement, no bookkeeping: the next sample alone
      # ends the shedding. This is the property the counter version lacked.
      publish(round(limit * 0.30), limit)
      refute OverloadGuard.over_threshold?()
    end
  end

  describe "behaviour" do
    test "normal memory serves requests" do
      limit = 8 * 1024 * 1024 * 1024
      publish(round(limit * 0.28), limit)

      conn = get(build_conn(), "/pricing")
      assert conn.status == 200
    end

    test "over threshold sheds with 503 and retry-after" do
      limit = 8 * 1024 * 1024 * 1024
      publish(round(limit * 0.95), limit)

      conn = OverloadGuard.call(Map.put(build_conn(), :request_path, "/tech/klaviyo"), [])

      assert conn.status == 503
      assert conn.halted
      assert get_resp_header(conn, "retry-after") == ["2"]
    end

    test "assets and health are never shed" do
      limit = 8 * 1024 * 1024 * 1024
      publish(round(limit * 0.99), limit)

      for path <- ["/assets/app.css", "/health"] do
        conn = OverloadGuard.call(Map.put(build_conn(), :request_path, path), [])
        refute conn.halted, "#{path} must never be shed"
      end
    end

    test "the threshold leaves headroom above steady state" do
      # Steady state is ~2.2G of a 6G limit (~37%). Shedding at 80% means
      # normal traffic never sees a 503, but the 6.3G excursion that caused
      # the outage would be caught.
      assert OverloadGuard.shed_ratio() >= 0.7 and OverloadGuard.shed_ratio() <= 0.9
    end
  end
end
