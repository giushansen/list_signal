defmodule LS.Audit do
  @moduledoc """
  Durable record of what each customer actually received.

  ## Why this exists

  A Stripe dispute can land up to 120 days after the charge, and the card
  network decides it on the evidence you can produce: that the account was
  used, that the data was delivered, from where, and when. Application logs
  cannot do that job — they rotate, and journald on these boxes keeps hours.

  So every event that represents *value delivered* is written here, in SQLite
  next to `users`: the one durable store in the system, backed up hourly and
  shipped offsite daily.

  ## What to record

  Only things you would want to show a card network or a customer:
  logins, searches, exports, CSV downloads. Not page views, not internal
  crawler activity — noise makes the evidence harder to read, and every row
  is personal data we then have to justify keeping.
  """

  import Ecto.Query, warn: false

  alias LS.Audit.Event
  alias LS.Repo

  @doc """
  Record one event. Never raises and never blocks the caller's happy path:
  losing an audit row must not cost a customer their download.

  `conn` supplies IP and user-agent when available.
  """
  @spec record(String.t(), map()) :: :ok
  def record(event, attrs \\ %{}) when is_binary(event) do
    case %Event{} |> Event.changeset(Map.put(attrs, :event, event)) |> Repo.insert() do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        require Logger
        Logger.warning("[Audit] discarded #{event}: #{inspect(changeset.errors)}")
        :ok
    end
  rescue
    # SQLite does not name its foreign-key constraints, so a user_id that is not a
    # real account can't be turned into a changeset error and raises here instead.
    # An audit row is never worth failing a request over — drop it with one line,
    # not the full multi-line Ecto hint.
    Ecto.ConstraintError ->
      require Logger
      Logger.warning("[Audit] discarded #{event}: references a user that does not exist")
      :ok

    e ->
      require Logger
      Logger.warning("[Audit] failed to record #{event}: #{Exception.message(e)}")
      :ok
  end

  @doc "Record an event with the requester's IP and user agent taken from `conn`."
  @spec record_from_conn(Plug.Conn.t(), String.t(), map()) :: :ok
  def record_from_conn(conn, event, attrs \\ %{}) do
    record(
      event,
      attrs
      |> Map.put(:ip, client_ip(conn))
      |> Map.put(:user_agent, header(conn, "user-agent"))
    )
  end

  @doc """
  Everything recorded for one email, oldest first — the answer to
  "prove this customer got what they paid for".
  """
  @spec history(String.t()) :: [Event.t()]
  def history(email) when is_binary(email) do
    Repo.all(from e in Event, where: e.email == ^email, order_by: [asc: e.inserted_at])
  end

  @doc "Events for one user id, oldest first."
  @spec history_for_user(binary()) :: [Event.t()]
  def history_for_user(user_id) do
    Repo.all(from e in Event, where: e.user_id == ^user_id, order_by: [asc: e.inserted_at])
  end

  # Behind Cloudflare the peer address is Cloudflare's, so prefer the header
  # it sets; fall back to the socket for direct hits.
  defp client_ip(conn) do
    case header(conn, "cf-connecting-ip") || header(conn, "x-forwarded-for") do
      nil -> conn.remote_ip |> :inet.ntoa() |> to_string()
      value -> value |> String.split(",") |> List.first() |> String.trim()
    end
  rescue
    _ -> nil
  end

  defp header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end
end
