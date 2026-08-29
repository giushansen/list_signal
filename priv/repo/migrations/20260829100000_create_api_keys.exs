defmodule LS.Repo.Migrations.CreateApiKeys do
  use Ecto.Migration

  def change do
    create table(:api_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      # Only the SHA-256 of the key is stored; the plaintext is shown once at
      # creation. `prefix` (first 11 chars, "ls_" + 8) is kept for display so
      # the user can tell keys apart without us holding the secret.
      add :key_hash, :binary, null: false
      add :prefix, :string, null: false
      add :name, :string, null: false, default: "default"
      add :revoked_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:api_keys, [:key_hash])
    create index(:api_keys, [:user_id])

    # One row per key per calendar month; the quota check reads one row and
    # the async tracker upserts it. Period is "YYYY-MM" so resets are free.
    create table(:api_usage, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :api_key_id, references(:api_keys, type: :binary_id, on_delete: :delete_all), null: false
      add :period, :string, null: false
      add :calls, :integer, null: false, default: 0
      timestamps(type: :utc_datetime)
    end

    create unique_index(:api_usage, [:api_key_id, :period])
  end
end
