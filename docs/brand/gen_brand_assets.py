#!/usr/bin/env python3
"""ListSignal brand assets, v1 ("Live list" mark).

Single source of truth for the mark geometry and every derived asset.
Run from anywhere:

    pip install cairosvg pillow
    python3 gen_brand_assets.py --out brand-pack

Writes a tree that mirrors the Phoenix repo layout:

    <out>/priv/static/images/brand/*.svg|png      the mark, tiles, lockups
    <out>/priv/static/favicon.* apple-touch-icon.png og-card.png site.webmanifest
    <out>/docs/brand/preview.png                  colourways at a glance

Fonts: Sora (display) and DM Sans (body) are the site's Google Fonts. The script
downloads them from github.com/google/fonts if they are not next to it; if that
fails it falls back to DejaVu Sans and says so.
"""
import argparse
import io
import json
import os
import shutil
import sys
import urllib.request

try:
    import cairosvg
    from PIL import Image, ImageDraw, ImageFont
except ImportError as e:  # pragma: no cover
    sys.exit(f"missing dependency: {e}. Run: pip install cairosvg pillow")

# ── Brand tokens ─────────────────────────────────────────────────────────────
# Keep these identical to assets/tailwind.config.js (accent / ls-dark).
ACCENT = "#10b981"   # tailwind `accent`   (emerald)
DARK = "#080e1e"     # tailwind `ls-dark`  (page background, also the "black" ink)
WHITE = "#ffffff"

# ── Mark geometry: 64-unit grid, one stroke weight (7), round caps/joins ──────
# Three equal lines; the middle one carries the beat. Do not edit ad hoc.
MARK_D = "M10 11H54M10 32H23L28 23L36 41L41 32H54M10 53H54"
STROKE = 7
TILE_RADIUS = 0.22        # corner radius as a fraction of the tile side
TILE_MARK_SCALE = 0.66    # mark size inside a tile (mark box = 64 units)
TINY_MARK_SCALE = 0.78    # 16px favicon: less padding so the stroke survives

FONT_URLS = {
    "Sora.ttf": "https://raw.githubusercontent.com/google/fonts/main/ofl/sora/Sora%5Bwght%5D.ttf",
    "DMSans.ttf": "https://raw.githubusercontent.com/google/fonts/main/ofl/dmsans/DMSans%5Bopsz%2Cwght%5D.ttf",
}


# ── SVG builders ─────────────────────────────────────────────────────────────
def mark_path(color):
    return (f'<path d="{MARK_D}" fill="none" stroke="{color}" stroke-width="{STROKE}" '
            f'stroke-linecap="round" stroke-linejoin="round"/>')


def mark_svg(color="currentColor"):
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64">'
            + mark_path(color) + "</svg>")


def tile_svg(bg, ink, scale=TILE_MARK_SCALE):
    off = (64 - 64 * scale) / 2
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64">'
            f'<rect width="64" height="64" rx="{64 * TILE_RADIUS:g}" fill="{bg}"/>'
            f'<g transform="translate({off:g} {off:g}) scale({scale})">{mark_path(ink)}</g></svg>')


def lockup_svg(text_color):
    """Tile + wordmark. Text uses the site's display font by name; the PNG twin
    is rendered with the real font file so it looks right anywhere."""
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 330 64" width="330" height="64">'
            f'<rect width="64" height="64" rx="{64 * TILE_RADIUS:g}" fill="{ACCENT}"/>'
            f'<g transform="translate(10.88 10.88) scale({TILE_MARK_SCALE})">{mark_path(WHITE)}</g>'
            f'<text x="82" y="46" font-family="Sora, \'DM Sans\', system-ui, sans-serif" font-weight="700" '
            f'font-size="42" letter-spacing="-1" fill="{text_color}">ListSignal</text></svg>')


# ── Raster helpers ───────────────────────────────────────────────────────────
def png_bytes(svg, size):
    return cairosvg.svg2png(bytestring=svg.encode(), output_width=size, output_height=size)


def png_image(svg, size):
    return Image.open(io.BytesIO(png_bytes(svg, size))).convert("RGBA")


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    mode = "wb" if isinstance(data, bytes) else "w"
    with open(path, mode) as f:
        f.write(data)


