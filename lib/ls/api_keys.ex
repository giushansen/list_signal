defmodule LS.ApiKeys do
  @moduledoc """
  API keys, quotas, and usage tracking for the public `/api/v1` + `/mcp`
  surface.

  Design constraints, in order:

    * **The request path must stay cheap.** Auth is one indexed SQLite read
      (by key hash); the quota check reads one usage row; usage recording is
      fire-and-forget (`record_usage_async/1`), so a busy SQLite can never
      slow an API response or drop one.
    * **We never store a key.** Only its SHA-256. The plaintext appears once
      at creation; `prefix` exists so users can tell keys apart.
    * **Quotas are per plan, not per key** (a user's keys share the pool),
      monthly, calendar-based ("YYYY-MM"), so a reset is just a new period
      string, no cron.

  The free tier is deliberately real (1,000 lookups/month): agent
  directories and the public-apis list only accept products a bot can
  actually try, and a generous free tier is the discovery funnel for the
  paid API.
  """

  import Ecto.Query
  alias LS.Repo
  alias LS.ApiKeys.{ApiKey, ApiUsage}

  @monthly_quota %{"free" => 1_000, "starter" => 5_000, "pro" => 25_000}
  # Requests per minute, enforced in-memory per node (abuse guard, not billing).
  @rate_per_min %{"free" => 30, "starter" => 60, "pro" => 120}

  def monthly_quota(plan), do: Map.get(@monthly_quota, plan, @monthly_quota["free"])
  def rate_per_min(plan), do: Map.get(@rate_per_min, plan, @rate_per_min["free"])

  # ── Key lifecycle ─────────────────────────────────────────────────────────

  @doc """
  Create a key for a user. Returns `{:ok, plaintext, key}`: the plaintext
  is shown once and never stored. One active key per user keeps the UI and
  the quota model trivial; revoke-and-recreate is the rotation story.
  """
  def create_key(user, name \\ "default") do
    if active_key_for_user(user.id) do
      {:error, :already_has_key}
    else
      plaintext = "ls_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

      %ApiKey{}
      |> ApiKey.changeset(%{
        user_id: user.id,
        key_hash: :crypto.hash(:sha256, plaintext),
        prefix: String.slice(plaintext, 0, 11),
        name: name
      })
      |> Repo.insert()
      |> case do
        {:ok, key} -> {:ok, plaintext, key}
        err -> err
      end
    end
  end

  def revoke_key(%ApiKey{} = key) do
    key
    |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(:second))
    |> Repo.update()
  end

  def active_key_for_user(user_id) do
    Repo.one(
      from k in ApiKey,
        where: k.user_id == ^user_id and is_nil(k.revoked_at),
        limit: 1
    )
  end

  # ── Auth (the hot path) ───────────────────────────────────────────────────

  @doc """
  Resolve a bearer token to `{:ok, key, user}` or an error atom. One read
  on the unique hash index, plus the user (for the plan).
  """
  def authenticate(plaintext) when is_binary(plaintext) do
    hash = :crypto.hash(:sha256, plaintext)

    case Repo.one(from k in ApiKey, where: k.key_hash == ^hash, preload: [:user]) do
      nil -> {:error, :invalid_key}
      %ApiKey{revoked_at: %DateTime{}} -> {:error, :revoked}
      %ApiKey{} = key -> {:ok, key, key.user}
    end
  end

  def authenticate(_), do: {:error, :invalid_key}

  # ── Quota ─────────────────────────────────────────────────────────────────

  def current_period, do: Calendar.strftime(Date.utc_today(), "%Y-%m")

  def usage_this_month(key_id) do
    Repo.one(
      from u in ApiUsage,
        where: u.api_key_id == ^key_id and u.period == ^current_period(),
        select: u.calls
    ) || 0
  end

  @doc "true when the key's plan has monthly calls left."
  def within_quota?(key, plan), do: usage_this_month(key.id) < monthly_quota(plan)

  @doc """
  Record one successful call, off the request path. A lost increment under
  crash is acceptable (we lose a fraction of a cent of accounting, the
  customer loses nothing); a slow write blocking a response is not.
  """
  def record_usage_async(key_id) do
    Task.Supervisor.start_child(LS.TaskSupervisor, fn -> record_usage(key_id) end)
  end

  @doc false
  def record_usage(key_id) do
    %ApiUsage{}
    |> Ecto.Changeset.change(api_key_id: key_id, period: current_period(), calls: 1)
    |> Repo.insert(
      on_conflict: [inc: [calls: 1], set: [updated_at: DateTime.utc_now(:second)]],
      conflict_target: [:api_key_id, :period]
    )
  end
end
