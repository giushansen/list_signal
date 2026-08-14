#!/usr/bin/env python3
"""
ListSignal — diverging-bar chart generator for social posts.
Reads TSVs in data/, emits self-contained HTML in out/, and writes out/render.sh
which screenshots each to a 2x PNG with headless Chrome.

Design follows the dataviz skill: diverging pair blue #2a78d6 (positive/lead) <->
red #e34948 (negative), neutral surface, rounded outer data-ends, one zero
baseline, direct value labels, text in ink tokens (not series color).

No third-party deps. Usage:  python3 make_charts.py  &&  bash out/render.sh
"""
import csv, os, pathlib

BASE = pathlib.Path(__file__).parent
DATA, OUT = BASE / "data", BASE / "out"
OUT.mkdir(exist_ok=True)

# palette (dataviz reference instance, light surface)
SURFACE   = "#fcfcfb"
INK       = "#0b0b0b"
INK2      = "#52514e"
MUTED     = "#898781"
BASELINE  = "#c3c2b7"
POS       = "#2a78d6"   # blue  — gains / Google
NEG       = "#e34948"   # red   — losses / Microsoft

NAMECOL, PLOT, PAD = 210, 620, 40   # px
HALF   = PLOT // 2
MAXBAR = HALF - 78                   # reserve room for value labels
ROW_H, GAP = 22, 12
WIDTH  = PAD + NAMECOL + PLOT + PAD

FONT = 'system-ui,-apple-system,"Segoe UI",sans-serif'


def read_rows(fname):
    with open(DATA / fname) as f:
        return [r for r in csv.reader(f, delimiter="\t") if r and r[0]]


def fmt(n):
    return f"{n:+,}".replace("+", "+").replace("-", "−")  # true minus glyph


def bar_row(name, val, maxabs, pos_color, neg_color, right_label, left_label):
    bw = round(abs(val) / maxabs * MAXBAR) if maxabs else 0
    if val >= 0:
        left, color = HALF, pos_color
        lbl = f'<span style="position:absolute;left:{HALF+bw+8}px;width:74px;text-align:left;' \
              f'line-height:{ROW_H}px;font-variant-numeric:tabular-nums;color:{INK2};font-size:13px">{right_label}</span>'
        bar = f'<div style="position:absolute;left:{left}px;width:{bw}px;height:{ROW_H}px;' \
              f'background:{color};border-radius:0 4px 4px 0"></div>'
    else:
        left, color = HALF - bw, neg_color
        lbl = f'<span style="position:absolute;left:{HALF-bw-8-74}px;width:74px;text-align:right;' \
              f'line-height:{ROW_H}px;font-variant-numeric:tabular-nums;color:{INK2};font-size:13px">{left_label}</span>'
        bar = f'<div style="position:absolute;left:{left}px;width:{bw}px;height:{ROW_H}px;' \
              f'background:{color};border-radius:4px 0 0 4px"></div>'
    return (
        f'<div style="display:flex;align-items:center;height:{ROW_H}px;margin-bottom:{GAP}px">'
        f'<div style="width:{NAMECOL}px;padding-right:14px;text-align:right;color:{INK};'
        f'font-size:13.5px;line-height:{ROW_H}px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">{name}</div>'
        f'<div style="position:relative;width:{PLOT}px;height:{ROW_H}px">{bar}{lbl}</div>'
        f'</div>'
    )


def page(title, subtitle, source, legend, rows_html, n_rows):
    plot_h = n_rows * (ROW_H + GAP)
    zero_x = NAMECOL + HALF
    height = 40 + 34 + 26 + 28 + plot_h + 40 + 40  # pad+title+sub+legend+plot+caption+pad
    body = f'''<div style="position:absolute;left:{PAD}px;top:0;width:{NAMECOL+PLOT}px">
  <div style="height:40px"></div>
  <div style="font:600 22px {FONT};color:{INK};letter-spacing:-.2px">{title}</div>
  <div style="font:400 14px {FONT};color:{INK2};margin-top:6px">{subtitle}</div>
  <div style="margin-top:16px;font:500 12.5px {FONT};color:{INK2}">{legend}</div>
  <div style="position:relative;margin-top:14px;height:{plot_h}px">
    <div style="position:absolute;left:{NAMECOL+HALF}px;top:-4px;width:2px;height:{plot_h+8}px;background:{BASELINE}"></div>
    {rows_html}
  </div>
  <div style="margin-top:20px;font:400 11.5px {FONT};color:{MUTED}">{source}</div>
</div>'''
    return (f'<!doctype html><html><head><meta charset="utf-8"><style>'
            f'*{{margin:0;box-sizing:border-box}}html,body{{background:{SURFACE}}}</style></head>'
            f'<body style="width:{WIDTH}px;height:{height}px;position:relative;font-family:{FONT}">'
            f'{body}</body></html>'), WIDTH, height


