defmodule LS.Repo.Migrations.ApiKeysEncrypted do
  use Ecto.Migration

  # Reversible copy of the key so Settings can show it again. The SHA-256
  # hash stays the auth path and the unique index; this column is only read
  # by the owner's Settings page. Nullable: keys created before this column
  # have no plaintext on record and show as "rotate to see".
  def change do
    alter table(:api_keys) do
      add :encrypted_key, :binary
    end
  end
end
