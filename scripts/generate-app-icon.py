#!/usr/bin/env python3
"""Generate the RDPServer app icon from the white line-art pager artwork.

The artwork lives at ``native/macos/Resources/AppIcon-art.png`` (transparent
background, white strokes). This script trims its transparent margins,
composites it onto a dark rounded-square macOS tile with a subtle gradient,
and renders every iconset representation with LANCZOS downsampling before
packing the ``.icns`` with ``iconutil``.

The artwork is the product's icon source; the tile geometry (margins, corner
radius, gradient, sheen) is defined here so the icon stays reproducible on any
machine with the same Pillow/iconutil versions.

Requirements: macOS (for ``iconutil``) and Pillow. Pillow is an environment
dependency, not a project dependency (all other scripts here are
standard-library only); when it is missing this script exits with a clear
message.

Usage:
    python3 scripts/generate-app-icon.py                 # rewrite the tracked .icns
    python3 scripts/generate-app-icon.py --preview /tmp/appicon-preview.png
    python3 scripts/generate-app-icon.py --iconset /tmp/AppIcon.iconset
    python3 scripts/generate-app-icon.py --art path/to/other-art.png
    python3 scripts/generate-app-icon.py --verify-only

The output path defaults to ``native/macos/Resources/AppIcon.icns`` (resolved
from the repository root, so the script works from any cwd). The packaging
script ``scripts/package-app-dmg.py`` copies that file into the bundle and the
Info.plist keeps ``CFBundleIconFile = AppIcon``; no packaging change is needed.
"""

from __future__ import annotations

import argparse
import hashlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFilter
except ImportError:  # pragma: no cover - exercised only without Pillow
    sys.exit(
        "error: Pillow is required to compose the icon (stdlib + Pillow only).\n"
        "       Install it in the environment you use to run this script, e.g.\n"
        "         python3 -m pip install Pillow\n"
        "       The project's other scripts do not need Pillow; only this one does."
    )

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / "native" / "macos" / "Resources" / "AppIcon.icns"
DEFAULT_ART = ROOT / "native" / "macos" / "Resources" / "AppIcon-art.png"
_art_path = DEFAULT_ART

# iconset entry -> pixel size. Every size 16/32/64/128/256/512/1024 is covered
# exactly once by the 10 names below; 32/256/512 appear twice by design (1x and
# @2x share a pixel size) and are rendered once.
ICONSET_ENTRIES = (
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
)
ICON_SIZES = tuple(sorted({size for _, size in ICONSET_ENTRIES}))
SUPERSAMPLE = 4  # 4x rendering + LANCZOS gives clean edges at every size.

# Tile geometry (fractions of the square canvas) and palette (sRGB).
TILE_TOP = (44, 56, 76)
TILE_BOTTOM = (9, 13, 19)
TILE_MARGIN = 0.098
TILE_RADIUS = 0.225  # fraction of the tile edge
ART_WIDTH = 0.64  # fraction of the tile width
ART_VERTICAL_OFFSET = 0.006  # optical centering nudge, fraction of the canvas
HAIRLINE_ALPHA = 20
SHEEN_ALPHA = 16
SHEEN_HEIGHT = 0.40  # fraction of the tile height


def _rgba(color, alpha=255):
    if len(color) == 4:
        return color
    return (color[0], color[1], color[2], alpha)


def _vertical_gradient(width: int, height: int, top, bottom) -> Image.Image:
    """RGB gradient image; width is ignored (a 1 px column is stretched)."""
    strip = Image.new("RGB", (1, height))
    pixels = strip.load()
    for y in range(height):
        ratio = y / max(height - 1, 1)
        pixels[0, y] = (
            round(top[0] + (bottom[0] - top[0]) * ratio),
            round(top[1] + (bottom[1] - top[1]) * ratio),
            round(top[2] + (bottom[2] - top[2]) * ratio),
        )
    return strip.resize((max(width, 1), height), Image.NEAREST)


def _rounded_box_mask(size: int, box, radius: float) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    return mask