def swatch(color, label):
    return (f'<span style="display:inline-block;width:11px;height:11px;border-radius:3px;'
            f'background:{color};vertical-align:middle;margin:0 5px -1px 0"></span>{label}')


def build_net(fname, out, title, subtitle, source, up_word, down_word):
    rows = [(r[0], int(r[1])) for r in read_rows(fname)]
    maxabs = max(abs(v) for _, v in rows)
    html = "".join(bar_row(n, v, maxabs, POS, NEG, fmt(v), fmt(v)) for n, v in rows)
    legend = swatch(NEG, down_word) + '&nbsp;&nbsp;&nbsp;' + swatch(POS, up_word)
    doc, w, h = page(title, subtitle, source, legend, html, len(rows))
    (OUT / out).write_text(doc)
    return out, w, h


def build_share(fname, out, title, subtitle, source):
    rows = []
    for c, g, m in ((r[0], int(r[1]), int(r[2])) for r in read_rows(fname)):
        share = g / (g + m) * 100
        rows.append((c, share, g, m))
    rows.sort(key=lambda x: -x[1])
    html = ""
    for c, share, g, m in rows:
        dev = share - 50
        rlab = f"{share:.0f}%"          # Google leads -> right label = Google share
        llab = f"{100-share:.0f}%"      # Microsoft leads -> left label = MS share
        html += bar_row(c, dev, 50, POS, NEG, rlab, llab)
    legend = swatch(NEG, "Microsoft 365 leads") + '&nbsp;&nbsp;&nbsp;' + swatch(POS, "Google Workspace leads")
    doc, w, h = page(title, subtitle, source, legend, html, len(rows))
    (OUT / out).write_text(doc)
    return out, w, h


SRC_SIGNAL = "Source: ListSignal — 1.27M technology changes logged across 414,061 businesses, 4 Jun – 12 Aug 2026."
SRC_EMAIL  = "Source: ListSignal — MX records of ~8.7M live businesses (countries with 5k+), Aug 2026."

charts = [
    build_net("chart1_tech.tsv", "chart1_tech.html",
              "What the web is adopting — and ripping out",
              "Net change (installs minus removals) per technology, last ~10 weeks.",
              SRC_SIGNAL, "gaining", "losing"),
    build_net("chart2_apps.tsv", "chart2_apps.html",
              "Marketing & commerce apps: who's winning installs",
              "Net change (installs minus removals) per app, last ~10 weeks.",
              SRC_SIGNAL, "gaining", "losing"),
    build_share("chart3_email.tsv", "chart3_email.html",
                "Google vs Microsoft for business email, by country",
                "Share of businesses on each provider (of the two), by MX record.",
                SRC_EMAIL),
]

chrome = ('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
          if os.path.exists('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome')
          else 'google-chrome')
lines = ["#!/usr/bin/env bash", "set -e", f'CHROME="{chrome}"', f'cd "{OUT}"']
for name, w, h in charts:
    png = name.replace(".html", ".png")
    lines.append(
        f'"$CHROME" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=2 '
        f'--default-background-color=FFFFFFFF --window-size={w},{h} '
        f'--screenshot="{OUT/png}" "file://{OUT/name}" >/dev/null 2>&1 && echo "  {png}"')
(OUT / "render.sh").write_text("\n".join(lines) + "\n")
print("wrote", len(charts), "charts + render.sh to", OUT)
