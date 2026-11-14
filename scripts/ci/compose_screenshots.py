#!/usr/bin/env python3
"""
Compose App Store marketing frames from raw simulator captures (CI only; needs Pillow).

    compose_screenshots.py [--raw build/screenshots/raw] [--out build/screenshots/composed]
                           [--captions store/en-US/captions.txt]

For every build/screenshots/raw/<device>/<n>-<screen>.png writes
build/screenshots/composed/<device>/<n>-<screen>.png: a brand-purple gradient, the screen's caption
(store/en-US/captions.txt, "<screen>=<caption>", at most two lines) in bold white at the top, and the
capture below it with rounded corners and a soft shadow. The output is exactly the store size for
the device, PNG, RGB (no alpha):

    iphone-69   1320 x 2868   (iPhone with Dynamic Island, large display  -> APP_IPHONE_67)
    iphone-63   1206 x 2622   (iPhone with Dynamic Island, medium display -> APP_IPHONE_61)
    iphone-duo  2007 x 2853   (iPhone Duo, inner display                  -> APP_IPHONE_DUO)

A device folder may hold orientation-probe.png (the app's red-over-blue probe screen, captured on
the same display): every capture in that folder is then rotated the way that makes the probe upright.
The iPhone Duo's inner display can come out of `simctl io screenshot` sideways (2853x2007).
Without a probe, a capture whose orientation doesn't match the store size is an error.

Font: the system font of the macOS runner (SF, else Helvetica / Arial); nothing is bundled.
"""

import argparse
import pathlib
import re
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageStat

SIZES = {
    'iphone-69': (1320, 2868),
    'iphone-63': (1206, 2622),
    'iphone-duo': (2007, 2853),
}

TOP = (0x43, 0x1F, 0x86)     # brand purple
BOTTOM = (0x7B, 0x4F, 0xD6)

# (path, TrueType collection index, variable-font instance name). First one that loads wins.
FONTS = [
    ('/System/Library/Fonts/SFNS.ttf', 0, 'Bold'),
    ('/System/Library/Fonts/SFNSDisplay.ttf', 0, 'Bold'),
    ('/System/Library/Fonts/Helvetica.ttc', 1, None),           # Helvetica Bold
    ('/System/Library/Fonts/HelveticaNeue.ttc', 1, None),       # Helvetica Neue Bold
    ('/System/Library/Fonts/Supplemental/Arial Bold.ttf', 0, None),
    ('/Library/Fonts/Arial Bold.ttf', 0, None),
    ('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf', 0, None),  # local runs on Linux
]


def load_font(size):
    for path, index, instance in FONTS:
        if not pathlib.Path(path).exists():
            continue
        try:
            font = ImageFont.truetype(path, size, index=index)
        except OSError:
            continue
        if instance:
            try:
                font.set_variation_by_name(instance)
            except (OSError, ValueError, AttributeError):
                pass  # not a variable font here, or no such instance: regular weight is fine
        return font
    print('::warning::No system TrueType font found; using Pillow\'s default font', file=sys.stderr)
    return ImageFont.load_default(size)


def read_captions(path):
    captions = {}
    for line in pathlib.Path(path).read_text(encoding='utf-8').splitlines():
        line = line.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, value = line.split('=', 1)
        captions[key.strip()] = value.strip()
    return captions


def gradient(size):
    """Diagonal gradient from TOP (top-left) to BOTTOM (bottom-right)."""
    w, h = size
    # A small gradient scaled up is smooth and fast.
    small = Image.new('RGB', (64, 64))
    px = small.load()
    for y in range(64):
        for x in range(64):
            t = (x / 63 * 0.35 + y / 63 * 0.65)
            px[x, y] = tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM))
    return small.resize((w, h), Image.Resampling.BICUBIC)


def text_width(draw, text, font):
    left, _, right, _ = draw.textbbox((0, 0), text, font=font)
    return right - left


def wrap(draw, caption, font, max_width):
    """Lines for the caption: forced breaks at ' | ', else greedy word wrap. None if > 2 lines."""
    parts = [p.strip() for p in caption.split('|')] if '|' in caption else [caption]
    lines = []
    for part in parts:
        current = ''
        for word in part.split():
            candidate = f'{current} {word}'.strip()
            if not current or text_width(draw, candidate, font) <= max_width:
                current = candidate
            else:
                lines.append(current)
                current = word
        if current:
            lines.append(current)
    if len(lines) > 2 or any(text_width(draw, line, font) > max_width for line in lines):
        return None
    return lines


def fit_caption(draw, caption, width, start_size):
    """Largest font size (down to 55%) at which the caption fits in two lines."""
    size = start_size
    while size >= start_size * 0.55:
        font = load_font(size)
        lines = wrap(draw, caption, font, width)
        if lines:
            return font, lines, size
        size -= 4
    sys.exit(f'Caption too long for two lines: "{caption}"')


def rounded_mask(size, radius):
    mask = Image.new('L', size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), radius=radius, fill=255)
    return mask


