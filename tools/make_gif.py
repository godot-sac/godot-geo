"""Turns a Godot Movie Maker PNG sequence into an animated GIF for the README (Pillow, in tools/requirements.txt).

Usage:
    <godot> --path . --write-movie <dir>/frame.png --fixed-fps 15 res://demo/visibility_tour.tscn
    tools/.venv/Scripts/python -I tools/make_gif.py <dir> docs/media/visibility.gif [--width 800] [--fps 15]
One palette is made from a few frames and used for all of them; each frame stores only the pixels that changed.
"""
import argparse
from pathlib import Path

import numpy as np
from PIL import Image

TRANSPARENT = 255  # palette index of unchanged pixels


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("frames", type=Path, help="directory with frame*.png")
    ap.add_argument("out", type=Path)
    ap.add_argument("--width", type=int, default=800)
    ap.add_argument("--fps", type=float, default=15.0)
    ap.add_argument("--colors", type=int, default=192)
    args = ap.parse_args()

    paths = sorted(args.frames.glob("frame*.png"))
    if not paths:
        raise SystemExit(f"no frame*.png in {args.frames}")

    def load(p: Path) -> Image.Image:
        im = Image.open(p).convert("RGB")
        return im.resize((args.width, round(im.height * args.width / im.width)), Image.LANCZOS)

    samples = [load(paths[i]) for i in sorted({0, len(paths) // 3, len(paths) * 2 // 3, len(paths) - 1})]
    sheet = Image.new("RGB", (samples[0].width, samples[0].height * len(samples)))
    for i, im in enumerate(samples):
        sheet.paste(im, (0, i * im.height))
    palette = sheet.quantize(min(args.colors, 255), method=Image.Quantize.MEDIANCUT)
    frames = []
    previous = None
    for p in paths:
        index = np.asarray(load(p).quantize(palette=palette, dither=Image.Dither.NONE))
        # Pixels that did not change become transparent, so the previous frame shows through.
        out = index.copy()
        if previous is not None:
            out[index == previous] = TRANSPARENT
        previous = index
        frame = Image.fromarray(out, "P")
        frame.putpalette(palette.getpalette()[:765] + [0, 0, 0])
        frames.append(frame)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    frames[0].save(args.out, save_all=True, append_images=frames[1:], duration=round(1000 / args.fps), loop=0,
                   optimize=False, disposal=1, transparency=TRANSPARENT)
    print(f"{args.out}: {len(frames)} frames, {frames[0].width}x{frames[0].height}, "
          f"{args.out.stat().st_size / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