def _load_art(unit: int):
    """Trim the artwork's transparent margins and scale it for a ``unit`` canvas."""
    art = Image.open(_art_path).convert("RGBA")
    # Ignore the faint (>0, <=8) anti-alias/shadow halo when trimming so the
    # visible pager — not its soft fringe — defines the composition size.
    bbox = art.getchannel("A").point(lambda value: 255 if value > 8 else 0).getbbox()
    if bbox is None:
        raise RuntimeError(f"artwork has no opaque pixels: {_art_path}")
    art = art.crop(bbox)

    tile_edge = unit * (1 - TILE_MARGIN * 2)
    target_width = max(1, round(tile_edge * ART_WIDTH))
    scale = target_width / art.width
    target_height = max(1, round(art.height * scale))
    return art.resize((target_width, target_height), Image.LANCZOS)


def render_icon(size: int) -> Image.Image:
    """Compose one square representation at ``size`` px, antialiased."""
    unit = size * SUPERSAMPLE
    canvas = Image.new("RGBA", (unit, unit), (0, 0, 0, 0))

    def px(fraction: float) -> float:
        return fraction * unit

    # --- background tile: rounded square with a soft drop shadow -------------
    tile_box = (px(TILE_MARGIN), px(TILE_MARGIN), px(1 - TILE_MARGIN), px(1 - TILE_MARGIN))
    tile_radius = TILE_RADIUS * (tile_box[2] - tile_box[0])

    shadow = Image.new("RGBA", (unit, unit), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (tile_box[0], tile_box[1] + px(0.016), tile_box[2], tile_box[3] + px(0.016)),
        radius=tile_radius,
        fill=(0, 0, 0, 90),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(px(0.018)))
    canvas = Image.alpha_composite(canvas, shadow)

    tile_mask = _rounded_box_mask(unit, tile_box, tile_radius)
    tile = _vertical_gradient(unit, unit, TILE_TOP, TILE_BOTTOM).convert("RGBA")

    # faint top sheen, fading out before the middle of the tile
    sheen_height = max(1, round((tile_box[3] - tile_box[1]) * SHEEN_HEIGHT))
    sheen_strip = Image.new("RGBA", (1, sheen_height))
    for y in range(sheen_height):
        alpha = round(SHEEN_ALPHA * (1 - y / max(sheen_height - 1, 1)))
        sheen_strip.putpixel((0, y), (255, 255, 255, alpha))
    tile.alpha_composite(sheen_strip.resize((unit, sheen_height), Image.NEAREST),
                         (0, round(tile_box[1])))
    canvas.paste(tile, (0, 0), tile_mask)

    # hairline edge keeps the tile crisp against light and dark desktops
    ImageDraw.Draw(canvas).rounded_rectangle(
        tile_box,
        radius=tile_radius,
        outline=_rgba((255, 255, 255), HAIRLINE_ALPHA),
        width=max(1, round(px(0.002))),
    )

    # --- white pager artwork, optically centred ------------------------------
    art = _load_art(unit)
    art_x = round((unit - art.width) / 2)
    art_y = round((unit - art.height) / 2 + px(ART_VERTICAL_OFFSET))
    canvas.alpha_composite(art, (art_x, art_y))

    return canvas.resize((size, size), Image.LANCZOS)


def write_iconset(directory: Path) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    rendered: dict[int, Path] = {}
    for size in ICON_SIZES:
        path = directory / f"render-{size}.png"
        render_icon(size).save(path, format="PNG", optimize=True)
        rendered[size] = path
    # Re-use the single render per pixel size for both 1x/@2x entry names.
    for name, size in ICONSET_ENTRIES:
        shutil.copyfile(rendered[size], directory / name)
    for path in rendered.values():
        path.unlink()


def run_iconutil(arguments) -> None:
    completed = subprocess.run(["iconutil", *arguments], capture_output=True, text=True)
    if completed.returncode != 0:
        output = (completed.stderr or completed.stdout).strip()
        raise RuntimeError("iconutil failed: " + " ".join(completed.args) + ("\n" + output if output else ""))


def build_icns(icns_path: Path, iconset_dir: Path) -> None:
    icns_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="rdp-appicon-") as staging:
        staged = Path(staging) / "AppIcon.icns"
        run_iconutil(["-c", "icns", str(iconset_dir), "-o", str(staged)])
        temporary = icns_path.with_suffix(icns_path.suffix + ".tmp")
        shutil.copyfile(staged, temporary)
        temporary.replace(icns_path)