def load_font(name, size, variation):
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, name)
    if not os.path.exists(path):
        try:
            urllib.request.urlretrieve(FONT_URLS[name], path)
        except Exception as e:
            print(f"warning: could not fetch {name} ({e}); using DejaVu Sans", file=sys.stderr)
            return ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", size)
    font = ImageFont.truetype(path, size)
    try:
        font.set_variation_by_name(variation)
    except Exception:
        pass
    return font


def draw_tracked(draw, xy, text, font, fill, tracking):
    """PIL has no letter-spacing; draw glyph by glyph. Returns the end x."""
    x, y = xy
    for ch in text:
        draw.text((x, y), ch, font=font, fill=fill)
        x += font.getlength(ch) + tracking
    return x - tracking


def text_width(text, font, tracking):
    return sum(font.getlength(ch) for ch in text) + tracking * (len(text) - 1)


def lockup_png(text_color, tile_px=96, gap=22):
    """Transparent PNG: green tile + 'ListSignal' in Sora Bold, tracking-tight."""
    font = load_font("Sora.ttf", int(tile_px * 0.66), "Bold")
    tracking = -font.size * 0.025
    tw = text_width("ListSignal", font, tracking)
    ascent, descent = font.getmetrics()
    w = int(tile_px + gap + tw + 4)
    img = Image.new("RGBA", (w, tile_px), (0, 0, 0, 0))
    img.alpha_composite(png_image(tile_svg(ACCENT, WHITE), tile_px), (0, 0))
    d = ImageDraw.Draw(img)
    # Optical centre: cap-height sits visually centred on the tile.
    cap = font.getbbox("L")[3] - font.getbbox("L")[1]
    y = (tile_px - cap) / 2 - font.getbbox("L")[1]
    draw_tracked(d, (tile_px + gap, y), "ListSignal", font, text_color, tracking)
    return img


def og_card():
    """1200x630 share image: lockup + the site's title line, on ls-dark."""
    W, H = 1200, 630
    img = Image.new("RGBA", (W, H), DARK)
    d = ImageDraw.Draw(img)
    title = load_font("Sora.ttf", 112, "Bold")
    sub = load_font("DMSans.ttf", 38, "Regular")
    tracking = -title.size * 0.025
    tile_px, gap = 132, 34
    tw = text_width("ListSignal", title, tracking)
    total = tile_px + gap + tw
    x0 = (W - total) / 2
    y_tile = 205
    img.alpha_composite(png_image(tile_svg(ACCENT, WHITE), tile_px), (int(x0), y_tile))
    cap_box = title.getbbox("L")
    cap = cap_box[3] - cap_box[1]
    y_text = y_tile + (tile_px - cap) / 2 - cap_box[1]
    draw_tracked(d, (x0 + tile_px + gap, y_text), "ListSignal", title, WHITE, tracking)
    line = "Domain Intelligence, Checked in Real Time"
    lw = sub.getlength(line)
    d.text(((W - lw) / 2, y_tile + tile_px + 52), line, font=sub, fill=(255, 255, 255, 150))
    return img


def favicon_ico(path):
    sizes = [(48, TILE_MARK_SCALE), (32, TILE_MARK_SCALE), (16, TINY_MARK_SCALE)]
    frames = [png_image(tile_svg(ACCENT, WHITE, s), n) for n, s in sizes]
    try:
        frames[0].save(path, format="ICO", sizes=[(n, n) for n, _ in sizes], append_images=frames[1:])
    except TypeError:  # older Pillow: let it resample from the 48px frame
        frames[0].save(path, format="ICO", sizes=[(n, n) for n, _ in sizes])


def preview(brand_dir, out_path):
    """One image with the three colourways, both lockups and true-pixel favicons."""
    W, H = 1180, 560
    img = Image.new("RGBA", (W, H), "#3a404c")
    d = ImageDraw.Draw(img)
    label = load_font("DMSans.ttf", 15, "Medium")
    tiles = [("white on green", tile_svg(ACCENT, WHITE)),
             ("white on black", tile_svg(DARK, WHITE)),
             ("black on white", tile_svg(WHITE, DARK))]
    for i, (name, svg) in enumerate(tiles):
        x = 40 + i * 300
        img.alpha_composite(png_image(svg, 256), (x, 40))
        d.text((x, 306), name, font=label, fill="#cfd5e0")
    # true-pixel favicons, upscaled 4x nearest so you see what the tab shows
    fx = 940
    d.text((fx, 40), "favicon 16 / 32 / 48 (4x zoom)", font=label, fill="#cfd5e0")
    y = 70
    for n, s in [(16, TINY_MARK_SCALE), (32, TILE_MARK_SCALE), (48, TILE_MARK_SCALE)]:
        im = png_image(tile_svg(ACCENT, WHITE, s), n)
        im = im.resize((n * 4, n * 4), Image.NEAREST)
        img.alpha_composite(im, (fx, y))
        y += n * 4 + 14
    # lockups (rendered small enough to sit under the tiles, clear of the favicon column)
    d.rounded_rectangle((40, 350, 460, 520), 16, fill=DARK)
    img.alpha_composite(lockup_png(WHITE, tile_px=72, gap=16), (70, 399))
    d.rounded_rectangle((480, 350, 900, 520), 16, fill=WHITE)
    img.alpha_composite(lockup_png(DARK, tile_px=72, gap=16), (510, 399))
    img.convert("RGB").save(out_path)


