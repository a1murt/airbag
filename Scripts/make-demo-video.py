#!/usr/bin/env python3
"""Renders the README demo video: an agent deletes a folder at 2:07 a.m., one click in Airbag's menu brings it back.

usage: Scripts/make-demo-video.py DEMO_SCREENS_DIR OUT_DIR
DEMO_SCREENS_DIR comes from `Airbag --render-demo DIR -AppleLanguages "(en)"` (the app's real screens).
Writes OUT_DIR/frames/*.jpg (1920x1080, 30 fps, for Scripts/encode-video.swift) and OUT_DIR/demo.gif.
Needs Pillow."""
import math, os, shutil, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

SCREENS, OUT = sys.argv[1], sys.argv[2]
W, H, FPS = 1920, 1080, 30
FRAMES = os.path.join(OUT, 'frames')
shutil.rmtree(FRAMES, ignore_errors=True)
os.makedirs(FRAMES)

F = '/System/Library/Fonts/'
SANS = lambda s: ImageFont.truetype(F + 'SFNS.ttf', s)
MONO = ImageFont.truetype(F + 'SFNSMono.ttf', 22)
MENU, MENU_B, CAP, TITLE, SMALL = SANS(17), SANS(17), SANS(34), SANS(64), SANS(26)
WIN_TITLE = SANS(16)

INK, DIM_INK = (29, 29, 31), (110, 110, 118)
TERM_BG, TERM_INK, TERM_DIM = (28, 28, 32), (230, 230, 235), (128, 128, 138)
GREEN, RED, ORANGE, BLUE = (93, 205, 125), (255, 107, 99), (255, 170, 80), (10, 132, 255)


def ease(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


def lerp(a, b, t):
    return a + (b - a) * t


# ---------- static layers ----------

def wallpaper():
    top, bottom = (58, 72, 140), (196, 120, 160)
    g = Image.new('RGB', (1, H))
    for y in range(H):
        t = y / H
        g.putpixel((0, y), tuple(int(lerp(top[i], bottom[i], t)) for i in range(3)))
    img = g.resize((W, H))
    glow = Image.new('RGB', (W, H), (255, 190, 140))
    mask = Image.new('L', (W, H), 0)
    ImageDraw.Draw(mask).ellipse([W * 0.45, H * 0.35, W * 1.25, H * 1.3], fill=120)
    return Image.composite(glow, img, mask.filter(ImageFilter.GaussianBlur(220)))


def shield(d, x, y, s, color):
    pts = [(x, y), (x + s * 0.5, y - s * 0.18), (x + s, y), (x + s, y + s * 0.5), (x + s * 0.5, y + s * 1.05), (x, y + s * 0.5)]
    d.polygon(pts, fill=color)


ICON_X, ICON_Y = 1622, 17          # Airbag's menu bar item


def menubar(img):
    bar = Image.new('RGBA', (W, 34), (245, 245, 248, 205))
    img.paste(bar, (0, 0), bar)
    d = ImageDraw.Draw(img)
    x = 22
    d.text((x, 7), '', font=SANS(19), fill=INK)
    x += 36
    for i, item in enumerate(['Terminal', 'Shell', 'Edit', 'View', 'Window', 'Help']):
        d.text((x, 8), item, font=MENU_B if i == 0 else MENU, fill=INK)
        x += d.textlength(item, font=MENU) + 26
    shield(d, ICON_X - 8, ICON_Y - 8, 16, INK)
    for r in (13, 8, 3):                                  # Wi-Fi
        d.arc([1672 - r, 25 - r, 1672 + r, 25 + r], start=225, end=315, fill=INK, width=3)
    d.rounded_rectangle([1700, 11, 1728, 23], radius=3, outline=INK, width=2)
    d.rectangle([1703, 14, 1722, 20], fill=INK)
    d.text((1752, 8), 'Thu 23 Oct  2:07 AM', font=MENU, fill=INK)


def rounded(img, r):
    mask = Image.new('L', img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, img.width - 1, img.height - 1], radius=r, fill=255)
    out = img.convert('RGBA')
    out.putalpha(mask)
    return out


