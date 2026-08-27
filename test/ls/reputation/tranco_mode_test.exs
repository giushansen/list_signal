defmodule LS.Reputation.TrancoModeTest do
  use ExUnit.Case, async: false

  alias LS.Reputation.{Bloom, Tranco}

  @moduledoc """
  Tranco's two storage modes.

  Workers asked one question of a 402 MB ETS table on a 1,968 MB machine: is
  this domain ranked? That is the crawl bypass in LS.HTTP.DomainFilter, worth
  ~150K legitimate domains per 1.5 days, so it could not simply be dropped.
  Workers now hold a 4.9 MB bloom filter for exactly that question and the
  master fills the rank column.

  The regression these guard against: if `ranked?/1` ever falls back to
  `lookup/1` on a worker, the bypass silently stops firing and discovery
  narrows with nothing in the logs to show for it.
  """

  setup do
    on_exit(fn ->
      :persistent_term.erase({Tranco, :bloom})
      Application.delete_env(:ls, :tranco_mode)
    end)

    :ok
  end

  test "membership mode answers from the bloom filter, not from ETS" do
    bloom = Bloom.new(1_000, 0.01)
    Bloom.put(bloom, "stripe.com")
    :persistent_term.put({Tranco, :bloom}, bloom)

    assert Tranco.ranked?("stripe.com")
    refute Tranco.ranked?("definitely-not-ranked-anywhere.example")
  end

  test "www. and case are normalised the same way in both modes" do
    bloom = Bloom.new(1_000, 0.01)
    Bloom.put(bloom, "stripe.com")
    :persistent_term.put({Tranco, :bloom}, bloom)

    assert Tranco.ranked?("WWW.Stripe.COM")
    assert Tranco.ranked?("www.stripe.com")
  end

  test "lookup/1 returns nil in membership mode, so a worker never invents a rank" do
    :persistent_term.put({Tranco, :bloom}, Bloom.new(10, 0.01))
    if :ets.info(:tranco_ranks) != :undefined, do: :ets.delete_all_objects(:tranco_ranks)

    assert Tranco.lookup("stripe.com") == nil
  end

  test "with no bloom loaded it falls back to ETS, so the master is unaffected" do
    :persistent_term.erase({Tranco, :bloom})
    if :ets.info(:tranco_ranks) == :undefined, do: :ets.new(:tranco_ranks, [:named_table, :set, :public])
    :ets.insert(:tranco_ranks, {"stripe.com", 4_521})

    assert Tranco.ranked?("stripe.com")
    assert Tranco.lookup("stripe.com") == 4_521
  end

  test "a missing ETS table and a missing bloom are both survivable" do
    :persistent_term.erase({Tranco, :bloom})
    if :ets.info(:tranco_ranks) != :undefined, do: :ets.delete(:tranco_ranks)

    assert Tranco.lookup("stripe.com") == nil
    refute Tranco.ranked?("stripe.com")

    :ets.new(:tranco_ranks, [:named_table, :set, :public])
  end

  test "parse_line/1 keeps only well-formed CSV rows" do
    assert Tranco.parse_line("1,google.com") == {:ok, "google.com", 1}
    assert Tranco.parse_line("42,WWW.Stripe.com ") == {:ok, "stripe.com", 42}

    for bad <- ["", "google.com", "notanumber,google.com", "1,", ",", "1,   "] do
      assert Tranco.parse_line(bad) == :skip, "accepted malformed line: #{inspect(bad)}"
    end
  end

  test "membership mode is keyed on the role, so standalone keeps the ranks" do
    # "standalone" (dev and test) runs the master AND worker child lists in one
    # BEAM and does need rank values. Deciding this inside role_children(
    # "worker", _) switched local nodes to membership mode and broke three
    # domain-filter tests, which is how this was caught.
    source = File.read!("lib/ls/application.ex")

    assert source =~ ~s|if(role == "worker", do: :membership, else: :full)|,
           "the storage mode must depend on the role, not on the worker child list"

    worker_block =
      source
      |> String.split(~s|defp role_children("worker"|)
      |> Enum.at(1)
      |> String.split(~s|defp role_children("standalone"|)
      |> List.first()

    refute worker_block =~ ":tranco_mode",
           "setting the mode here also catches standalone, which needs the ranks"
  end

  test "the crawl bypass calls ranked?/1, not lookup/1" do
    src = File.read!("lib/ls/http/domain_filter.ex")
    assert src =~ "Tranco.ranked?("
    refute src =~ "Tranco.lookup(", "lookup/1 is always nil on a worker; the bypass would stop firing"
  end
end
