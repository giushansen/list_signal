# Selling a one-off CSV

The runbook for the cold-outreach motion: you build a targeted list, the buyer
pays through a Stripe link, they download it once, and you can prove all of it
if the charge is ever disputed.

No account, no login, no dashboard for the buyer. They came from an email and
already paid — asking them to register before receiving what they bought loses
sales. **The unguessable token in the download URL is the credential**, which
is why links expire and why every download is written down.

---

## 1. Build the list

Any query that returns columns and rows works. Start from
`v_business_export` — it is the customer-facing shape already (one row per
business, children flattened).

```elixir
# On the master:  _build/prod/rel/ls/bin/ls remote

{:ok, rows} = LS.Clickhouse.query("""
  SELECT domain, title, country, all_emails, product_price_avg, products, tech
  FROM v_business_export
  WHERE platform = 'Shopify'
    AND country = 'DE'
    AND products BETWEEN 50 AND 500
    AND all_emails != ''
  ORDER BY coalesce(tranco_rank, 99999999)
  LIMIT 2000
""")

columns = ~w(domain title country all_emails product_price_avg products tech)
```

Aim for **500–3,000 rows**. Below 500 the buyer feels short-changed; above
~5,000 the file stops being a targeted list and starts being a database dump —
which is both less valuable to them and easier to resell.

## 2. Create the order

```elixir
{:ok, order} = LS.CsvSales.create_order(
  "buyer@theircompany.com",
  columns,
  rows,
  description: "German Shopify stores, 50-500 products",
  amount_cents: 19_900,
  stripe_payment_link: "https://buy.stripe.com/xxxxx",
  valid_for_days: 30
)

order.token      # => "kJ8s...": goes in the download URL
order.watermark  # => "a3f2c1": identifies this buyer's copy
```

This writes their **watermarked copy** to disk immediately. The file exists
before payment; the download endpoint refuses to serve it until `paid_at` is
set.

## 3. Send the email

Two links, in this order:

```
Here are 1,847 German Shopify stores with 50-500 products,
each with a contact address and their average product price.

Sample (10 rows):  https://listsignal.com/sample/...
Get the full file: https://buy.stripe.com/xxxxx  — $199, one-off
```

Keep the payment link and the download link separate. The buyer gets the
download link **after** payment, in the receipt or your follow-up.

## 4. Mark it paid

When Stripe confirms the payment:

```elixir
order = LS.CsvSales.get_by_token("kJ8s...")
{:ok, order} = LS.CsvSales.mark_paid(order, "cs_live_...")
```

Idempotent by design — Stripe retries webhooks, and a second delivery must not
look like a second purchase in the evidence trail.

## 5. Send the download link

```
https://listsignal.com/d/kJ8s...
```

Valid for the period you set. Every hit is counted with its IP and timestamp;
unpaid and expired attempts are recorded too.

## 6. If the charge is disputed

```elixir
LS.Audit.history("buyer@theircompany.com")
```

Gives you, in order: when the order was created, when it was paid, and every
download with timestamp and IP. That is the evidence a card network wants —
"downloaded 3 times from two IPs in Germany between 2 and 5 May" answers
"I never received it" in a way a support email cannot.

Include in your dispute response: the order description, row count, the
download timestamps, and the terms the buyer accepted at purchase.

---

## Checking on a sale

```elixir
order = LS.CsvSales.get_by_token(token)

order.paid_at              # nil until Stripe confirms
order.download_count       # every hit, not just the first
order.first_downloaded_at
order.last_download_ip
order.expires_at
```

## Tracing a leak

If a list you sold turns up somewhere it should not:

```elixir
LS.CsvSales.trace_canary("northgate-supply-a3f2c1.com")
# => [%Order{email: "buyer@theircompany.com", ...}]
```

See `docs/watermarking.md` for what the marks are and what they can prove.

---

## Testing Stripe before you sell

**Use test mode for the flow, one real charge for the wiring.**

Live mode rejects test cards outright, so `4242 4242 4242 4242` against a live
key proves nothing — and repeated failed live attempts can look like card
testing to Stripe's fraud systems, which is worth avoiding.

1. **Test mode**: swap in test keys, make a test payment link, and run the whole
   sequence with `4242 4242 4242 4242` (any future expiry, any CVC). Confirm the
   webhook fires, `paid_at` is set, and the download works.
2. **One live charge**: buy a real $1 link with your own card, confirm the
   download, then refund it in the Stripe dashboard. This is the only way to
   verify live keys, webhook signatures and your payout path together. A
   refunded charge costs you nothing and does not count against you.

Never ship a payment link you have not walked through end to end yourself.
