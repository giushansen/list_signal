defmodule LS.Repo.Migrations.AddEngagementFields do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # Opt-out is a durable fact about the user, not a mailing-list detail:
      # honouring it survives provider switches, exports, and rebuilds.
      add :digest_subscribed, :boolean, default: true, null: false
      # 1-email-per-week cap for the digest.
      add :digest_last_sent_at, :utc_datetime
      # The "you hit the export wall" email goes out once, ever.
      add :wall_email_sent_at, :utc_datetime
    end
  end
end
