# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# This is idempotent — safe to run multiple times.

alias LS.Repo
alias LS.Accounts.User

# Create a default admin/test user for development (pro plan via manual override)
unless Repo.get_by(User, email: "admin@listsignal.com") do
  %User{}
  |> Ecto.Changeset.change(%{
    email: "admin@listsignal.com",
    plan: "pro",
    stripe_subscription_id: "manual_override",
    confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second)
  })
  |> Repo.insert!()

  IO.puts("Created admin user: admin@listsignal.com (pro plan)")
end

# Create a free-tier test user
unless Repo.get_by(User, email: "free@listsignal.com") do
  %User{}
  |> Ecto.Changeset.change(%{
    email: "free@listsignal.com",
    plan: "free",
    confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second)
  })
  |> Repo.insert!()

  IO.puts("Created free user: free@listsignal.com (free plan)")
end