def shadow_for(size, r, blur=28, alpha=110):
    w, h = size
    pad = blur * 3
    s = Image.new('RGBA', (w + pad * 2, h + pad * 2), (0, 0, 0, 0))
    ImageDraw.Draw(s).rounded_rectangle([pad, pad + 14, pad + w, pad + h + 14], radius=r, fill=(0, 0, 0, alpha))
    return s.filter(ImageFilter.GaussianBlur(blur)), pad


def chrome(content, title, dark=False):
    """A window: title bar with traffic lights on top of `content` (RGB), rounded and with its shadow."""
    bar_h = 38
    win = Image.new('RGB', (content.width, content.height + bar_h), TERM_BG if dark else (236, 236, 238))
    d = ImageDraw.Draw(win)
    for i, c in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
        d.ellipse([16 + i * 22, 13, 28 + i * 22, 25], fill=c)
    tw = d.textlength(title, font=WIN_TITLE)
    d.text(((win.width - tw) / 2, 10), title, font=WIN_TITLE, fill=TERM_DIM if dark else DIM_INK)
    win.paste(content, (0, bar_h))
    win = rounded(win, 14)
    sh, pad = shadow_for(win.size, 14)
    return win, sh, pad


def place(frame, layer, x, y, alpha=1.0, scale=1.0):
    win, sh, pad = layer
    if scale != 1.0:
        win = win.resize((int(win.width * scale), int(win.height * scale)), Image.LANCZOS)
        sh = sh.resize((int(sh.width * scale), int(sh.height * scale)), Image.LANCZOS)
        pad = int(pad * scale)
        x += (layer[0].width - win.width) / 2
        y += (layer[0].height - win.height) / 2
    if alpha < 1.0:
        win = win.copy(); sh = sh.copy()
        win.putalpha(win.getchannel('A').point(lambda v: int(v * alpha)))
        sh.putalpha(sh.getchannel('A').point(lambda v: int(v * alpha)))
    frame.paste(sh, (int(x - pad), int(y - pad)), sh)
    frame.paste(win, (int(x), int(y)), win)


def screen(name, crop, width):
    img = Image.open(os.path.join(SCREENS, name)).convert('RGB')
    if crop:
        img = img.crop(crop)
    return img.resize((width, int(img.height * width / img.width)), Image.LANCZOS)


BASE = wallpaper()

# The app's real screens: the popover before and after Undo (rendered by `Airbag --render-demo`).
# Points of interest are given in the 2x PNG's pixels (380 pt wide = 760 px) and scaled with the popover.
POP_W = 494                       # 1.3x the real 380 pt so it stays legible in the GIF
POP_PX = 760


def popover_layer(name):
    img = rounded(screen(name, None, POP_W), 14)
    sh, pad = shadow_for(img.size, 14, blur=20, alpha=90)
    return (img, sh, pad)


popover = popover_layer('popover-light.png')
popover_undone = popover_layer('popover-undone-light.png')
POP_X, POP_Y = ICON_X - POP_W // 2, 40
pp = lambda x, y: (POP_X + x * POP_W / POP_PX, POP_Y + y * POP_W / POP_PX)
UNDO_PX = tuple(float(v) for v in os.environ.get('UNDO_PX', '690,222').split(','))            # Undo in "Recent changes"
RECENT_PX = tuple(float(v) for v in os.environ.get('RECENT_PX', '14,184,746,262').split(','))  # that row
UNDO = pp(*UNDO_PX)
RECENT_ROW = (*pp(RECENT_PX[0], RECENT_PX[1]), *pp(RECENT_PX[2], RECENT_PX[3]))

icon = Image.open('Resources/AppIcon-1024.png').convert('RGBA')

# ---------- terminal windows ----------

AGENT = (150, 120, 900, 540)     # x, y, w, h
SHELL = (1000, 600, 720, 300)


def terminal(lines, w, h, title, caret=None):
    body = Image.new('RGB', (w, h), TERM_BG)
    d = ImageDraw.Draw(body)
    y = 22
    last_x = 26
    for parts in lines:
        x = 26
        for text, color in parts:
            d.text((x, y), text, font=MONO, fill=color)
            x += d.textlength(text, font=MONO)
        last_x, last_y = x, y
        y += 36
    if caret == 'end' and lines:
        d.rectangle([last_x + 2, last_y + 2, last_x + 14, last_y + 26], fill=TERM_INK)
    elif caret == 'next':
        d.rectangle([26, y + 2, 38, y + 26], fill=TERM_INK)
    return chrome(body, title, dark=True)


