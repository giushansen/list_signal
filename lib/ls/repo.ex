defmodule LS.Repo do
  use Ecto.Repo,
    otp_app: :ls,
    adapter: Ecto.Adapters.SQLite3
end
