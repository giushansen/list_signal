defmodule LS.Plans do
  @moduledoc """
  The one place plan numbers live (2026-10-27).

  Before this module the same plan was described in seven places with
  three different units: the pricing page sold CSV rows a month, the API
  metered calls (25,000 calls of 100 rows is 2.5M rows for the same $149),
  the dashboard throttled searches a minute, and the Settings page, the
  upgrade modal, the terms and llms.txt each carried their own copy of the
  numbers, two of them already stale ($39, $29, 500 rows). One table, one
  unit:

    * **Rows a month, any surface.** A row that leaves the product counts
      once, whether it left as a CSV line, an API search hit, an MCP tool
      result or a `/company` record. Browsing the dashboard is free; a row
      on screen is not a row in their CRM.
    * **Rows a page** is the per-call cap and the dashboard page size.
    * **Searches a minute** is one number for the dashboard and the API.
    * Counts, group-bys and dataset stats are free on every plan: sensing
      the data before pulling it is what makes an agent efficient.

  Done for you ("dfy") is Scale plus a person: the same limits, with the
  owner building lists by hand on request. It maps to a Stripe price like
  the others so the webhook can set it.
  """

  @plans [
    {"free",
     %{
       name: "Free",
       monthly: 0,
       yearly: 0,
       rows: 1_000,
       per_page: 15,
       per_min: 10,
       emails: false,
       feed: false,
       seats: 1,
       file_cap: 1_000
     }},
    {"starter",
     %{
       name: "Starter",
       monthly: 49,
       yearly: 490,
       rows: 2_500,
       per_page: 50,
       per_min: 30,
       emails: true,
       feed: false,
       seats: 1,
       file_cap: 2_500
     }},
    {"pro",
     %{
       name: "Pro",
       monthly: 149,
       yearly: 1_490,
       rows: 15_000,
       per_page: 100,
       per_min: 120,
       emails: true,
       feed: true,
       seats: 1,
       file_cap: 15_000
     }},
    {"scale",
     %{
       name: "Scale",
       monthly: 399,
       yearly: 3_990,
       rows: 75_000,
       per_page: 100,
       per_min: 300,
       emails: true,
       feed: true,
       seats: 3,
       file_cap: 25_000
     }},
    {"dfy",
     %{
       name: "Done for you",
       monthly: 999,
       yearly: nil,
       rows: 75_000,
       per_page: 100,
       per_min: 300,
       emails: true,
       feed: true,
       seats: 3,
       file_cap: 25_000
     }}
  ]

  @by_name Map.new(@plans)
  @names Enum.map(@plans, &elem(&1, 0))

  # The rows an analysis read (`/api/v1/query`, the MCP query tool) may
  # return in one call. Paid plans get a wider page there than in search,
  # because the point of the tool is a table, not a list.
  @query_max %{"free" => 15, "starter" => 50, "pro" => 500, "scale" => 500, "dfy" => 500}

  @doc "Every plan name, cheapest first."
  @spec names() :: [String.t()]
  def names, do: @names

  @doc "The plans a Stripe subscription can set."
  @spec paid_plans() :: [String.t()]
  def paid_plans, do: @names -- ["free"]

  @doc "The self-serve plans the pricing page shows as columns."
  @spec self_serve() :: [String.t()]
  def self_serve, do: ~w(free starter pro scale)

  @doc "A plan's table row; an unknown name reads as free, never as more."
  @spec get(String.t() | nil) :: map()
  def get(plan), do: Map.get(@by_name, plan, @by_name["free"])

  def rows(plan), do: get(plan).rows
  def per_page(plan), do: get(plan).per_page
  def per_min(plan), do: get(plan).per_min
  def emails?(plan), do: get(plan).emails
  def feed?(plan), do: get(plan).feed
  def seats(plan), do: get(plan).seats
  def label(plan), do: get(plan).name
  def monthly(plan), do: get(plan).monthly
  def yearly(plan), do: get(plan).yearly

  @doc "Rows in ONE CSV file. Past this a file is a database dump, not a list."
  def file_cap(plan), do: get(plan).file_cap

  @doc "Rows one analysis read may return."
  def query_max(plan), do: Map.get(@query_max, plan, @query_max["free"])

  @doc "The monthly-equivalent price when billed yearly, or nil when there is no yearly price."
  def yearly_per_month(plan) do
    case yearly(plan) do
      nil -> nil
      y -> div(y, 12)
    end
  end

  def paid?(plan), do: plan in paid_plans()

  @doc "Thousands-separated number, the way every plan card prints it."
  @spec fmt(integer()) :: String.t()
  def fmt(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
