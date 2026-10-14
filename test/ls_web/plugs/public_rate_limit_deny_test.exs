defmodule LSWeb.Plugs.PublicRateLimitDenyTest do
  # async: false, it sets an env var the plug reads.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias LSWeb.Plugs.PublicRateLimit

  @moduledoc """
  2026-10-14: two addresses took 1,074 rate-limit refusals in a day and
  kept coming (a Paris hosting box on "/", a Google Cloud box on the store
  pages). A 429 is advice; a denied address gets 403 before any read.
  """

  setup do
    System.put_env("LS_PUBLIC_DENY_IPS", "23.251.146.115, 185.177.72.17")
    on_exit(fn -> System.delete_env("LS_PUBLIC_DENY_IPS") end)
    :ok
  end

  test "a denied address is refused with 403 and halted; a neighbour is not" do
    conn = conn(:get, "/website/some-shop") |> put_req_header("cf-connecting-ip", "23.251.146.115") |> PublicRateLimit.call([])
    assert conn.status == 403
    assert conn.halted

    other = conn(:get, "/website/some-shop") |> put_req_header("cf-connecting-ip", "23.251.146.116") |> PublicRateLimit.call([])
    refute other.halted
  end

  test "the list is read from the env, trimmed, and absent means nobody is denied" do
    assert PublicRateLimit.denied?("185.177.72.17")
    refute PublicRateLimit.denied?("185.177.72.18")
    System.delete_env("LS_PUBLIC_DENY_IPS")
    refute PublicRateLimit.denied?("185.177.72.17")
  end

  test "the box's own loopback probe is never denied even if listed" do
    System.put_env("LS_PUBLIC_DENY_IPS", "127.0.0.1")
    conn = conn(:get, "/") |> PublicRateLimit.call([])
    refute conn.halted
  end
end
