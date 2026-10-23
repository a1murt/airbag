#!/usr/bin/env python3
"""Builds docs/images/demo.gif, the README hero: an agent deletes a folder, Airbag brings it back in one click.

usage: Scripts/make-demo-gif.py PREVIEWS_DIR [OUT]
PREVIEWS_DIR holds the English light previews (`Airbag --render-previews DIR -AppleLanguages "(en)"`).
Needs Pillow."""
import os, sys
from PIL import Image, ImageDraw, ImageFont

PREVIEWS = sys.argv[1]
OUT = sys.argv[2] if len(sys.argv) > 2 else 'docs/images/demo.gif'
W, H = 1200, 750          # drawn at this size, saved at half for a light GIF
FINAL = (960, 600)
MONO = ImageFont.truetype('/System/Library/Fonts/SFNSMono.ttf', 26)
MONO_B = ImageFont.truetype('/System/Library/Fonts/SFNSMono.ttf', 26)
SANS = ImageFont.truetype('/System/Library/Fonts/SFNS.ttf', 34)
SANS_S = ImageFont.truetype('/System/Library/Fonts/SFNS.ttf', 24)
TITLE = ImageFont.truetype('/System/Library/Fonts/SFNS.ttf', 56)

BG = (246, 246, 248)
INK = (29, 29, 31)
ACCENT = (40, 110, 245)
TERM = (30, 30, 34)
TERM_TEXT = (228, 228, 232)
DIM = (140, 140, 150)
GREEN = (80, 200, 120)
RED = (255, 105, 97)
ORANGE = (255, 159, 67)


def canvas():
    return Image.new('RGB', (W, H), BG)


def caption(img, text, sub=None):
    d = ImageDraw.Draw(img)
    d.rectangle([0, H - 110, W, H], fill=(255, 255, 255))
    d.line([0, H - 110, W, H - 110], fill=(225, 225, 230), width=2)
    tw = d.textlength(text, font=SANS)
    d.text(((W - tw) / 2, H - 92 if sub else H - 76), text, font=SANS, fill=INK)
    if sub:
        sw = d.textlength(sub, font=SANS_S)
        d.text(((W - sw) / 2, H - 48), sub, font=SANS_S, fill=DIM)


def window(img, box, title, dark=True):
    d = ImageDraw.Draw(img)
    x0, y0, x1, y1 = box
    d.rounded_rectangle([x0 + 6, y0 + 10, x1 + 6, y1 + 10], radius=18, fill=(215, 215, 222))  # shadow
    d.rounded_rectangle(box, radius=18, fill=TERM if dark else (255, 255, 255))
    for i, c in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
        d.ellipse([x0 + 22 + i * 26, y0 + 20, x0 + 38 + i * 26, y0 + 36], fill=c)
    tw = d.textlength(title, font=SANS_S)
    d.text(((x0 + x1 - tw) / 2, y0 + 14), title, font=SANS_S, fill=DIM)


TERM_BOX = (90, 50, W - 90, H - 150)


def terminal(lines, cap, sub=None, cursor=True):
    img = canvas()
    window(img, TERM_BOX, 'shop-app — agent')
    d = ImageDraw.Draw(img)
    y = TERM_BOX[1] + 70
    for parts in lines:
        x = TERM_BOX[0] + 34
        for text, color in parts:
            d.text((x, y), text, font=MONO, fill=color)
            x += d.textlength(text, font=MONO)
        y += 44
    if cursor:
        d.rectangle([TERM_BOX[0] + 34, y + 4, TERM_BOX[0] + 48, y + 32], fill=TERM_TEXT)
    caption(img, cap, sub)
    return img


