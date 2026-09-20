"""Store art for Shared XP Pool.

    python tools/make_store_art.py mod      (needs Pillow)

The picture is the rule: four players earn different amounts, and all four end
up on the same line. Four because that is MaxPlayerNum on a hosted world.

Nothing here is taken from the game -- shapes and type only -- so it is safe to
upload anywhere. Kept in the repo because both stores want the art again every
time the pages are touched, and redrawing it by hand would not match.
"""
import sys
from PIL import Image, ImageDraw, ImageFont

BG       = (13, 17, 26)
BG_GLOW  = (22, 30, 47)
TRACK    = (30, 37, 52)
EARNED   = (43, 108, 176)
GRANTED  = (99, 179, 237)
LINE     = (246, 173, 85)
TEXT     = (237, 242, 247)
MUTED    = (139, 152, 173)

BOLD = "C:/Windows/Fonts/segoeuib.ttf"
REG  = "C:/Windows/Fonts/segoeui.ttf"

# What each player earned, as a fraction of the leader.
EARNED_FRACTIONS = [1.00, 0.34, 0.62, 0.18]


def spaced(draw, xy, text, font, fill, tracking, anchor_center_x=None):
    widths = [draw.textlength(c, font=font) for c in text]
    total = sum(widths) + tracking * (len(text) - 1)
    x = (anchor_center_x - total / 2) if anchor_center_x is not None else xy[0]
    y = xy[1]
    for c, w in zip(text, widths):
        draw.text((x, y), c, font=font, fill=fill)
        x += w + tracking
    return total


def fit(text, target_w, font_path, tracking):
    """Largest size at which `text` fits `target_w`, tracking included."""
    lo, hi = 8, 400
    while lo < hi:
        mid = (lo + hi + 1) // 2
        f = ImageFont.truetype(font_path, mid)
        d = ImageDraw.Draw(Image.new("RGB", (1, 1)))
        w = sum(d.textlength(c, font=f) for c in text) + tracking * (len(text) - 1)
        if w <= target_w:
            lo = mid
        else:
            hi = mid - 1
    return ImageFont.truetype(font_path, lo)


def render_wordmark(w, h, path, tracking):
    """Type only.

    The thumbnail is shown at about a hundred pixels in a store grid, where
    four bars and a level line turn to mud. A name that can be read at that
    size does more work than a picture that cannot.
    """
    img = Image.new("RGB", (w, h), BG)
    d = ImageDraw.Draw(img)

    for i in range(24):
        t = i / 24
        d.ellipse(
            [w * 0.5 - w * (0.75 - t * 0.3), h * 0.5 - h * (0.6 - t * 0.25),
             w * 0.5 + w * (0.75 - t * 0.3), h * 0.5 + h * (0.6 - t * 0.25)],
            fill=tuple(int(BG[k] + (BG_GLOW[k] - BG[k]) * t) for k in range(3)),
        )

    inner = w * 0.84
    lines = ["SHARED", "XP POOL"]
    fonts = [fit(t, inner, BOLD, tracking) for t in lines]
    heights = [f.getbbox("H")[3] - f.getbbox("H")[1] for f in fonts]

    line_gap = h * 0.045
    rule_gap = h * 0.075
    sub_gap = h * 0.055
    sub_f = ImageFont.truetype(REG, int(h * 0.054))
    sub_h = sub_f.getbbox("Hy")[3] - sub_f.getbbox("Hy")[1]

    # Everything measured first, then placed, so the block sits optically
    # centred rather than wherever the first line happened to start.
    total = sum(heights) + line_gap * (len(lines) - 1) + rule_gap + sub_gap + sub_h
    y = (h - total) / 2 * 0.92

    for i, (text, f, hh) in enumerate(zip(lines, fonts, heights)):
        spaced(d, (0, y - f.getbbox("H")[1]), text, f, TEXT, tracking, anchor_center_x=w / 2)
        y += hh + (line_gap if i < len(lines) - 1 else 0)

    rule_y = y + rule_gap
    d.line([w * 0.32, rule_y, w * 0.68, rule_y], fill=LINE, width=max(2, int(h / 150)))

    d.text((w / 2, rule_y + sub_gap), "everyone stays the same level",
           font=sub_f, fill=MUTED, anchor="ma")

    img.save(path)
    print(f"{path}  {w}x{h}")


def render(w, h, path, title_px, sub_px, tag_px, bar_w, gap, tracking):
    img = Image.new("RGB", (w, h), BG)
    d = ImageDraw.Draw(img)

    # A soft vignette, so the bars sit on something rather than float.
    for i in range(24):
        t = i / 24
        d.ellipse(
            [w * 0.5 - w * (0.75 - t * 0.3), h * 0.62 - h * (0.55 - t * 0.22),
             w * 0.5 + w * (0.75 - t * 0.3), h * 0.62 + h * (0.55 - t * 0.22)],
            fill=tuple(int(BG[k] + (BG_GLOW[k] - BG[k]) * t) for k in range(3)),
        )

    title_f = ImageFont.truetype(BOLD, title_px)
    sub_f   = ImageFont.truetype(REG, sub_px)
    tag_f   = ImageFont.truetype(BOLD, tag_px)

    top = int(h * 0.10)
    spaced(d, (0, top), "SHARED XP POOL", title_f, TEXT, tracking, anchor_center_x=w / 2)
    sub_y = top + title_px + int(h * 0.025)
    d.text((w / 2, sub_y), "everyone stays the same level",
           font=sub_f, fill=MUTED, anchor="ma")

    n = len(EARNED_FRACTIONS)
    span = n * bar_w + (n - 1) * gap
    x0 = (w - span) / 2
    base = int(h * 0.80)
    level_y = int(h * 0.40)
    full = base - level_y
    radius = bar_w // 2

    # The shared level, drawn behind the bars and overhanging them.
    d.line([x0 - bar_w * 0.55, level_y, x0 + span + bar_w * 0.55, level_y],
           fill=LINE, width=max(2, bar_w // 18))

    for i, frac in enumerate(EARNED_FRACTIONS):
        bx = int(x0 + i * (bar_w + gap))
        eh = int(full * frac)

        # Painted through a rounded mask, so the boundary between what a
        # player earned and what the pool paid is a flat fill line rather than
        # another rounded cap floating inside the bar.
        bar = Image.new("RGB", (bar_w, full), GRANTED)
        ImageDraw.Draw(bar).rectangle([0, full - eh, bar_w, full], fill=EARNED)

        mask = Image.new("L", (bar_w, full), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, bar_w - 1, full - 1],
                                              radius=radius, fill=255)
        img.paste(bar, (bx, level_y), mask)

    # Caps on the level line, so it reads as a level and not a divider.
    cap = max(3, bar_w // 9)
    for x in (x0 - bar_w * 0.55, x0 + span + bar_w * 0.55):
        d.ellipse([x - cap, level_y - cap, x + cap, level_y + cap], fill=LINE)

    d.text((w / 2, int(h * 0.885)), "CO-OP  ·  HOST ONLY", font=tag_f, fill=MUTED, anchor="ma")

    img.save(path)
    print(f"{path}  {w}x{h}")


render_wordmark(512, 512, sys.argv[1] + "/thumbnail-512.png", tracking=4)
render(1280, 720, sys.argv[1] + "/banner-1280x720.png",
       title_px=82, sub_px=36, tag_px=22, bar_w=88, gap=136, tracking=7)
