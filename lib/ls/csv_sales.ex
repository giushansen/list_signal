defmodule LS.CsvSales do
  @moduledoc """
  Selling a one-off CSV to someone who is not a user.

  ## The flow, end to end

      1. `create_order/1`     you build the CSV, this records the sale and
                              watermarks the buyer's copy
      2. Stripe Payment Link  you paste the link into the outreach email
      3. `mark_paid/2`        the webhook flips the order to paid
      4. `GET /d/:token`      buyer downloads; every hit is recorded
      5. `LS.Audit`           the durable trail a dispute is decided on

  Deliberately no account, no login, no dashboard: a cold-outreach buyer who
  has already paid should not have to register to receive the file. The
  unguessable token in the URL is the credential, which is why it expires and
  why every download is written down.

  ## Watermarking, and what it can and cannot do

  Two marks, both cheap:

    * a **watermark id** in a trailing comment row — visible, removable, and
      enough to identify a copy someone forwarded without thinking;
    * **canary rows** — a handful of synthetic domains unique to this buyer,
      mixed into the data. These survive reformatting, re-sorting, and import
      into a CRM. If a list turns up elsewhere, the canaries name the buyer.

  What this cannot do is tell you when a file is *opened*. A CSV is an inert
  text file: it cannot load a tracking pixel, and anything that could would
  be a macro that mail gateways strip and buyers rightly distrust. Download
  tracking is real; open tracking is not available at this format, and
  claiming otherwise in a dispute would be worse than saying nothing.
  """

  import Ecto.Query, warn: false

  alias LS.CsvSales.Order
  alias LS.Repo

  @default_validity_days 30
  @canary_count 3

  @doc """
  Record a sale and write the buyer's watermarked copy of `rows`.

  Options: `:description`, `:amount_cents`, `:currency`, `:stripe_payment_link`,
  `:valid_for_days` (default #{@default_validity_days}).
  """
  @spec create_order(String.t(), [String.t()], [[term()]], keyword()) ::
          {:ok, Order.t()} | {:error, term()}
  def create_order(email, columns, rows, opts \\ []) do
    token = generate_token()
    watermark = generate_watermark()
    canaries = generate_canaries(watermark)
    dir = storage_dir()
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{token}.csv")

    File.write!(path, build_csv(columns, rows, watermark, canaries, email))

    valid_days = Keyword.get(opts, :valid_for_days, @default_validity_days)

    %Order{}
    |> Order.changeset(%{
      token: token,
      email: email,
      description: Keyword.get(opts, :description),
      file_path: path,
      row_count: length(rows),
      amount_cents: Keyword.get(opts, :amount_cents),
      currency: Keyword.get(opts, :currency, "usd"),
      stripe_payment_link: Keyword.get(opts, :stripe_payment_link),
      watermark: watermark,
      canary_domains: Enum.join(canaries, "|"),
      expires_at: DateTime.utc_now() |> DateTime.add(valid_days * 86_400, :second) |> trim()
    })
    |> Repo.insert()
  end

  @doc "Fetch an order by its download token."
  @spec get_by_token(String.t()) :: Order.t() | nil
  def get_by_token(token) when is_binary(token), do: Repo.get_by(Order, token: token)

  @doc "Fetch an order by the Stripe checkout session that paid for it."
  @spec get_by_session(String.t()) :: Order.t() | nil
  def get_by_session(session_id) when is_binary(session_id),
    do: Repo.get_by(Order, stripe_session_id: session_id)

  @doc """
  Mark an order paid. Idempotent: Stripe retries webhooks, and a second
  `checkout.session.completed` must not move `paid_at` or look like a second
  purchase in the evidence trail.
  """
  @spec mark_paid(Order.t(), String.t() | nil) :: {:ok, Order.t()} | {:error, term()}
  def mark_paid(%Order{paid_at: paid_at} = order, _session_id) when not is_nil(paid_at),
    do: {:ok, order}

  def mark_paid(%Order{} = order, session_id) do
    order
    |> Order.changeset(%{paid_at: trim(DateTime.utc_now()), stripe_session_id: session_id})
    |> Repo.update()
  end

  @doc """
  Record a download. Returns the updated order.

  Counting every hit rather than only the first is deliberate: "downloaded
  four times from two countries" is a far stronger answer to a
  "never received it" dispute than a single boolean.
  """
  @spec record_download(Order.t(), String.t() | nil) :: {:ok, Order.t()} | {:error, term()}
  def record_download(%Order{} = order, ip) do
    now = trim(DateTime.utc_now())

    order
    |> Order.changeset(%{
      download_count: (order.download_count || 0) + 1,
      first_downloaded_at: order.first_downloaded_at || now,
      last_downloaded_at: now,
      last_download_ip: ip
    })
    |> Repo.update()
  end

  @doc """
  Which order a leaked canary domain belongs to — the whole point of seeding
  them. Give it a domain you found in someone else's list.
  """
  @spec trace_canary(String.t()) :: [Order.t()]
  def trace_canary(domain) when is_binary(domain) do
    pattern = "%#{domain}%"
    Repo.all(from o in Order, where: like(o.canary_domains, ^pattern))
  end

  @doc "Where buyer copies live. Override with LS_CSV_DIR."
  def storage_dir, do: System.get_env("LS_CSV_DIR") || Path.join(File.cwd!(), "priv/csv_orders")

  # ── building the file ──────────────────────────────────────────────────────

  @doc """
  The buyer's copy: their rows, their canaries, their watermark.

  Exposed for tests — a watermark that silently stops being written is worse
  than none, because you would only discover it while trying to trace a leak.
  """
  @spec build_csv([String.t()], [[term()]], String.t(), [String.t()], String.t()) :: String.t()
  def build_csv(columns, rows, watermark, canaries, email) do
    canary_rows = Enum.map(canaries, &canary_row(&1, columns))

    # Canaries sit inside the data, not at the end: a buyer who trims the last
    # few lines before reselling still carries them.
    all_rows = interleave(rows, canary_rows)

    [
      Enum.join(columns, ","),
      Enum.map_join(all_rows, "\n", &csv_line/1),
      "",
      "# Licensed to #{email} — single-organisation use. ref:#{watermark}"
    ]
    |> Enum.join("\n")
  end

  defp interleave(rows, []), do: rows

  defp interleave(rows, canaries) do
    # Spread them evenly through the file rather than bunching them.
    step = max(div(length(rows), length(canaries) + 1), 1)

    canaries
    |> Enum.with_index(1)
    |> Enum.reduce(rows, fn {canary, i}, acc ->
      at = min(i * step, length(acc))
      List.insert_at(acc, at, canary)
    end)
  end

  defp canary_row(domain, columns) do
    # Shaped like a real row so it survives a glance, and so a buyer importing
    # the list into a CRM keeps it.
    Enum.map(columns, fn
      "domain" -> domain
      "title" -> "Wholesale Supply Co"
      "country" -> "US"
      _ -> ""
    end)
  end

  defp csv_line(row), do: Enum.map_join(row, ",", &csv_cell/1)

  defp csv_cell(nil), do: ""

  defp csv_cell(value) do
    str = to_string(value)

    if String.contains?(str, [",", "\"", "\n"]) do
      "\"" <> String.replace(str, "\"", "\"\"") <> "\""
    else
      str
    end
  end

  # ── identifiers ────────────────────────────────────────────────────────────

  # 32 url-safe chars: the link is the credential, so it must not be guessable
  # and must not need escaping in an email client.
  defp generate_token, do: 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp generate_watermark, do: 6 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  # Domains that look ordinary but are ours, derived from the watermark so the
  # mapping survives even if the row is lost.
  defp generate_canaries(watermark) do
    for i <- 1..@canary_count do
      suffix = watermark |> String.slice(0, 6)
      "#{canary_word(i)}-#{suffix}.com"
    end
  end

  defp canary_word(1), do: "northgate-supply"
  defp canary_word(2), do: "brightwater-trading"
  defp canary_word(_), do: "cedarpoint-partners"

  # SQLite stores second precision; keep DateTimes comparable on read-back.
  defp trim(dt), do: DateTime.truncate(dt, :second)
end
