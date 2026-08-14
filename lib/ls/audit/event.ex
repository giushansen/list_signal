defmodule LS.Audit.Event do
  @moduledoc """
  One recorded delivery of value: a login, a search, an export, a download.

  `email` is denormalised alongside `user_id` on purpose — a deleted account
  must not erase the proof that its owner was served, which is exactly the
  case a dispute tends to involve.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "audit_events" do
    field :email, :string
    field :event, :string
    field :metadata, :map, default: %{}
    field :ip, :string
    field :user_agent, :string
    field :user_id, :binary_id

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:user_id, :email, :event, :metadata, :ip, :user_agent])
    |> validate_required([:event])
    # A user_id that isn't a real account (e.g. deleted mid-request) must surface
    # as a changeset error, not a raised Ecto.ConstraintError — the email is kept
    # denormalised precisely so the row is still worth writing without it.
    |> foreign_key_constraint(:user_id)
    # A pathological user agent should never be the reason an audit row is lost.
    |> update_change(:user_agent, &truncate(&1, 500))
    |> update_change(:ip, &truncate(&1, 100))
  end

  defp truncate(nil, _), do: nil
  defp truncate(value, max) when is_binary(value), do: String.slice(value, 0, max)
  defp truncate(value, _), do: value
end
