defmodule LS.Repo.Migrations.AddSubscriptionStatusToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :subscription_status, :string
      add :current_period_end, :utc_datetime
    end
  end
end
