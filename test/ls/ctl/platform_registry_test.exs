defmodule LS.CTL.PlatformRegistryTest do
  @moduledoc """
  The registry's job is to make platform detection permanent *without* ever
  mislabelling a real business. Both halves are tested here: a sustained
  platform gets promoted, a one-off spike does not.
  """
  use ExUnit.Case, async: false

  alias LS.CTL.PlatformRegistry

  setup do
    # The GenServer owns the tables; if it is not running (unit context), make
    # them ourselves so the pure logic is still exercised.
    for t <- [:platform_registry, :platform_pending] do
      if :ets.whereis(t) == :undefined do
        :ets.new(t, [:set, :public, :named_table])
      else
        :ets.delete_all_objects(t)
      end
    end

    :ok
  end

  describe "grace window" do
    test "a single detection does NOT promote — a startup can spike briefly" do
      PlatformRegistry.observe("fast-growing-startup.com", %{cert_count: 30})
      refute PlatformRegistry.known?("fast-growing-startup.com")
    end

    test "a sustained detection promotes on the second cycle" do
      PlatformRegistry.observe("myshopify.com", %{cert_count: 5000})
      refute PlatformRegistry.known?("myshopify.com")

      PlatformRegistry.observe("myshopify.com", %{cert_count: 9000})
      assert PlatformRegistry.known?("myshopify.com")
    end

    test "further detections keep it known and do not error" do
      for _ <- 1..5, do: PlatformRegistry.observe("squarespace.com", %{cert_count: 1})
      assert PlatformRegistry.known?("squarespace.com")
    end
  end

  describe "known?/1" do
    test "unknown domains are not platforms" do
      refute PlatformRegistry.known?("acme.com")
    end

    test "tolerates non-binary input rather than raising in the CT hot path" do
      refute PlatformRegistry.known?(nil)
      refute PlatformRegistry.known?(123)
    end
  end

  describe "count/0" do
    test "reflects promoted platforms only" do
      assert PlatformRegistry.count() == 0
      PlatformRegistry.observe("netlify.app", %{})
      assert PlatformRegistry.count() == 0
      PlatformRegistry.observe("netlify.app", %{})
      assert PlatformRegistry.count() == 1
    end
  end
end