PROBE = 'orientation-probe.png'


def probe_rotation(path):
    """Degrees (counter-clockwise, as Image.rotate) that turn the probe capture upright: portrait,
    red half on top, blue half below. None if no rotation does."""
    probe = Image.open(path).convert('RGB')
    for angle in (0, 90, 270, 180):
        img = probe.rotate(angle, expand=True) if angle else probe
        if img.height <= img.width:
            continue
        w, h = img.size
        # Skip the edges (status bar, home indicator, rounded corners).
        top = ImageStat.Stat(img.crop((w // 4, h * 15 // 100, w * 3 // 4, h * 40 // 100))).mean
        bottom = ImageStat.Stat(img.crop((w // 4, h * 60 // 100, w * 3 // 4, h * 85 // 100))).mean
        if top[0] > 2 * top[2] + 40 and bottom[2] > 2 * bottom[0] + 40:
            return angle
    return None


def compose(raw_path, caption, size, rotation=0):
    w, h = size
    canvas = gradient(size)
    draw = ImageDraw.Draw(canvas)

    margin = round(w * 0.07)
    base = round(w * 0.075)  # caption font size before shrinking; ~99 px at 1320 wide
    if w > h * 0.65:         # iPhone Duo's near-square inner display: size by height instead
        base = round(h * 0.036)
    font, lines, font_size = fit_caption(draw, caption, w - 2 * margin, base)

    line_height = round(font_size * 1.18)
    caption_top = round(h * 0.045)
    for i, line in enumerate(lines):
        draw.text((w / 2, caption_top + i * line_height), line, font=font, fill='white', anchor='ma')
    caption_bottom = caption_top + 2 * line_height  # reserve two lines so frames line up

    # The capture, scaled to fit below the caption.
    shot = Image.open(raw_path).convert('RGB')
    if rotation:
        shot = shot.rotate(rotation, expand=True)
    if (shot.width > shot.height) != (w > h):
        sys.exit(f'{raw_path}: {shot.width}x{shot.height} capture for a {w}x{h} frame, and no '
                 f'{PROBE} to tell how to rotate it')
    gap = round(h * 0.03)
    avail_w = w - 2 * margin
    avail_h = h - caption_bottom - gap - round(h * 0.03)
    scale = min(avail_w / shot.width, avail_h / shot.height)
    shot_size = (round(shot.width * scale), round(shot.height * scale))
    shot = shot.resize(shot_size, Image.Resampling.LANCZOS)
    x = (w - shot_size[0]) // 2
    y = caption_bottom + gap
    radius = round(min(shot_size) * 0.075)

    # Soft shadow: a blurred dark rounded rectangle, a little below the capture.
    blur = round(w * 0.02)
    shadow_layer = Image.new('L', (w, h), 0)
    ImageDraw.Draw(shadow_layer).rounded_rectangle(
        (x, y + blur // 2, x + shot_size[0], y + shot_size[1] + blur // 2), radius=radius, fill=110)
    shadow_layer = shadow_layer.filter(ImageFilter.GaussianBlur(blur))
    canvas.paste(Image.new('RGB', (w, h), (20, 8, 45)), (0, 0), shadow_layer)

    canvas.paste(shot, (x, y), rounded_mask(shot_size, radius))
    return canvas


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--raw', default='build/screenshots/raw')
    parser.add_argument('--out', default='build/screenshots/composed')
    parser.add_argument('--captions', default='store/en-US/captions.txt')
    args = parser.parse_args()

    captions = read_captions(args.captions)
    raw_root, out_root = pathlib.Path(args.raw), pathlib.Path(args.out)
    count = 0
    for device_dir in sorted(p for p in raw_root.iterdir() if p.is_dir()):
        size = SIZES.get(device_dir.name)
        if not size:
            print(f'::warning::Skipping unknown device folder {device_dir.name}')
            continue
        rotation = 0
        probe = device_dir / PROBE
        if probe.exists():
            rotation = probe_rotation(probe)
            if rotation is None:
                sys.exit(f'{probe}: no rotation shows the red half on top; was the probe captured on '
                         'the right display?')
            print(f'{device_dir.name}: captures rotated {rotation} degrees (from {PROBE})')
        for raw in sorted(device_dir.glob('*.png')):
            if raw.name == PROBE:
                continue
            match = re.fullmatch(r'\d+-(.+)', raw.stem)
            screen = match.group(1) if match else raw.stem
            if screen not in captions:
                sys.exit(f'No caption for screen "{screen}" in {args.captions}')
            image = compose(raw, captions[screen], size, rotation)
            assert image.size == size and image.mode == 'RGB'
            dest = out_root / device_dir.name / raw.name
            dest.parent.mkdir(parents=True, exist_ok=True)
            image.save(dest, 'PNG', optimize=True)
            count += 1
            print(f'{dest}  {size[0]}x{size[1]}  "{captions[screen]}"')
    if not count:
        sys.exit(f'No raw screenshots found under {raw_root}')


if __name__ == '__main__':
    main()