def _sips_dimensions(path: Path):
    completed = subprocess.run(
        ["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)],
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise RuntimeError(f"sips failed for {path}: {completed.stderr.strip()}")
    values = {}
    for line in completed.stdout.splitlines():
        key, _, value = line.strip().partition(":")
        if key in ("pixelWidth", "pixelHeight"):
            values[key] = int(value.strip())
    return values["pixelWidth"], values["pixelHeight"]


def verify_icns(icns_path: Path, expected_size: int = 1024) -> None:
    """Round-trip through iconutil/sips and assert every rep has the right size."""
    if sys.platform != "darwin":
        raise RuntimeError("iconutil/sips verification requires macOS")
    with tempfile.TemporaryDirectory(prefix="rdp-appicon-verify-") as staging:
        extracted = Path(staging) / "Extracted.iconset"
        run_iconutil(["-c", "iconset", str(icns_path), "-o", str(extracted)])
        for name, size in ICONSET_ENTRIES:
            rep = extracted / name
            if not rep.is_file():
                raise RuntimeError(f"icns is missing representation {name}")
            width, height = _sips_dimensions(rep)
            if (width, height) != (size, size):
                raise RuntimeError(f"{name}: expected {size}x{size}, got {width}x{height}")
        largest = _sips_dimensions(icns_path)
        if largest != (expected_size, expected_size):
            raise RuntimeError(f"icns largest rep is {largest}, expected {expected_size}x{expected_size}")
    print(f"  verified: {len(ICONSET_ENTRIES)} reps via iconutil, largest {expected_size}x{expected_size}")


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main(argv=None) -> int:
    global _art_path
    parser = argparse.ArgumentParser(
        description="Generate the RDPServer app icon from the white pager artwork."
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT,
        help=f"icns output path (default: {DEFAULT_OUTPUT})",
    )
    parser.add_argument(
        "--art",
        type=Path,
        default=None,
        help=f"white line-art source PNG (default: {DEFAULT_ART})",
    )
    parser.add_argument("--iconset", type=Path, default=None, help="keep the generated .iconset directory here")
    parser.add_argument("--preview", type=Path, default=None, help="also write the 1024 px PNG here")
    parser.add_argument("--verify-only", action="store_true", help="only verify an existing icns (no drawing)")
    args = parser.parse_args(argv)

    if sys.platform != "darwin":
        sys.exit("error: iconutil is required; run this on macOS")
    if shutil.which("iconutil") is None:
        sys.exit("error: iconutil not found in PATH")

    _art_path = DEFAULT_ART if args.art is None else (
        args.art if args.art.is_absolute() else (ROOT / args.art)
    )

    output = args.output if args.output.is_absolute() else (ROOT / args.output)
    if args.verify_only:
        verify_icns(output)
        print(f"  {output} {output.stat().st_size:,} bytes sha256={_sha256(output)}")
        return 0

    if not _art_path.is_file():
        sys.exit(f"error: artwork not found: {_art_path}")

    iconset_dir = args.iconset
    temporary_iconset = None
    if iconset_dir is None:
        temporary_iconset = tempfile.TemporaryDirectory(prefix="rdp-appicon-iconset-")
        iconset_dir = Path(temporary_iconset.name) / "AppIcon.iconset"
    try:
        sizes = ", ".join(str(size) for size in ICON_SIZES)
        print(f"==> composing {len(ICON_SIZES)} representations: {sizes} px")
        print(f"    artwork: {_art_path}")
        write_iconset(iconset_dir)
        build_icns(output, iconset_dir)
        verify_icns(output)
    finally:
        if temporary_iconset is not None:
            temporary_iconset.cleanup()

    if args.preview is not None:
        preview = args.preview if args.preview.is_absolute() else (ROOT / args.preview)
        preview.parent.mkdir(parents=True, exist_ok=True)
        render_icon(1024).save(preview, format="PNG", optimize=True)
        print(f"  preview: {preview}")

    print(f"  wrote {output} {output.stat().st_size:,} bytes sha256={_sha256(output)}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, OSError) as error:
        sys.exit(f"error: {error}")
