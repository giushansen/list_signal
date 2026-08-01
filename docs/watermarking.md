# What the watermark actually does

Every CSV sold carries two marks. Neither prevents copying — nothing can, once
a file is in someone's hands. What they do is make **attribution** possible,
and attribution is what makes a resale clause enforceable rather than
decorative.

## The two marks

### 1. The visible reference

A line at the end of the file:

```
# Licensed to buyer@theircompany.com — single-organisation use. ref:a3f2c1
```

Names the licensee and carries a short id tied to the order.

**What it catches:** casual forwarding. Someone shares the file with a
colleague at another company, or posts it in a Slack they shouldn't; the
licence line travels with it and the recipient can see it wasn't theirs to
have. Most informal leaking is thoughtless rather than malicious, and a
visible mark stops a good share of it before it starts.

**What it does not catch:** anyone who reads the file before resharing.
Deleting one comment line takes seconds.

### 2. The canary rows

Three synthetic businesses, unique to each buyer, are woven into the data:

```
northgate-supply-a3f2c1.com,Wholesale Supply Co,US
brightwater-trading-a3f2c1.com,Wholesale Supply Co,US
cedarpoint-partners-a3f2c1.com,Wholesale Supply Co,US
```

Shaped like real rows, spread through the file rather than bunched at the end.

**What they catch:** deliberate resale. The canaries survive everything a
reseller normally does — deleting the comment line, re-sorting, filtering
columns, importing into a CRM, exporting again, merging with another list.
Because the domains are unique per buyer, finding one in a list you did not
sell tells you exactly whose copy it came from:

```elixir
LS.CsvSales.trace_canary("northgate-supply-a3f2c1.com")
# => the order, the buyer's email, the purchase date
```

**What they do not catch:** someone who cross-references your file against a
second source and drops rows that only appear in yours. That requires effort
and suspicion; almost nobody does it.

## The honest limits

- **Nothing stops copying.** A determined reseller with two sources and
  patience can strip both marks. The goal is to raise the cost above the value
  and to be able to prove it when it happens anyway.
- **You cannot know when a file is opened.** A CSV is inert text — it cannot
  load a tracking pixel, and anything that could would be a macro that mail
  gateways strip and buyers rightly distrust. What you get is **download**
  tracking: how many times, when, and from which IP. That is real evidence.
  Open tracking would mean shipping XLSX or a hosted view instead, which is a
  different product decision.
- **Canaries are fake rows in a paid product.** Three in a list of 2,000 is
  0.15% — immaterial to the buyer's use, and they look like ordinary small
  businesses. Worth knowing you made that trade deliberately.
- **Attribution is not proof of publication.** A canary tells you whose copy
  leaked. It does not tell you who did the leaking if that buyer was itself
  breached. Treat it as strong evidence for a conversation, not as a verdict.

## Why this matters legally

The terms say the data is licensed for single-organisation use and may not be
resold, and that files carry markers identifying the purchaser. That sentence
only has teeth because the markers exist: without them, a resale claim is an
assertion; with them, it is a demonstration.
