defmodule LS.ApiKeys.ApiKey do
  @moduledoc "One API key. Only the SHA-256 hash is stored, never the key."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "api_keys" do
    belongs_to :user, LS.Accounts.User
    field :key_hash, :binary
    field :prefix, :string
    field :name, :string, default: "default"
    field :revoked_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  def changeset(key, attrs) do
    key
    |> cast(attrs, [:user_id, :key_hash, :prefix, :name])
    |> validate_required([:user_id, :key_hash, :prefix])
    |> validate_length(:name, max: 80)
    |> unique_constraint(:key_hash)
  end
end

defmodule LS.ApiKeys.ApiUsage do
  @moduledoc "Monthly call counter per key. Period is \"YYYY-MM\"."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "api_usage" do
    belongs_to :api_key, LS.ApiKeys.ApiKey
    field :period, :string
    field :calls, :integer, default: 0
    timestamps(type: :utc_datetime)
  end
end
