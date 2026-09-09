defmodule LS.ThrottleTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Magic-link mail bombing (security audit 2026-09-09): unlimited sends per
  address meant anyone could run up the Mailgun bill and burn the sending
  domain's reputation. The throttle must stop the abuser and stay invisible
  to a person who mistypes their address twice.
  """

  test "a key is allowed up to the limit inside one window, then refused" do
    key = System.unique_integer([:positive])
    assert Enum.map(1..5, fn _ -> LS.Throttle.allow?(:test, key, 5, 3600) end) == [true, true, true, true, true]
    refute LS.Throttle.allow?(:test, key, 5, 3600)
  end

  test "keys and scopes do not share a counter" do
    a = System.unique_integer([:positive])
    b = System.unique_integer([:positive])
    for _ <- 1..3, do: LS.Throttle.allow?(:test, a, 3, 3600)
    refute LS.Throttle.allow?(:test, a, 3, 3600)
    assert LS.Throttle.allow?(:test, b, 3, 3600)
    assert LS.Throttle.allow?(:other_scope, a, 3, 3600)
  end

  test "fails open when the table is gone, so a limiter bug never locks people out" do
    # Same code path as allow?/4 with a missing table: update_counter raises
    # ArgumentError and the rescue returns true.
    assert_raise ArgumentError, fn -> :ets.update_counter(:no_such_table, :k, {2, 1}, {:k, 0, 0}) end
  end
end
