#!/usr/bin/env python3
"""Redact only photo thumbnails in 1320×2868 KeepOne screenshots.

Requires Pillow. Originals are read only; outputs contain no source text metadata.
Usage:
    python3 scripts/redact_screenshots.py --home <png> --categories <png> \
        --output-dir build/redacted-screenshots \
        --styles pixels-6 pixels-8 pixels-12
    python3 scripts/redact_screenshots.py --temporary <png> \
        --output-dir build/redacted-screenshots \
        --styles pixels-6 pixels-8 pixels-12
"""

import argparse
import math
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont


SIZE = (1320, 2868)
DEFAULT_STYLES = ("blur", "pixels", "dark-blur")
PIXEL_GRIDS = {"pixels": 4, "pixels-6": 6, "pixels-8": 8, "pixels-12": 12}
STYLES = DEFAULT_STYLES + ("pixels-6", "pixels-8", "pixels-12")
STYLE_TITLES = {
    "blur": "Блюр",
    "pixels": "Пікселі 4×4 · попередній",
    "dark-blur": "Темний блюр",
    "pixels-6": "Пікселі 6×6",
    "pixels-8": "Пікселі 8×8",
    "pixels-12": "Пікселі 12×12",
}
REGIONS = {
    "home": [(1031, 1362 + 193 * i, 1168, 1499 + 193 * i) for i in range(8)],
    "home-with-scan": [(1031, 1806 + 193 * i, 1168, 1943 + 193 * i) for i in range(6)],
    "categories": [(1031, 341 + 193 * i, 1168, 478 + 193 * i) for i in range(10)],
    "temporary": [(118, 749, 290, 921), (118, 1041, 290, 1213), (118, 1335, 290, 1507)],
}


def privacy_mask(size, screen):
    mask = Image.new("L", size, 0)
    draw = ImageDraw.Draw(mask)
    for left, top, right, bottom in REGIONS[screen]:
        # Draw before clipping so partially visible photos retain the right corners.
        radius = 36 if screen == "temporary" else 25
        draw.rounded_rectangle((left, top, right - 1, bottom - 1), radius=radius, fill=255)
    if screen.startswith("home"):
        # The floating tab bar covers the left edge of the last two thumbnails.
        draw.rounded_rectangle((249, 2618, 1073, 2802), radius=92, fill=0)
    return mask


def redact(source, screen, style):
    processed = source.copy()
    for left, top, right, bottom in REGIONS[screen]:
        box = (left, top, right, min(bottom, source.height))
        patch = source.crop(box)
        if style in PIXEL_GRIDS:
            grid = PIXEL_GRIDS[style]
            patch = patch.resize((grid, grid), Image.Resampling.BOX).resize(
                patch.size, Image.Resampling.NEAREST
            )
        else:
            patch = patch.filter(ImageFilter.GaussianBlur(radius=28))
            if style == "dark-blur":
                patch = Image.blend(
                    patch, Image.new("RGB", patch.size, (24, 25, 27)), 0.48
                )
        processed.paste(patch, box)
    mask = privacy_mask(source.size, screen)
    result = Image.composite(processed, source, mask)
    # Every pixel outside the thumbnail mask must remain identical to the source.
    difference = ImageChops.difference(source, result)
    outside = Image.composite(
        difference, Image.new("RGB", source.size), ImageChops.invert(mask)
    )
    if outside.getbbox() is not None:
        raise RuntimeError("Pixels outside the photo thumbnails changed")
    return result


def font(size):
    for path in (
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    ):
        if Path(path).exists():
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def annotate_temporary(source):
    """Add a handwritten editorial callout and an arrow to the category list."""
    area = (110, 2140, 1290, 2520)
    if source.crop(area).getbbox() is not None:
        raise ValueError("The annotation area is occupied; check this screenshot's layout")
    font_path = next((path for path in (
        "/System/Library/Fonts/Supplemental/Bradley Hand Bold.ttf",
        "/System/Library/Fonts/Supplemental/Georgia Bold Italic.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSerif-BoldItalic.ttf",
    ) if Path(path).exists()), None)
    if font_path is None:
        raise ValueError("A handwriting or italic font is required for the annotation")

    color = "#ff453a"
    note = Image.new("RGBA", (1160, 270))
    note_draw = ImageDraw.Draw(note)
    note_draw.text((50, 5), "9 categories in total!",
                   font=ImageFont.truetype(font_path, 96), anchor="lt",
                   fill=color, stroke_width=1, stroke_fill=color)
    note_draw.text((75, 140), "Some already cleaned up.",
                   font=ImageFont.truetype(font_path, 80), anchor="lt",
                   fill=color, stroke_width=1, stroke_fill=color)
    note_draw.line([(40, 122), (180, 118), (350, 120), (540, 117), (720, 119), (885, 115)],
                   fill=color, width=4)
    note = note.rotate(3, resample=Image.Resampling.BICUBIC, expand=True)
    overlay = Image.new("RGBA", source.size)
    overlay.alpha_composite(note, (90, 2150))

    # A loose curved arrow makes this clearly a comment added to the screenshot.
    start, control1, control2, end = (140, 2195), (15, 2140), (30, 1730), (175, 1535)
    points = []
    for step in range(121):
        t = step / 120
        points.append(tuple((1 - t) ** 3 * start[i]
                            + 3 * (1 - t) ** 2 * t * control1[i]
                            + 3 * (1 - t) * t ** 2 * control2[i]
                            + t ** 3 * end[i] for i in (0, 1)))
    draw = ImageDraw.Draw(overlay)
    draw.line(points, fill=color, width=8, joint="curve")
    angle = math.atan2(end[1] - control2[1], end[0] - control2[0])
    for offset in (-0.5, 0.5):
        wing = (end[0] - 52 * math.cos(angle + offset),
                end[1] - 52 * math.sin(angle + offset))
        draw.line([wing, end], fill=color, width=8)
    return Image.alpha_composite(source.convert("RGBA"), overlay).convert("RGB")


