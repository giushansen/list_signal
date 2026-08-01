defmodule LS.CsvSales.Order do
  @moduledoc """
  One CSV sold to one buyer: what they bought, whether they paid, and every
  time they downloaded it.

  The download URL carries `token`, so **the link is the credential** — there
  is no login for a cold-outreach buyer, and asking one to create an account
  before receiving what they already paid for loses sales. That makes three
  properties load-bearing: the token must be unguessable, the link must
  expire, and every download must be recorded.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "csv_orders" do
    field :token, :string
    field :email, :string
    field :description, :string
    field :file_path, :string
    field :row_count, :integer
    field :amount_cents, :integer
    field :currency, :string, default: "usd"

    field :stripe_payment_link, :string
    field :stripe_session_id, :string
    field :paid_at, :utc_datetime

    field :watermark, :string
    field :canary_domains, :string

    field :download_count, :integer, default: 0
    field :first_downloaded_at, :utc_datetime
    field :last_downloaded_at, :utc_datetime
    field :last_download_ip, :string
    field :expires_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(order, attrs) do
    order
    |> cast(attrs, [
      :token, :email, :description, :file_path, :row_count, :amount_cents, :currency,
      :stripe_payment_link, :stripe_session_id, :paid_at, :watermark, :canary_domains,
      :download_count, :first_downloaded_at, :last_downloaded_at, :last_download_ip, :expires_at
    ])
    |> validate_required([:token, :email, :file_path])
    |> unique_constraint(:token)
  end

  @doc """
  Is this order downloadable right now?

  Unpaid or expired means no file — checked here rather than in the controller
  so there is exactly one definition of "may download".
  """
  @spec downloadable?(t()) :: boolean()
  def downloadable?(%__MODULE__{paid_at: nil}), do: false

  def downloadable?(%__MODULE__{expires_at: nil}), do: true

  def downloadable?(%__MODULE__{expires_at: expires_at}),
    do: DateTime.compare(DateTime.utc_now(), expires_at) == :lt
end
