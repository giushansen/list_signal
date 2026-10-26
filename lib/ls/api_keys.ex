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
    * **Quotas are per user, not per key.** A user may hold several active
      keys (one per connector: Claude Code, claude.ai, a CRM), each named
      and revocable alone, but they all draw from one monthly pool sized by
      the plan. Without that, N free keys would mean N times the free
      quota. Monthly, calendar-based ("YYYY-MM"), so a reset is just a new
      period string, no cron.
    * **The per-minute rate limit stays per key.** It is an abuse guard on a
      single client's burst, not billing, so one runaway connector cannot
      lock the user's other keys out.
    * **Names are unique among a user's active keys** (partial unique index
      in migration 20261026100000). Revoking frees the name, so rotation is
      revoke + create under the same label.

  The free tier is deliberately real (1,000 lookups/month, no contact
  emails): agent directories and the public-apis list only accept products
  a bot can actually try, and a generous free tier is the discovery funnel
  for the paid API.
  """

  import Ecto.Query
  alias LS.Repo
  alias LS.ApiKeys.{ApiKey, ApiUsage, Vault}

  @monthly_quota %{"free" => 1_000, "starter" => 5_000, "pro" => 25_000}
  # Requests per minute, enforced in-memory per node (abuse guard, not billing).
  @rate_per_min %{"free" => 30, "starter" => 60, "pro" => 120}

  def monthly_quota(plan), do: Map.get(@monthly_quota, plan, @monthly_quota["free"])
  def rate_per_min(plan), do: Map.get(@rate_per_min, plan, @rate_per_min["free"])

  # ── Key lifecycle ─────────────────────────────────────────────────────────

  @doc """
  Create a named key for a user. Returns `{:ok, plaintext, key}`: the
  plaintext is shown once and never stored. `{:error, :already_has_key}`
  when the user already holds an active key under that name; revoke it to
  reuse the label. A blank name becomes "default".
  """
  def create_key(user, name \\ "default") do
    name = normalize_name(name)

    if active_key_named?(user.id, name) do
      {:error, :already_has_key}
    else
      plaintext = "ls_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

      %ApiKey{}
      |> ApiKey.changeset(%{
        user_id: user.id,
        key_hash: :crypto.hash(:sha256, plaintext),
        encrypted_key: Vault.encrypt(plaintext),
        prefix: String.slice(plaintext, 0, 11),
        name: name
      })
      |> Repo.insert()
      |> case do
        {:ok, key} -> {:ok, plaintext, key}
        {:error, %Ecto.Changeset{} = cs} -> if name_taken?(cs), do: {:error, :already_has_key}, else: {:error, cs}
      end
    end
  rescue
    # Two concurrent creates with the same name: the pre-check passed for
    # both, the partial unique index stopped the second. Same answer.
    Ecto.ConstraintError -> {:error, :already_has_key}
  end

  defp normalize_name(name) do
    case name |> to_string() |> String.trim() do
      "" -> "default"
      n -> String.slice(n, 0, 80)
    end
  end

  defp name_taken?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:name, {_, opts}} -> opts[:constraint] == :unique
      _ -> false
    end)
  end

  defp active_key_named?(user_id, name) do
    Repo.exists?(
      from k in ApiKey,
        where: k.user_id == ^user_id and k.name == ^name and is_nil(k.revoked_at)
    )
  end

  @doc """
  The key's plaintext for the owner's Settings page, or `:unavailable` for
  a key created before plaintexts were kept (2026-10-26) or written under a
  rotated `secret_key_base`. Never used by the auth path.
  """
  @spec reveal(ApiKey.t()) :: {:ok, String.t()} | :unavailable
  def reveal(%ApiKey{encrypted_key: nil}), do: :unavailable

  def reveal(%ApiKey{encrypted_key: blob}) do
    case Vault.decrypt(blob) do
      {:ok, plain} -> {:ok, plain}
      :error -> :unavailable
    end
  end

  @doc """
  Store the plaintext of a key that predates the vault, for the two keys
  that existed when it shipped. Refuses anything whose hash does not match
  the stored hash, so a wrong or made-up plaintext can never be attached
  to a key.
  """
  def backfill_plaintext(%ApiKey{} = key, plaintext) when is_binary(plaintext) do
    if :crypto.hash(:sha256, plaintext) == key.key_hash do
      key
      |> Ecto.Changeset.change(encrypted_key: Vault.encrypt(plaintext))
      |> Repo.update()
    else
      {:error, :mismatch}
    end
  end

  def revoke_key(%ApiKey{} = key) do
    key
    |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(:second))
    |> Repo.update()
  end

  @doc "A user's active keys, oldest first."
  def list_keys(user_id) do
    Repo.all(
      from k in ApiKey,
        where: k.user_id == ^user_id and is_nil(k.revoked_at),
        order_by: [asc: k.inserted_at]
    )
  end

  @doc """
  One of the user's own active keys by id, or nil. Scoped to the user on
  purpose: the Settings page revokes by id, and an id from another account
  must never resolve.
  """
  def get_key(user_id, key_id) do
    Repo.one(
      from k in ApiKey,
        where: k.id == ^key_id and k.user_id == ^user_id and is_nil(k.revoked_at)
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

  @doc """
  Calls this month across ALL of a user's keys, revoked ones included: a
  key revoked mid-month already spent its calls, and spending must not
  vanish with the key.
  """
  def user_usage_this_month(user_id) do
    Repo.one(
      from u in ApiUsage,
        join: k in ApiKey,
        on: k.id == u.api_key_id,
        where: k.user_id == ^user_id and u.period == ^current_period(),
        select: sum(u.calls)
    ) || 0
  end

  @doc """
  true when the plan has monthly calls left. Measured on the OWNER's total,
  not this key's, so a second key is a second connector, never a second
  quota.
  """
  def within_quota?(key, plan), do: user_usage_this_month(key.user_id) < monthly_quota(plan)

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
