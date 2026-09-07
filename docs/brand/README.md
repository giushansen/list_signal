# ListSignal brand and design guide

Written from the code. Every rule below names the file, test or config that
enforces it. If the code and this page disagree, fix one of them in the same
change; do not let them drift.

## 1. Identity

**ListSignal** is one word, capital L and capital S. Never "List Signal", never
"LS" in prose or as a logo. The old two-letter box is gone and
`test/ls_web/brand_test.exs` fails if it comes back.

One-line description, from the site's own `<title>` in
`lib/ls_web/components/layouts.ex` (`public_root/1`):

> ListSignal | Domain Intelligence, Checked in Real Time

Tone is evidence first. The code says so in more places than the marketing
does:

- Unknown beats fabricated: `lib/ls/country_inferrer.ex` (module doc, rule 6),
  `lib/ls/clickhouse.ex` (the comment on the silent fallback to "fabricated
  numbers"), `lib/ls/cluster/queue_trend.ex`.
- A search description must never misrepresent the search:
  `test/ls/engagement_test.exs` ("the search description (it must never
  misrepresent the search)") and the comment above `describe/1` in
  `lib/ls/engagement.ex`.
- Emails are a founder's note, not a campaign: `test/ls/engagement_test.exs`
  asserts no `<img>` and no branded header.
- Copy is typed by a person: `test/ls_web/human_copy_test.exs` fails the build
  on em dashes, curly quotes and the ellipsis character. The full writing
  rules are in `CLAUDE.md`, "Writing: sound like a person, not a model".
- Analytics are self-hosted and cookieless (Umami), see `README.md`,
  "Web Analytics (Umami)". No third-party pixels on the marketing site.

## 2. Logo

"Live list": three horizontal lines of equal length and equal stroke, the
middle one carrying a heartbeat. Three records, one live signal.

Construction: a 64-unit grid, stroke 7, round caps and round joins, one
stroke weight everywhere. The path is the logo:

```
M10 11H54 M10 32H23L28 23L36 41L41 32H54 M10 53H54
```

It lives in exactly two places, and a test pins them to each other:

- `lib/ls_web/components/brand_components.ex`, `@mark_path`, rendered inline
  by `logo_mark/1` (coloured by `currentColor`, no request).
- `docs/brand/gen_brand_assets.py`, `MARK_D`, from which every file under
  `priv/static/images/brand/` and every favicon is generated.

`test/ls_web/brand_test.exs` asserts the inline path, the stroke attributes,
and that `mark.svg` on disk carries the same path.

### Colourways

| Colourway | File | Use |
|---|---|---|
| White on green (primary) | `tile-green.svg`, `tile-green-{256,512,1024}.png`, `favicon.*`, `icon-*.png`, `apple-touch-icon.png` | Everywhere the tile appears: navbar, footer, auth pages, app headers, favicons, third-party avatars |
| White on dark | `tile-black.svg`, `tile-black-512.png`, `mark-white.svg` | On `ls-dark` surfaces when the tile itself is not wanted, and dark-mode avatars |
| Dark on white | `tile-white.svg`, `tile-white-512.png`, `mark-black.svg` | Light surfaces, print, `lockup-on-light` |

"Dark" is Tailwind `ls-dark` (`#080E1E`), "green" is Tailwind `accent`
(`#10B981`), both from `assets/tailwind.config.js`. The generator's `ACCENT`
and `DARK` constants must equal them; `brand_test.exs` checks the manifest's
colour against the config.

### Sizes and space

- Tile: at least 16 px. `logo_tile/1` switches from `rounded-lg` to
  `rounded` below 24 px so the corner radius stays proportionate; the 16 px
  favicon uses a tighter mark scale (`TINY_MARK_SCALE`) so the stroke survives.
- Inline mark: at least 14 px. The smallest one in the product is 18 px
  (footer copyright line).
- Clear space: one stroke width (7/64 of the mark's box) on every side. The
  tiles bake this in: the mark is 0.66 of the tile, the same ratio
  `logo_tile/1` uses.

### Don'ts

No gradient, shadow, glow, outline, rotation or animation. No recolouring
outside the three colourways. No letters added to or around the mark. Never
the bare mark on accent green without the tile (2.5:1 contrast, see §3).
The old navbar box carried a `bg-gradient-to-br from-white/20` overlay;
`brand_test.exs` fails if that string returns to `lib/ls_web`.

### Where each surface gets it

| Surface | Component or file |
|---|---|
| Public navbar | `<.logo_lockup />` in `public_nav/1`, `layouts.ex` |
| Public footer, brand line | `<.logo_tile size={36} />` in `footer/1` |
| Public footer, copyright | `<.logo_mark size={18} class="text-white/35" />` in `footer/1` |
| Browser tab, home screen, PWA | `head_icons/1` in `layouts.ex`, used by `public_root/1` and `root/1` |
| Share cards | `og-card.png` via `og:image` in `public_root/1` |
| Log in, sign up, magic-link confirmation | `<.logo_lockup />` in `lib/ls_web/live/user_live/{login,registration,confirmation}.ex` |
| Customer dashboard header | `<.logo_lockup href={~p"/dashboard"} text_class="text-base" />` in `explorer_live.ex` |
| Customer dashboard and settings footer | `<.logo_tile size={16} class="opacity-80" />` |
| Settings header | `<.logo_tile size={32} />` beside the page name, `settings.ex` |
| Admin dashboard | `<.logo_mark size={20} class="header-mark" />` in `dashboard_live.ex` |
| OpenAPI (Redoc) | `info["x-logo"]` in `lib/ls_web/controllers/openapi_controller.ex` |
| GitHub README | `priv/static/images/brand/tile-green-256.png` |
| Emails | Nothing, on purpose (`test/ls/engagement_test.exs`) |

## 3. Colour

Tokens, copied from `theme.extend.colors` in `assets/tailwind.config.js`:

| Token | Hex | Where used |
|---|---|---|
| `ls-dark` | `#080E1E` | Page background and navbar (`bg-ls-dark`, `bg-ls-dark/85`) in `layouts.ex`; `theme-color` and manifest colour |
| `ls-dark-2` | `#0C1429` | Defined, not used as a class anywhere in `lib/ls_web`; the value appears as a literal in `page_html/developers.html.heex` |
| `ls-dark-3` | `#111B33` | Defined, not used as a class; the literal `bg-[#111B33]` is the auth-page card colour (41 uses) |
| `accent` | `#10B981` | CTAs, links, live dots, the logo tile (`bg-accent` 112 uses, `text-accent` 113) |
| `accent-hover` | `#34D399` | Hover state of every accent CTA (30 uses) |

Not tokens, hard-coded, and worth knowing about:

- `bg-[#0a0e17]`: the `root/1` body and the three auth pages (9 uses). It is
  not `ls-dark`; the two darks differ by a few units.
- `bg-[#0B0F19]` and `bg-[#0F1628]`: the customer dashboard page and header
  in `explorer_live.ex` and `settings.ex`.
- Emerald, amber, blue and red utilities (`emerald-400`, `amber-500`,
  `blue-500`, `red-500`) carry status meaning in the dashboard and the plan
  badges.

Admin dashboard palette, inline CSS in `lib/ls_web/live/dashboard_live.ex`
(dashboard only, not Tailwind tokens): background `#0a0e17`, cards `#111827`,
borders `#1e293b`, dashboard accent `#38bdf8`, status green `#4ade80`, amber
`#fbbf24`, red `#f87171`, heading text `#e8edf4`, body text `#c8d3e0`.

WCAG contrast, computed from the hex values above (relative luminance per
WCAG 2.1):

| Pair | Ratio | Note |
|---|---|---|
| White on `#10B981` | 2.54:1 | Fails AA for text. Fine for the mark in the tile; also the pair on every primary CTA. Recorded, not changed. |
| White on `#080E1E` | 19.23:1 | Passes everything |
| `#080E1E` on `#10B981` | 7.58:1 | Passes AA; the same ratio as accent text on the dark background |
| `#34D399` on `#080E1E` | 10.0:1 | Passes AA |
| `#e8edf4` on `#0a0e17` | 16.41:1 | Admin dashboard headings |

## 4. Typography

| Role | Family | Token | Loaded weights |
|---|---|---|---|
| Display, wordmark, headings | Sora | `font-display` (`assets/tailwind.config.js`) | 400, 500, 600, 700, 800 |
| Body | DM Sans | `font-body`, and the `body` rule in `assets/css/app.css` | 400, 500, 600, 700, italic 400 |
| Admin dashboard numbers and labels | JetBrains Mono | none, inline `@import` in `dashboard_live.ex` | 400, 500, 600, 700 |
| Admin dashboard text | IBM Plex Sans | none, same `@import` | 400, 500, 600 |

Weights come from the Google Fonts `<link>` in `public_root/1`. The customer
dashboard declares `font-['Inter',system-ui,sans-serif]` in
`explorer_live.ex` and `settings.ex` but Inter is not loaded anywhere, so it
renders in the system font.

The wordmark is `font-display font-bold tracking-tight` at `text-[21px]` in
the navbar (`logo_lockup/1` default), `text-base` in the customer dashboard
header. Display sizes actually used with `font-display`, by count: `text-lg`
(43), `text-2xl` (42), `text-sm` (31), `text-[15px]` (16), `text-base` (15),
`text-xl` (10), `text-[clamp(28px,4vw,40px)]` (8), `text-4xl` (5). The home
hero is `text-[clamp(38px,5.2vw,62px)] font-extrabold leading-[1.08]
tracking-[-2px]` (`page_html/home.html.heex`). Prices on `/pricing` are
`text-[48px] font-extrabold tracking-[-2px]`.

## 5. Layout and components

Class strings are copied, not paraphrased.

- Container: `mx-auto max-w-[1200px] px-6` (25 uses). The footer uses
  `max-w-6xl mx-auto px-6`, the customer dashboard `max-w-[1700px] mx-auto px-5`.
- Fixed navbar: `fixed top-0 left-0 right-0 z-50 border-b border-white/[0.07]
  bg-ls-dark/85 backdrop-blur-xl` (`public_nav/1`). Pages start at
  `pt-[140px]` to clear it.
- Radii in use, by count in `lib/ls_web`: `rounded-xl` (142), `rounded-full`
  (69), `rounded-lg` (64), `rounded-2xl` (5). Tiles and nav buttons are
  `rounded-lg`, large CTAs `rounded-xl`, chips and dots `rounded-full`, home
  feature cards `rounded-[20px]`.
- Primary CTA, navbar: `rounded-lg bg-accent px-4 md:px-5 py-2 text-sm
  font-semibold text-white hover:bg-accent-hover transition-all
  hover:-translate-y-px`.
- Primary CTA, large (home bottom): `inline-flex items-center gap-2 rounded-xl
  bg-accent px-8 py-4 font-display text-[15px] font-semibold text-white
  shadow-[0_8px_28px_rgba(16,185,129,0.25)] hover:bg-accent-hover
  hover:-translate-y-0.5 transition-all`.
- Secondary link: `text-sm font-medium text-white/60 hover:text-white
  transition-colors` (navbar); the `text-white/60` to `hover:text-white`
  pattern appears 151 times.
- Card: `rounded-[20px] bg-white/[0.03] border border-white/[0.07]
  hover:border-accent/25` (home features).
- Plan badges (`explorer_live.ex` header): Pro `inline-flex items-center
  gap-1.5 px-2.5 py-1 rounded-full text-[11px] font-semibold tracking-wide
  uppercase bg-emerald-500/15 text-emerald-400 ring-1 ring-emerald-500/20`;
  Starter the same in `blue-500`/`blue-400`; Free is an amber upgrade button
  with `animate-pulse`.
- Live dot (home): `<span class="h-1.5 w-1.5 rounded-full bg-accent
  animate-pulse"></span> Live Feed`, the same dot at `h-2 w-2` in the hero
  pill and on `/developers`.
- Brand components (`lib/ls_web/components/brand_components.ex`, imported
  everywhere by `html_helpers/0` in `lib/ls_web.ex`):
  - `logo_mark/1`: `size` (default 24), `class`, `label`. Decorative
    (`aria-hidden`) unless labelled, then `role="img"` with a `<title>`.
  - `logo_tile/1`: `size` (default 30), `class`. Box and mark scale together.
  - `logo_lockup/1`: `href` (default `/`), `text_class` (default
    `text-[21px]`), `class`. `inline-flex items-center gap-2 font-display
    font-bold tracking-tight text-white`.

## 6. Copy rules

- Emails are founder notes: paragraphs, no images, no layout tables, no
  branded header, one accent link. `test/ls/engagement_test.exs` and the
  layout in `lib/ls/email_layout.ex`.
- A search description says what the query does, including AND versus OR and
  every filter, even unknown ones. `lib/ls/engagement.ex`, the comment above
  `describe/1`, and `test/ls/engagement_test.exs`.
- No fabricated numbers, anywhere: the country inferrer, the queue trend and
  the ClickHouse fallbacks all choose "unknown" over a made-up value (§1).
- No em dashes, curly quotes or ellipsis characters in templates or emails:
  `test/ls_web/human_copy_test.exs`. The rest of the writing rules are in
  `CLAUDE.md`.

## 7. Assets

All under `priv/static`. Every file is generated; none is edited by hand.

| Path | Size | Use |
|---|---|---|
| `images/brand/mark.svg` | 64x64, `currentColor` | Inline or CSS-coloured mark |
| `images/brand/mark-{white,black,green}.svg`, `-512.png` | 64x64 / 512 px | Fixed-colour mark, transparent |
| `images/brand/tile-green.svg`, `-256.png`, `-512.png`, `-1024.png` | 64x64 / 256, 512, 1024 px | Primary tile: avatars, README, Redoc |
| `images/brand/tile-black.svg`, `-512.png` | 64x64 / 512 px | Tile on dark |
| `images/brand/tile-white.svg`, `-512.png` | 64x64 / 512 px | Tile on light |
| `images/brand/lockup-on-{dark,light}.svg`, `.png`, `-2x.png` | 330x64 / 1x and 2x | Tile plus wordmark, real Sora in the PNGs |
| `favicon.svg` | 64x64 | Modern browsers, listed first |
| `favicon.ico` | 16, 32, 48 | Legacy |
| `favicon-16x16.png`, `favicon-32x32.png` | 16, 32 px | Tab icon fallbacks |
| `apple-touch-icon.png` | 180 px | iOS home screen |
| `icon-192.png`, `icon-512.png` | 192, 512 px | `site.webmanifest`, `any maskable` |
| `site.webmanifest` | | Name, colours (`ls-dark`), icons |
| `og-card.png` | 1200x630 | Share card, `og:image` |
| `docs/brand/preview.png` | 1180x560 | Colourways, lockups and true-pixel favicons at a glance |

Regenerate with:

```
pip install cairosvg pillow
python3 docs/brand/gen_brand_assets.py --out /tmp/bp && cp -R /tmp/bp/priv /tmp/bp/docs .
```

The script has two colour constants, `ACCENT` and `DARK`, which must equal
Tailwind `accent` and `ls-dark`. It fetches Sora and DM Sans from
github.com/google/fonts (cached as `.ttf` next to the script, not committed)
and says on stderr if it had to fall back to DejaVu Sans. Every file in
`images/brand/` and every favicon is a derived file: change the constants or
the path in the script, never the output. `lib/ls_web.ex` `static_paths/0`
lists what Plug.Static serves; `brand_test.exs` checks every brand file is
in that list and exists.

## 8. Where the logo lives

Rolled out 2026-09-07:

- `lib/ls_web/components/layouts.ex`: `public_nav/1` lockup, `footer/1` tile
  and muted mark, `head_icons/1` shared by `public_root/1` and `root/1`,
  `og:image` width, height and alt.
- `lib/ls_web.ex`: `static_paths/0` serves `favicon.svg`, `favicon-16x16.png`,
  `icon-192.png`, `icon-512.png`, `site.webmanifest`; `html_helpers/0`
  imports `LSWeb.BrandComponents`.
- `lib/ls_web/live/dashboard_live.ex`: mark before the h1, `.header-mark`
  rule in the inline CSS.
- `lib/ls_web/live/explorer_live.ex`: lockup in the header, tile in the footer.
- `lib/ls_web/live/user_live/settings.ex`: tile beside the page name, tile
  in the footer.
- `lib/ls_web/live/user_live/login.ex`, `registration.ex`,
  `confirmation.ex`: centred lockup above the form.
- `lib/ls_web/controllers/openapi_controller.ex`: `x-logo` in `info`.
- `README.md`, `CLAUDE.md`: pointer to this page.
- `LSWeb.ErrorHTML` renders plain status text, no layout: nothing to brand.
- `/developers` shows no brand of its own; it gets the navbar.

Manual, outside the repo:

- Stripe, Settings, Branding: icon `tile-green-512.png`, logo
  `lockup-on-light-2x.png`, accent `#10b981`.
- GitHub repository, Settings, Social preview: `og-card.png`.
- Google Workspace avatar for will@listsignal.com: `tile-green-512.png`.
- LinkedIn, X, Product Hunt, Crunchbase: avatar `tile-green-1024.png`,
  banner `og-card.png`.
- MCP registry submissions (`docs/api-and-mcp.md`): `tile-green-512.png`
  wherever a logo is requested.
- Instantly: nothing. Cold-email signatures stay plain text.

Not refactored, on purpose: the per-page `<footer>` blocks in
`lib/ls_web/controllers/tech_html/show.html.heex`,
`store_html/show.html.heex` and `page_html/home.html.heex` still exist beside
the layout footer.

## 9. Changelog

- 2026-09-07 v1: replaced the LS letter box with the Live list mark.
