"""Generate the Frisket Plum Nib desktop and web icon set.

The vellum F ends in a fountain-pen point on a plum background.
The same geometry is written as SVG and drawn at 1024px for raster icons.
Run:  python tools/make_icon.py
"""
import io
import os
import json
from PIL import Image, ImageDraw

S = 1024          # working resolution
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "assets")

INK_TOP = (100, 72, 103)
INK_BOTTOM = (48, 43, 71)
PAPER = (249, 242, 228)
NIB_CUT = (80, 60, 86)
WEB_DIR = os.path.join(OUT, "web")


def rounded_mask(size, radius):
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return mask


def vertical_gradient(size, top, bottom):
    grad = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / (size - 1)
        grad.putpixel((0, y), tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return grad.resize((size, size))


def build(size=S):
    icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    body = vertical_gradient(S, INK_TOP, INK_BOTTOM).convert("RGBA")
    icon.paste(body, (0, 0), rounded_mask(S, 225))
    d = ImageDraw.Draw(icon)

    d.polygon([(296, 214), (416, 214), (416, 681), (356, 824), (296, 681)], fill=PAPER)
    d.rounded_rectangle((296, 214, 726, 312), radius=18, fill=PAPER)
    d.rounded_rectangle((296, 421, 621, 519), radius=18, fill=PAPER)
    d.ellipse((329, 589, 383, 643), fill=NIB_CUT)
    d.polygon([(345, 623), (367, 623), (359, 812), (353, 812)], fill=NIB_CUT)
    return icon if size == S else icon.resize((size, size), Image.LANCZOS)


def svg_mark():
    """Vector source for the website favicon and future brand work."""
    return '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" role="img" aria-labelledby="title">
  <title id="title">Frisket — Plum Nib</title>
  <defs>
    <linearGradient id="plum" x1="0" y1="0" x2="0" y2="1">
      <stop stop-color="#644867"/>
      <stop offset="1" stop-color="#302b47"/>
    </linearGradient>
  </defs>
  <rect width="1024" height="1024" rx="225" fill="url(#plum)"/>
  <path d="M296 214H416V681L356 824 296 681Z" fill="#f9f2e4"/>
  <rect x="296" y="214" width="430" height="98" rx="18" fill="#f9f2e4"/>
  <rect x="296" y="421" width="325" height="98" rx="18" fill="#f9f2e4"/>
  <circle cx="356" cy="616" r="27" fill="#503c56"/>
  <path d="M345 623H367L359 812H353Z" fill="#503c56"/>
</svg>
'''


def build_web_assets(master):
    os.makedirs(WEB_DIR, exist_ok=True)
    os.makedirs(os.path.join(OUT, "brand-concepts"), exist_ok=True)
    with open(os.path.join(OUT, "icon.svg"), "w", encoding="utf8") as handle:
        handle.write(svg_mark())
    with open(os.path.join(WEB_DIR, "favicon.svg"), "w", encoding="utf8") as handle:
        handle.write(svg_mark())
    with open(os.path.join(OUT, "brand-concepts", "05-plum-nib.svg"), "w", encoding="utf8") as handle:
        handle.write(svg_mark())
    master.resize((256, 256), Image.LANCZOS).save(
        os.path.join(WEB_DIR, "favicon.ico"), format="ICO",
        sizes=[(16, 16), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
    )
    for filename, px in [("favicon-16.png", 16), ("favicon-32.png", 32),
                         ("icon-192.png", 192),
                         ("icon-512.png", 512)]:
        master.resize((px, px), Image.LANCZOS).save(os.path.join(WEB_DIR, filename))
    touch = Image.new("RGBA", (S, S), INK_BOTTOM + (255,))
    touch.alpha_composite(master)
    touch.resize((180, 180), Image.LANCZOS).convert("RGB").save(
        os.path.join(WEB_DIR, "apple-touch-icon.png"))
    manifest = {
        "name": "Frisket Markdown Editor",
        "short_name": "Frisket",
        "icons": [
            {"src": "icon-192.png", "sizes": "192x192", "type": "image/png"},
            {"src": "icon-512.png", "sizes": "512x512", "type": "image/png"},
        ],
        "theme_color": "#302b47",
        "background_color": "#f9f2e4",
        "display": "standalone",
    }
    with open(os.path.join(WEB_DIR, "site.webmanifest"), "w", encoding="utf8") as handle:
        json.dump(manifest, handle, indent=2)
        handle.write("\n")
    print("wrote web favicons to", WEB_DIR)


def main():
    os.makedirs(OUT, exist_ok=True)
    master = build(S)

    png = master.resize((512, 512), Image.LANCZOS)
    png.save(os.path.join(OUT, "icon.png"))

    sizes = [16, 24, 32, 48, 64, 128, 256]
    master.resize((256, 256), Image.LANCZOS).save(
        os.path.join(OUT, "icon.ico"),
        format="ICO",
        sizes=[(s, s) for s in sizes],
    )

    for s in (32, 256):
        master.resize((s, s), Image.LANCZOS).save(os.path.join(OUT, f"icon-{s}.png"))

    print("wrote", OUT)
    build_web_assets(master)
    build_appx_assets()
    build_icns()




# ---------------------------------------------------------------------------
# Microsoft Store (MSIX) tile assets.
# electron-builder reads these from <buildResources>/appx.
# ---------------------------------------------------------------------------
APPX_DIR = os.path.join(OUT, "appx")

# name -> (width, height). Sizes fixed by the MSIX packaging schema.
APPX_ASSETS = {
    "Square44x44Logo.png": (44, 44),
    "Square71x71Logo.png": (71, 71),
    "Square150x150Logo.png": (150, 150),
    "Square310x310Logo.png": (310, 310),
    "StoreLogo.png": (50, 50),
    "Wide310x150Logo.png": (310, 150),
    "SplashScreen.png": (620, 300),
}

# Wide tiles and the splash screen get the mark plus a wordmark, so they read
# as branding rather than a stretched icon.
WORDMARK_CANDIDATES = [
    r"C:\Windows\Fonts\georgiab.ttf",
    r"C:\Windows\Fonts\pala.ttf",
    r"C:\Windows\Fonts\times.ttf",
    r"C:\Windows\Fonts\segoeui.ttf",
]


def load_font(size):
    from PIL import ImageFont
    for path in WORDMARK_CANDIDATES:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except Exception:
                continue
    return None


def wide_tile(master, width, height):
    """Mark on the left, wordmark to its right, on the brand gradient."""
    from PIL import ImageDraw
    tile = vertical_gradient(max(width, height), INK_TOP, INK_BOTTOM).convert("RGBA")
    tile = tile.resize((width, height))

    mark_size = int(height * 0.62)
    mark = master.resize((mark_size, mark_size), Image.LANCZOS)

    font = load_font(int(height * 0.30))
    text = "Frisket"
    text_w = 0
    if font:
        draw = ImageDraw.Draw(tile)
        box = draw.textbbox((0, 0), text, font=font)
        text_w = box[2] - box[0]

    gap = int(height * 0.10)
    total = mark_size + (gap + text_w if font else 0)
    x = (width - total) // 2
    y = (height - mark_size) // 2

    tile.paste(mark, (x, y), mark)

    if font:
        draw = ImageDraw.Draw(tile)
        box = draw.textbbox((0, 0), text, font=font)
        ty = (height - (box[3] - box[1])) // 2 - box[1]
        draw.text((x + mark_size + gap, ty), text, font=font, fill=PAPER + (255,))
    return tile


def build_appx_assets():
    os.makedirs(APPX_DIR, exist_ok=True)
    master = build(S)
    for name, (w, h) in APPX_ASSETS.items():
        if w != h:
            img = wide_tile(master, w, h)
        else:
            img = master.resize((w, h), Image.LANCZOS)
        img.save(os.path.join(APPX_DIR, name))
    print("wrote %d Store tile assets to %s" % (len(APPX_ASSETS), APPX_DIR))




# ---------------------------------------------------------------------------
# macOS .icns
#
# The format is a simple container: an 'icns' header followed by typed chunks.
# Modern OS X accepts PNG payloads for every type used below, so no Apple
# tooling is needed and this can be generated on any platform.
# ---------------------------------------------------------------------------
import struct

# chunk type -> pixel size. The ic11..ic14 types are the @2x retina variants.
ICNS_TYPES = [
    (b"icp4", 16),
    (b"icp5", 32),
    (b"icp6", 64),
    (b"ic07", 128),
    (b"ic08", 256),
    (b"ic09", 512),
    (b"ic10", 1024),
    (b"ic11", 32),
    (b"ic12", 64),
    (b"ic13", 256),
    (b"ic14", 512),
]

# macOS icons are expected to sit inside their canvas with a margin, unlike
# Windows icons which run edge to edge.
MAC_INSET = 0.10


def mac_master(size=S):
    """The Windows artwork, inset on a transparent canvas for macOS."""
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    inner = int(size * (1 - 2 * MAC_INSET))
    art = build(S).resize((inner, inner), Image.LANCZOS)
    offset = (size - inner) // 2
    canvas.paste(art, (offset, offset), art)
    return canvas


def build_icns():
    master = mac_master(1024)
    chunks = []
    for kind, px in ICNS_TYPES:
        buf = io.BytesIO()
        master.resize((px, px), Image.LANCZOS).save(buf, format="PNG")
        data = buf.getvalue()
        chunks.append(kind + struct.pack(">I", len(data) + 8) + data)

    body = b"".join(chunks)
    icns = b"icns" + struct.pack(">I", len(body) + 8) + body

    target = os.path.join(OUT, "icon.icns")
    with open(target, "wb") as fh:
        fh.write(icns)

    # electron-builder also likes a plain 512 PNG for the DMG background/volume.
    master.resize((512, 512), Image.LANCZOS).save(os.path.join(OUT, "icon-mac.png"))
    print("wrote %s (%d chunks, %.1f KB)" % (target, len(chunks), len(icns) / 1024))


if __name__ == "__main__":
    main()