def screenshot(name, crop, cap, sub=None, highlight=None, cursor_at=None, pressed=False):
    """A crop of a light preview inside a window frame; highlight/cursor in crop coordinates."""
    shot = Image.open(os.path.join(PREVIEWS, name)).convert('RGB').crop(crop)
    box_w, box_h = W - 180, H - 210
    scale = min(box_w / shot.width, box_h / shot.height)
    shot = shot.resize((int(shot.width * scale), int(shot.height * scale)), Image.LANCZOS)
    img = canvas()
    x0 = (W - shot.width) // 2
    y0 = 50 + 46
    window(img, (x0, 50, x0 + shot.width, y0 + shot.height + 6), 'Airbag', dark=False)
    img.paste(shot, (x0, y0))
    d = ImageDraw.Draw(img)
    if highlight:
        hx0, hy0, hx1, hy1 = [v * scale for v in highlight]
        d.rounded_rectangle([x0 + hx0 - 6, y0 + hy0 - 6, x0 + hx1 + 6, y0 + hy1 + 6], radius=16, outline=ACCENT, width=5)
    if cursor_at:
        cx, cy = x0 + cursor_at[0] * scale, y0 + cursor_at[1] * scale
        if pressed:
            d.ellipse([cx - 26, cy - 26, cx + 26, cy + 26], outline=ACCENT, width=4)
        arrow = [(cx, cy), (cx, cy + 40), (cx + 11, cy + 30), (cx + 20, cy + 48), (cx + 27, cy + 45), (cx + 18, cy + 27), (cx + 32, cy + 27)]
        d.polygon(arrow, fill=(0, 0, 0), outline=(255, 255, 255))
    caption(img, cap, sub)
    return img


def end_card():
    img = canvas()
    d = ImageDraw.Draw(img)
    icon = Image.open('Resources/AppIcon-1024.png').convert('RGBA').resize((190, 190), Image.LANCZOS)
    img.paste(icon, ((W - 190) // 2, 150), icon)
    for text, font, color, y in [('Airbag', TITLE, INK, 370), ('Undo for AI coding agents', SANS, INK, 450),
                                 ('Free · Open source · Native macOS', SANS_S, DIM, 510)]:
        tw = d.textlength(text, font=font)
        d.text(((W - tw) / 2, y), text, font=font, fill=color)
    return img


P = ('> ', DIM)
frames = []  # (image, milliseconds)
prompt = [P, ('clean up the old checkout code', TERM_TEXT)]
bash = [('● ', GREEN), ('Bash', TERM_TEXT), ('(rm -rf src/legacy)', DIM)]
done = [('  └  ', DIM), ('(no output)', DIM)]
reply = [('● ', TERM_TEXT), ('Done — removed the legacy checkout folder.', TERM_TEXT)]
ls = [('$ ', DIM), ('ls src/legacy', TERM_TEXT)]
gone = [('ls: src/legacy: No such file or directory', RED)]

typed = 'clean up the old checkout code'
for n in (8, 16, 24, len(typed)):
    frames.append((terminal([[P, (typed[:n], TERM_TEXT)]], 'Your agent runs on autopilot…'), 160))
frames.append((terminal([prompt], 'Your agent runs on autopilot…'), 500))
frames.append((terminal([prompt, bash], 'Your agent runs on autopilot…'), 700))
frames.append((terminal([prompt, bash, done, reply], '…and deletes the wrong folder.'), 1500))
frames.append((terminal([prompt, bash, done, reply, [], ls], '…and deletes the wrong folder.'), 600))
frames.append((terminal([prompt, bash, done, reply, [], ls, gone], 'Uncommitted work. Not in git.', None, False), 1900))

# "Before `rm -rf src/legacy`" card in the 2080×1360 timeline preview.
TL = (370, 0, 2080, 960)                      # cards and toolbar, no sidebar
CARD = (409 - 370, 824, 2054 - 370, 929)
frames.append((screenshot('main-timeline-light.png', TL, 'Airbag took a snapshot right before it.', highlight=CARD), 1700))
frames.append((screenshot('main-timeline-light.png', TL, 'Airbag took a snapshot right before it.', highlight=CARD,
                          cursor_at=(760 - 370, 868)), 900))
frames.append((screenshot('restore-light.png', (0, 60, 1040, 960), 'One click.', cursor_at=(935, 845)), 1100))
frames.append((screenshot('restore-light.png', (0, 60, 1040, 960), 'One click.', cursor_at=(935, 845), pressed=True), 450))
back = [('cart.ts   checkout.ts', GREEN)]
frames.append((terminal([prompt, bash, done, reply, [], ls, back], "It's all back.", 'Including .env and files git never saw.'), 2300))
frames.append((end_card(), 2400))

images = [f.resize(FINAL, Image.LANCZOS).convert('P', palette=Image.ADAPTIVE, colors=255) for f, _ in frames]
os.makedirs(os.path.dirname(OUT) or '.', exist_ok=True)
images[0].save(OUT, save_all=True, append_images=images[1:], duration=[ms for _, ms in frames], loop=0, optimize=True, disposal=1)
print(f'wrote {OUT}: {len(images)} frames, {sum(ms for _, ms in frames) / 1000:.1f} s, {os.path.getsize(OUT) // 1024} KB')