# ── Main ─────────────────────────────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="brand-pack")
    args = ap.parse_args()
    out = args.out
    static = f"{out}/priv/static"
    brand = f"{static}/images/brand"
    docs = f"{out}/docs/brand"
    os.makedirs(brand, exist_ok=True)
    os.makedirs(docs, exist_ok=True)

    # 1. The mark on a transparent background (SVG + PNG)
    write(f"{brand}/mark.svg", mark_svg("currentColor"))          # inline / CSS-coloured
    for name, color in [("white", WHITE), ("black", DARK), ("green", ACCENT)]:
        write(f"{brand}/mark-{name}.svg", mark_svg(color))
        write(f"{brand}/mark-{name}-512.png", png_bytes(mark_svg(color), 512))

    # 2. Tiles (rounded square with the mark), three colourways
    for name, bg, ink, sizes in [("green", ACCENT, WHITE, (256, 512, 1024)),
                                 ("black", DARK, WHITE, (512,)),
                                 ("white", WHITE, DARK, (512,))]:
        svg = tile_svg(bg, ink)
        write(f"{brand}/tile-{name}.svg", svg)
        for n in sizes:
            write(f"{brand}/tile-{name}-{n}.png", png_bytes(svg, n))

    # 3. Lockups (tile + wordmark), for dark and light surfaces
    write(f"{brand}/lockup-on-dark.svg", lockup_svg(WHITE))
    write(f"{brand}/lockup-on-light.svg", lockup_svg(DARK))
    lockup_png(WHITE).save(f"{brand}/lockup-on-dark.png")
    lockup_png(DARK).save(f"{brand}/lockup-on-light.png")
    lockup_png(WHITE, tile_px=192, gap=44).save(f"{brand}/lockup-on-dark-2x.png")
    lockup_png(DARK, tile_px=192, gap=44).save(f"{brand}/lockup-on-light-2x.png")

    # 4. Favicons, touch icon, manifest icons, OG card (site root, as Phoenix serves them)
    write(f"{static}/favicon.svg", tile_svg(ACCENT, WHITE))
    write(f"{static}/favicon-16x16.png", png_bytes(tile_svg(ACCENT, WHITE, TINY_MARK_SCALE), 16))
    write(f"{static}/favicon-32x32.png", png_bytes(tile_svg(ACCENT, WHITE), 32))
    write(f"{static}/apple-touch-icon.png", png_bytes(tile_svg(ACCENT, WHITE), 180))
    write(f"{static}/icon-192.png", png_bytes(tile_svg(ACCENT, WHITE), 192))
    write(f"{static}/icon-512.png", png_bytes(tile_svg(ACCENT, WHITE), 512))
    favicon_ico(f"{static}/favicon.ico")
    og_card().convert("RGB").save(f"{static}/og-card.png", optimize=True)
    write(f"{static}/site.webmanifest", json.dumps({
        "name": "ListSignal",
        "short_name": "ListSignal",
        "start_url": "/",
        "display": "standalone",
        "background_color": DARK,
        "theme_color": DARK,
        "icons": [
            {"src": "/icon-192.png", "sizes": "192x192", "type": "image/png", "purpose": "any maskable"},
            {"src": "/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any maskable"},
        ],
    }, indent=2) + "\n")

    # 5. Preview sheet + a copy of this script next to it
    preview(brand, f"{docs}/preview.png")
    shutil.copy(os.path.abspath(__file__), f"{docs}/gen_brand_assets.py")
    print(f"ok: wrote {out}/")


if __name__ == "__main__":
    main()