def typed(text, t0, t1, t):
    n = int(len(text) * ease((t - t0) / (t1 - t0))) if t >= t0 else 0
    return text[:max(0, min(len(text), n))]


def caption(frame, text, t, t_in, t_out):
    a = min(ease((t - t_in) / 0.35), ease((t_out - t) / 0.35))
    if a <= 0:
        return
    layer = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    tw = d.textlength(text, font=CAP)
    x0, y0 = (W - tw) / 2 - 34, 960
    d.rounded_rectangle([x0, y0, x0 + tw + 68, y0 + 70], radius=35, fill=(20, 20, 24, int(200 * a)))
    d.text((x0 + 34, y0 + 14), text, font=CAP, fill=(255, 255, 255, int(255 * a)))
    frame.paste(layer, (0, 0), layer)


def cursor(frame, x, y, click=0.0):
    d = ImageDraw.Draw(frame)
    if click > 0:
        r = 10 + 26 * click
        d.ellipse([x - r, y - r, x + r, y + r], outline=(255, 255, 255), width=3)
    s = 1.25
    pts = [(0, 0), (0, 25), (6, 19), (11, 30), (15, 28), (10, 18), (18, 18)]
    pts = [(x + px * s, y + py * s) for px, py in pts]
    d.polygon(pts, fill=(0, 0, 0), outline=(255, 255, 255))


def path(t, keys):
    """Cursor position from keyframes [(time, (x, y))], eased between them."""
    if t <= keys[0][0]:
        return keys[0][1]
    for (ta, pa), (tb, pb) in zip(keys, keys[1:]):
        if t <= tb:
            k = ease((t - ta) / (tb - ta))
            return (lerp(pa[0], pb[0], k), lerp(pa[1], pb[1], k))
    return keys[-1][1]


# ---------- the script ----------

PROMPT = 'clean up the old checkout code'
L_PROMPT = lambda s: [('> ', TERM_DIM), (s, TERM_INK)]
L_PLAN = [('● ', TERM_INK), ("I'll remove the legacy checkout module.", TERM_INK)]
L_BASH = [('● ', GREEN), ('Bash', TERM_INK), ('(rm -rf src/legacy)', TERM_DIM)]
L_OUT = [('  └  ', TERM_DIM), ('(no output)', TERM_DIM)]
L_DONE = [('● ', TERM_INK), ('Done. Removed src/legacy.', TERM_INK)]
LS = 'ls src/legacy'

DURATION = 14.6
C_ICON = (ICON_X + 2, ICON_Y + 2)
cur_keys = [(6.6, (960, 700)), (7.6, C_ICON), (8.3, C_ICON), (10.1, UNDO), (11.4, UNDO)]
clicks = [7.75, 10.55]
T_UNDO = 10.6


