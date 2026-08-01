defmodule LS.Repo.Migrations.CreateAuditAndCsvOrders do
  @moduledoc """
  Two tables that exist for one reason: proving, months later, that a customer
  received what they paid for.

  Log lines are not evidence — they rotate, and journald keeps hours on these
  boxes. A Stripe dispute arrives up to 120 days after the charge and is
  decided on what you can show: who logged in, what they searched, what they
  downloaded, when, and from where. Both tables live in SQLite alongside
  `users`, which is the only durable store here and is backed up hourly.
  """
  use Ecto.Migration

  def change do
    create table(:audit_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      # Denormalised on purpose: a deleted account must not erase the evidence
      # that its owner was served.
      add :email, :string
      add :event, :string, null: false
      # search terms, row counts, order token — whatever makes the event
      # meaningful to a human reading it back in a dispute.
      add :metadata, :map, default: %{}
      add :ip, :string
      add :user_agent, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:audit_events, [:user_id])
    create index(:audit_events, [:email])
    create index(:audit_events, [:event])
    create index(:audit_events, [:inserted_at])

    create table(:csv_orders, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # The buyer never sees a numeric id: the download URL carries this
      # unguessable token, so the link IS the credential.
      add :token, :string, null: false
      add :email, :string, null: false
      add :description, :string
      add :file_path, :string, null: false
      add :row_count, :integer
      add :amount_cents, :integer
      add :currency, :string, default: "usd"

      add :stripe_payment_link, :string
      add :stripe_session_id, :string
      add :paid_at, :utc_datetime

      # Per-buyer watermark. Recorded here so a leaked file can be traced back
      # to the exact order without keeping a copy of every file sold.
      add :watermark, :string
      add :canary_domains, :string

      add :download_count, :integer, default: 0
      add :first_downloaded_at, :utc_datetime
      add :last_downloaded_at, :utc_datetime
      add :last_download_ip, :string
      # A link that never expires is a link that leaks.
      add :expires_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:csv_orders, [:token])
    create index(:csv_orders, [:email])
    create index(:csv_orders, [:stripe_session_id])
  end
end
