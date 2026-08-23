defmodule LS.Engagement do
  @moduledoc """
  The founder-led activation loop: three emails, nothing else.

    1. **Welcome** — plain text from the founder, sent the moment an account is
       first confirmed. One question, built to be replied to: reply rate
       predicts conversion (r≈0.62) where opens don't (r≈0.21).
    2. **Wall** — sent once, ever, the day after a free user searched but
       could not export. Behaviour-triggered beats time-drip by ~30% on
       conversion, and this is the single highest-intent moment in the funnel:
       they built a list they wanted and hit the wall taking it away.
    3. **Digest** — weekly, capped by `digest_last_sent_at`, only to
       `digest_subscribed` users, always anchored on the user's LAST search
       (from the audit trail) so it is about *their* list, not our product.

  Deliberately not a marketing platform: no sequences, no scoring, no HTML
  templates. Total sends per user lifecycle ≤ 1 welcome + 1 wall + 1/week
  digest they can leave in one click.

  Unsubscribe honours `users.digest_subscribed` — a durable column, not a
  provider-side suppression list, so the choice survives provider switches
  and is visible in every query that selects recipients.
  """

  import Ecto.Query
  import Swoosh.Email, except: [from: 2]
  require Logger

  alias LS.{Accounts.User, Audit, Clickhouse, Mailer, Repo}

  @from {"Will at ListSignal", "will@listsignal.com"}
  @tick_ms 60 * 60 * 1000

  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    # Only the master sends email, and never in dev/test.
    if Keyword.get(opts, :enabled, System.get_env("LS_ROLE") == "master") do
      Process.send_after(self(), :tick, @tick_ms)
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    safely(&send_wall_emails/0)
    safely(&send_digests/0)
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, state}
  end

  defp safely(fun) do
    fun.()
  rescue
    e -> Logger.error("[ENGAGE] #{Exception.message(e)}")
  end

  # ── 1. Welcome ───────────────────────────────────────────────────────────

  @doc """
  Send the founder welcome. Called from the confirmation path, so it goes out
  within the minute of activation — welcome emails inside a minute see ~10x
  the engagement of ones delayed an hour. Never raises: a mail failure must
  not break login.
  """
  def send_welcome(%User{} = user) do
    email =
      base_email(user)
      |> subject("What list are you trying to build?")
      |> text_body("""
      Hi,

      Will here, I built ListSignal.

      One question, because it shapes what I build next: what list are you
      trying to build?

      Two things people come here for:

      1. Shopify stores that went live this week and already have a contact
         address. About 5,000 of those every week, and you reach them before
         anyone else does.

      2. SaaS companies under $10M that are hiring right now. Big enough to
         have budget, small enough that you reach the person who decides.

      Tell me what you are after and I can build the list with you.

      Will
      listsignal.com
      """)

    deliver(email, "welcome", user)
  end

  # ── 2. The wall ──────────────────────────────────────────────────────────

  @doc """
  Email free users who searched 18–48h ago and could not export. Once per
  user, ever (`wall_email_sent_at`). The email quotes THEIR latest search and
  its current match count — their number, not our copy.
  """
  def send_wall_emails do
    for user <- wall_candidates() do
      case last_search(user.email) do
        nil ->
          :ok

        filters ->
          count = count_for(filters)

          email =
            base_email(user)
            |> subject("Your ListSignal search matched #{format_number(count)} businesses")
            |> text_body(wall_body(count, filters))

          case deliver(email, "wall", user) do
            :ok ->
              user
              |> Ecto.Changeset.change(wall_email_sent_at: now())
              |> Repo.update()

            _ ->
              :ok
          end
      end
    end

    :ok
  end

  defp wall_candidates do
    cutoff_recent = DateTime.add(DateTime.utc_now(), -18 * 3600, :second)
    cutoff_old = DateTime.add(DateTime.utc_now(), -48 * 3600, :second)

    searched =
      from(a in LS.Audit.Event,
        where: a.event == "search",
        where: a.inserted_at < ^cutoff_recent and a.inserted_at > ^cutoff_old,
        select: a.email,
        distinct: true
      )
      |> Repo.all()
      |> Enum.reject(&is_nil/1)

    if searched == [] do
      []
    else
      from(u in User,
        where: u.email in ^searched,
        where: is_nil(u.wall_email_sent_at),
        where: u.plan == "free" or is_nil(u.plan),
        where: not is_nil(u.confirmed_at)
      )
      |> Repo.all()
    end
  end

  # ── 3. Digest ────────────────────────────────────────────────────────────

  @doc """
  Weekly signal digest, anchored on each user's LAST search. Only
  `digest_subscribed` users; at most one per 7 days; skipped entirely when
  the user has never searched (a digest about nothing teaches people to
  unsubscribe).
  """
  def send_digests do
    for user <- digest_candidates() do
      case last_search(user.email) do
        nil ->
          :ok

        filters ->
          send_digest(user, filters)
      end
    end

    :ok
  end

  defp digest_candidates do
    week_ago = DateTime.add(DateTime.utc_now(), -7 * 24 * 3600, :second)

    from(u in User,
      where: u.digest_subscribed == true,
      where: not is_nil(u.confirmed_at),
      where: is_nil(u.digest_last_sent_at) or u.digest_last_sent_at < ^week_ago
    )
    |> Repo.all()
  end

  defp send_digest(user, filters) do
    new_count = count_new_for(filters, 7)
    signals = signal_highlights(filters)

    # An empty digest is worse than none: skip quiet weeks silently.
    if new_count > 0 or signals != [] do
      email =
        base_email(user)
        |> subject("#{format_number(new_count)} new businesses match your last search")
        |> text_body(digest_body(user, new_count, filters, signals))
        |> header("List-Unsubscribe", "<#{unsubscribe_url(user)}>")
        |> header("List-Unsubscribe-Post", "List-Unsubscribe=One-Click")

      case deliver(email, "digest", user) do
        :ok ->
          user |> Ecto.Changeset.change(digest_last_sent_at: now()) |> Repo.update()

        _ ->
          :ok
      end
    end
  end

  @doc """
  The user's most recent dashboard search, from the durable audit trail.
  Returns the filter map or nil. Public because the digest is a promise
  about "your last search" and tests must pin that it really is the LAST one.
  """
  def last_search(email) do
    from(a in LS.Audit.Event,
      where: a.email == ^email and a.event == "search",
      order_by: [desc: a.inserted_at],
      limit: 1,
      select: a.metadata
    )
    |> Repo.one()
    |> case do
      %{"filters" => filters} when is_map(filters) and map_size(filters) > 0 -> filters
      _ -> nil
    end
  end

  @doc """
  Send all three templates to one address so the owner can judge the real
  thing: same renderer, same From, same Mailgun path as production. Uses the
  recipient's own last search when they have one, otherwise a representative
  example, so the wall and digest read exactly as a customer would see them.
  """
  def preview_all(email_address) do
    user =
      Repo.get_by(User, email: email_address) ||
        %User{id: 0, email: email_address, digest_subscribed: true}

    filters = last_search(email_address) || %{"tech" => "Shopify", "has_email" => "true"}

    send_welcome(user)
    send_wall_preview(user, filters)
    send_digest_preview(user, filters)
    :ok
  end

  defp send_wall_preview(user, filters) do
    count = count_for(filters)

    base_email(user)
    |> subject("[preview] Your ListSignal search matched #{format_number(count)} businesses")
    |> text_body(wall_body(count, filters))
    |> deliver_preview(user)
  end

  defp send_digest_preview(user, filters) do
    new_count = count_new_for(filters, 7)
    signals = signal_highlights(filters)

    base_email(user)
    |> subject("[preview] #{format_number(new_count)} new businesses match your last search")
    |> text_body(digest_body(user, new_count, filters, signals))
    |> deliver_preview(user)
  end

  defp deliver_preview(email, user), do: deliver(email, "preview", user)

  @doc false
  def wall_body(count, filters) do
    """
    Hi,

    Will from ListSignal.

    The search you ran yesterday matches #{format_number(count)} businesses
    (#{describe(filters)}).

    Free accounts can browse them, exporting needs a paid plan. Two ways
    to get the list:

    Starter is $29/mo for 5,000 rows a month, cancel any time:
    https://listsignal.com/pricing

    Or reply here and I will send you the first 25 rows free. No card.
    I would rather you see the data quality than take my word for it.

    And if this list is not quite the right one, tell me what you
    actually need and I can build it with you.

    Will
    """
  end

  @doc false
  def digest_body(user, new_count, filters, signals) do
    signal_lines =
      case signals do
        [] -> ""
        lines -> "\n" <> Enum.join(lines, "\n") <> "\n"
      end

    """
    Hi,

    #{format_number(new_count)} new businesses matched your last search this week
    (#{describe(filters)}).

    See them, freshest first:
    https://listsignal.com/dashboard
    #{signal_lines}
    Want a different cut of the data? Reply and I can build it with you.

    Will

    You get one of these a week, about your own search.
    Unsubscribe: #{unsubscribe_url(user)}
    """
  end

  # ── Unsubscribe ──────────────────────────────────────────────────────────

  @salt "digest-unsubscribe"
  # A year: unsubscribe links in old emails must keep working — a dead
  # unsubscribe link is how legitimate mail becomes spam reports.
  @token_max_age 365 * 24 * 3600

  def unsubscribe_token(%User{id: id}), do: Phoenix.Token.sign(LSWeb.Endpoint, @salt, id)

  def unsubscribe_url(user),
    do: "https://listsignal.com/digest/unsubscribe/#{unsubscribe_token(user)}"

  @doc "Verify a token and persist the opt-out. Idempotent."
  def unsubscribe(token) do
    with {:ok, user_id} <- Phoenix.Token.verify(LSWeb.Endpoint, @salt, token, max_age: @token_max_age),
         %User{} = user <- Repo.get(User, user_id) do
      user |> Ecto.Changeset.change(digest_subscribed: false) |> Repo.update()
    else
      _ -> {:error, :invalid}
    end
  end

  # ── shared ───────────────────────────────────────────────────────────────

  defp base_email(user) do
    new()
    |> to(user.email)
    |> Swoosh.Email.from(@from)
    |> reply_to(elem(@from, 1))
  end

  defp deliver(email, kind, user) do
    case Mailer.deliver(email) do
      {:ok, _} ->
        Audit.record("engagement_#{kind}", %{email: user.email, user_id: user.id})
        :ok

      {:error, reason} ->
        Logger.warning("[ENGAGE] #{kind} to #{user.email} failed: #{inspect(reason)}")
        :error
    end
  end

  defp count_for(filters), do: do_count(filters, nil)
  defp count_new_for(filters, days), do: do_count(filters, days)

  defp do_count(filters, days) do
    atomized =
      Map.new(filters, fn {k, v} -> {String.to_existing_atom(to_string(k)), v} end)

    atomized = if days, do: Map.put(atomized, :first_seen_days, days), else: atomized

    case Clickhouse.count_businesses_for_digest(atomized) do
      {:ok, n} -> n
      _ -> 0
    end
  rescue
    # An unknown filter key (schema drift since the search was recorded) must
    # not crash the whole batch.
    _ -> 0
  end

  # Signal highlights only when the search names a tech/app — a global
  # firehose is noise, their tech's churn is signal.
  defp signal_highlights(filters) do
    tech = filters["tech"] || filters["shopify_app"]

    if tech in [nil, ""] do
      []
    else
      tech
      |> String.split(",", trim: true)
      |> Enum.take(2)
      |> Enum.flat_map(fn t ->
        case Clickhouse.signal_counts_for(String.trim(t), 7) do
          {:ok, added, removed} when added + removed > 0 ->
            ["#{t}: #{format_number(added)} businesses added it, #{format_number(removed)} dropped it"]

          _ ->
            []
        end
      end)
    end
  end

  defp describe(filters) do
    filters
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{v}" end)
    |> case do
      "" -> "all businesses"
      s -> s
    end
  end

  defp format_number(n) when is_integer(n),
    do: n |> Integer.to_string() |> String.replace(~r/(?<=\d)(?=(\d{3})+$)/, ",")

  defp format_number(n), do: to_string(n)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