def frame_at(t):
    f = BASE.copy()
    menubar(f)
    # agent terminal
    lines = []
    if t >= 0.4:
        lines.append(L_PROMPT(typed(PROMPT, 0.6, 2.2, t)))
    if t >= 2.6: lines.append(L_PLAN)
    if t >= 3.2: lines.append(L_BASH)
    if t >= 3.8: lines.append(L_OUT)
    if t >= 4.3: lines.append(L_DONE)
    agent_caret = 'end' if t < 2.4 else ('next' if t >= 4.3 else None)
    shell_front = t >= 12.0
    agent = terminal(lines, AGENT[2], AGENT[3], 'claude — shop-app', agent_caret)
    shell_lines = []
    if t >= 5.0:
        shell_lines.append([('$ ', TERM_DIM), (typed(LS, 5.1, 5.7, t), TERM_INK)])
    if t >= 5.9:
        shell_lines.append([('ls: src/legacy: No such file or directory', RED)])
    if t >= 12.2:
        shell_lines.append([('$ ', TERM_DIM), (typed(LS, 12.3, 12.8, t), TERM_INK)])
    if t >= 13.0:
        shell_lines.append([('cart.ts', GREEN), ('    ', TERM_INK), ('checkout.ts', GREEN)])
    shell = terminal(shell_lines, SHELL[2], SHELL[3], 'zsh — shop-app', 'next' if t >= 5.9 else 'end')
    place(f, agent, AGENT[0], AGENT[1])
    if t >= 4.8:
        a = ease((t - 4.8) / 0.4)
        place(f, shell, SHELL[0], SHELL[1] + (1 - a) * 30, alpha=a)
    # the popover: opens on the menu bar click, shows the agent's rm -rf with Undo, then the result
    pop_a = ease((t - 7.8) / 0.25) * (1 - ease((t - 11.9) / 0.3))
    if pop_a > 0:
        layer = popover_undone if t >= T_UNDO else popover
        place(f, layer, POP_X, POP_Y + (1 - pop_a) * -10, alpha=pop_a)
        if 8.4 <= t <= 10.3:
            pulse = 0.5 + 0.5 * math.sin((t - 8.4) * 6)
            d = ImageDraw.Draw(f)
            d.rounded_rectangle(RECENT_ROW, radius=10, outline=(BLUE[0], BLUE[1], BLUE[2]), width=int(2 + 2 * pulse))
        if 10.45 <= t < T_UNDO:
            d = ImageDraw.Draw(f, 'RGBA')
            bx, by = UNDO
            d.rounded_rectangle([bx - 30, by - 14, bx + 30, by + 14], radius=7, fill=(0, 0, 0, 40))
    if shell_front:
        place(f, shell, SHELL[0], SHELL[1])
    # captions
    caption(f, '2:07 a.m. Your agent is on autopilot.', t, 0.2, 4.2)
    caption(f, '…and deletes the wrong folder.', t, 4.3, 6.4)
    caption(f, 'Airbag took a snapshot right before it.', t, 8.3, 10.3)
    caption(f, 'One click.', t, 10.5, 11.9)
    caption(f, "It's all back.", t, 12.1, DURATION)
    # cursor
    if 6.6 <= t <= 11.8:
        x, y = path(t, cur_keys)
        click = max([1 - abs(t - c) / 0.18 for c in clicks if abs(t - c) < 0.18] or [0])
        cursor(f, x, y, click)
    return f


def end_card(k):
    f = BASE.filter(ImageFilter.GaussianBlur(18))
    veil = Image.new('RGBA', (W, H), (255, 255, 255, int(150 * k)))
    f.paste(veil, (0, 0), veil)
    d = ImageDraw.Draw(f)
    ic = icon.resize((200, 200), Image.LANCZOS)
    a = int(255 * k)
    ic.putalpha(ic.getchannel('A').point(lambda v: int(v * k)))
    f.paste(ic, ((W - 200) // 2, 250), ic)
    for text, font, color, y in [('Airbag', TITLE, INK, 480), ('Undo for AI coding agents', CAP, INK, 570),
                                 ('github.com/a1murt/airbag', SMALL, DIM_INK, 630)]:
        tw = d.textlength(text, font=font)
        d.text(((W - tw) / 2, y), text, font=font, fill=color + (a,))
    return f


frames = []
n = int(DURATION * FPS)
for i in range(n):
    frames.append(frame_at(i / FPS))
for i in range(int(2.2 * FPS)):
    k = ease(i / (0.5 * FPS))
    frames.append(Image.blend(frames[n - 1].convert('RGB'), end_card(1.0).convert('RGB'), k) if k < 1 else end_card(1.0).convert('RGB'))

for i, fr in enumerate(frames):
    fr.convert('RGB').save(os.path.join(FRAMES, f'{i:05d}.jpg'), quality=93)

# README GIF: 12 fps, 960 px wide.
step = FPS / 12
gif = [frames[int(i * step)].convert('RGB').resize((960, 540), Image.LANCZOS) for i in range(int(len(frames) / step))]
pal = [g.quantize(colors=200, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE) for g in gif]
pal[0].save(os.path.join(OUT, 'demo.gif'), save_all=True, append_images=pal[1:], duration=int(1000 / 12), loop=0, optimize=True)
print(f'{len(frames)} frames at {FPS} fps ({len(frames) / FPS:.1f} s); demo.gif {os.path.getsize(os.path.join(OUT, "demo.gif")) // 1024} KB')
