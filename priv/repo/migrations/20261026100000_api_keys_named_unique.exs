defmodule LS.Repo.Migrations.ApiKeysNamedUnique do
  use Ecto.Migration

  # Multiple active keys per user (one per connector, revocable alone), with
  # the name unique among that user's ACTIVE keys. Partial index: a revoked
  # key frees its name, so "claude-sales" can be rotated by revoke + create.
  # The application pre-checks the name; this index is the guard against two
  # concurrent creates racing past that check.
  def change do
    create unique_index(:api_keys, [:user_id, :name], where: "revoked_at IS NULL")
  end
end