def comparison(images, destination, styles=DEFAULT_STYLES, screen="categories", detail_box=None):
    width, gap, header = 340, 24, 102
    height = round(SIZE[1] * width / SIZE[0])
    canvas = Image.new("RGB", (len(styles) * width + (len(styles) + 1) * gap, header + height + 252), "#f4f5f7")
    draw = ImageDraw.Draw(canvas)
    draw.text((gap, 16), "Лише мініатюри фото · решта скриншота без змін", font=font(24), fill="#23272b")
    for i, style in enumerate(styles):
        left = gap + i * (width + gap)
        draw.text((left, 62), f"{i + 1}. {STYLE_TITLES[style]}", font=font(23), fill="#23272b")
        image = images[(screen, style)]
        canvas.paste(image.resize((width, height), Image.Resampling.LANCZOS), (left, header))
        draw.text((left, header + height + 16), "Мініатюра зблизька", font=font(20), fill="#555b63")
        detail = image.crop(detail_box or REGIONS[screen][2]).resize((176, 176), Image.Resampling.NEAREST)
        canvas.paste(detail, (left, header + height + 50))
    canvas.save(destination, optimize=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path)
    parser.add_argument("--categories", type=Path)
    parser.add_argument("--temporary", type=Path)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--styles", nargs="+", choices=STYLES, default=DEFAULT_STYLES)
    parser.add_argument("--home-layout", choices=("with-scan", "without-scan"), default="without-scan")
    parser.add_argument("--annotate-temporary", action="store_true",
                        help="Add the red README note below the temporary categories")
    args = parser.parse_args()
    sources = {screen: path for screen, path in (
        ("home", args.home), ("categories", args.categories), ("temporary", args.temporary)
    ) if path is not None}
    if not sources:
        parser.error("Supply --home, --categories, or --temporary")
    if args.annotate_temporary and args.temporary is None:
        parser.error("--annotate-temporary requires --temporary")
    if any(path.resolve().is_relative_to(args.output_dir.resolve()) for path in sources.values()):
        parser.error("Keep source screenshots outside the output directory")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    images = {}
    for screen, path in sources.items():
        layout = "home-with-scan" if screen == "home" and args.home_layout == "with-scan" else screen
        with Image.open(path) as opened:
            if opened.size != SIZE:
                parser.error(f"{path.name}: expected {SIZE}, got {opened.size}; update the masks first")
            source = opened.convert("RGB")
            profile = opened.info.get("icc_profile")
            source.info.clear()
        for style in args.styles:
            image = redact(source, layout, style)
            if screen == "temporary" and args.annotate_temporary:
                image = annotate_temporary(image)
            output = args.output_dir / f"{screen}-{style}.png"
            options = {"icc_profile": profile} if profile else {}
            image.save(output, optimize=True, **options)
            images[(screen, style)] = image
            print(f"{output}: {len(REGIONS[layout])} thumbnails redacted, UI unchanged")
    if "categories" in sources:
        output = args.output_dir / "comparison.png"
        comparison(images, output, args.styles)
        print(output)
    if "home" in sources:
        output = args.output_dir / "home-comparison.png"
        home_layout = "home-with-scan" if args.home_layout == "with-scan" else "home"
        comparison(images, output, args.styles, screen="home", detail_box=REGIONS[home_layout][2])
        print(output)
    if "temporary" in sources:
        output = args.output_dir / "temporary-comparison.png"
        comparison(images, output, args.styles, screen="temporary", detail_box=REGIONS["temporary"][1])
        print(output)


if __name__ == "__main__":
    main()
