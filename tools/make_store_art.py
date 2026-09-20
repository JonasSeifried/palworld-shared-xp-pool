"""Store art for Shared XP Pool.

The picture is the rule: four players earn different amounts, and all four end
up on the same line. Nothing here is taken from the game -- shapes and type
only -- so it is safe to upload anywhere.
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


render(512, 512, sys.argv[1] + "/thumbnail-512.png",
       title_px=42, sub_px=21, tag_px=15, bar_w=54, gap=30, tracking=3)
render(1280, 720, sys.argv[1] + "/banner-1280x720.png",
       title_px=82, sub_px=36, tag_px=22, bar_w=88, gap=136, tracking=7)
