defmodule LS.CacheWarmerTest do
  use ExUnit.Case, async: false

  @moduledoc """
  The warmer's start timing, which is what closes the post-deploy cold window.

  2026-08-24: /top/fashion returned 503 after 25s on a deploy because the
  warmer waits 90s for boot to finish before it starts. With LS.CacheSnapshot
  restoring the cache, that wait is wasted — the pass is a walk over keys that
  are already present. So the warmer checks early and only pays the full boot
  delay when it genuinely has cold work to do.
  """

  setup do
    :persistent_term.erase({LS.CacheSnapshot, :restored})
    Application.put_env(:ls, :warm_start_delay_ms, 300)
    Application.put_env(:ls, :warm_early_check_ms, 50)

    on_exit(fn ->
      :persistent_term.erase({LS.CacheSnapshot, :restored})
      Application.delete_env(:ls, :warm_start_delay_ms)
      Application.delete_env(:ls, :warm_early_check_ms)
    end)

    :ok
  end

  test "restored_count defaults to 0 when no snapshot ran, so a cold boot is the default" do
    assert LS.CacheSnapshot.restored_count() == 0
  end

  test "a restored cache makes the warmer warm immediately instead of waiting out the boot delay" do
    :persistent_term.put({LS.CacheSnapshot, :restored}, 412)

    {:noreply, _} = LS.CacheWarmer.handle_info(:maybe_warm_early, %{})

    assert_received :warm, "a warm cache must not sit idle for the full boot delay"
  end

  test "a cold cache defers rather than competing with a booting app" do
    :persistent_term.put({LS.CacheSnapshot, :restored}, 0)

    {:noreply, _} = LS.CacheWarmer.handle_info(:maybe_warm_early, %{})

    refute_received :warm, "cold warming must not start while the app is still booting"
    # It is scheduled, not dropped.
    assert_receive :warm, 2_000
  end
end
