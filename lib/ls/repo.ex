defmodule LS.Repo do
  @moduledoc """
  Ecto repo over SQLite. Holds the only critical durable state: users, plans
  and Stripe subscriptions. Analytics data lives in ClickHouse (`LS.Clickhouse`), not here.
  """
  use Ecto.Repo,
    otp_app: :ls,
    adapter: Ecto.Adapters.SQLite3
end
