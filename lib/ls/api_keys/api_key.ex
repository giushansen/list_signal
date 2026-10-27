defmodule LS.ApiKeys.ApiKey do
  @moduledoc "One API key. Only the SHA-256 hash is stored, never the key."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "api_keys" do
    belongs_to :user, LS.Accounts.User
    field :key_hash, :binary
    # Reversible copy, see LS.ApiKeys.Vault. nil for keys created before
    # 2026-10-26; Settings shows those as "rotate to see".
    field :encrypted_key, :binary
    field :prefix, :string
    field :name, :string, default: "default"
    field :revoked_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  def changeset(key, attrs) do
    key
    |> cast(attrs, [:user_id, :key_hash, :encrypted_key, :prefix, :name])
    |> validate_required([:user_id, :key_hash, :prefix, :name])
    |> validate_length(:name, min: 1, max: 80)
    # Names are labels a user types; control characters would corrupt the
    # Settings list and the audit rows that carry the key prefix beside them.
    |> validate_format(:name, ~r/^[^\x00-\x1F\x7F]+$/, message: "contains control characters")
    |> unique_constraint(:key_hash)
    |> unique_constraint([:user_id, :name], message: "an active key with this name already exists")
  end
end

defmodule LS.ApiKeys.ApiUsage do
  @moduledoc """
  Monthly counter per key. Period is "YYYY-MM". `calls` is how many
  successful calls, `rows` how many rows they delivered (2026-10-27, the
  metered unit); `rows` is nil on months written before rows existed, and
  the quota then reads the call count in its place.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "api_usage" do
    belongs_to :api_key, LS.ApiKeys.ApiKey
    field :period, :string
    field :calls, :integer, default: 0
    field :rows, :integer
    timestamps(type: :utc_datetime)
  end
end
