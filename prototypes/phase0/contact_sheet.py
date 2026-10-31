"""Phase 0: builds a labelled side-by-side sheet."""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

VIEWS = ["overview", "city", "oblique_hills", "low_valley", "top_down"]
src, dst = Path(sys.argv[1]), Path(sys.argv[2])
dst.mkdir(parents=True, exist_ok=True)
cell_w, cell_h, label_h = 960, 540, 34
sheet = Image.new("RGB", (cell_w * 2, (cell_h + label_h) * len(VIEWS)), "white")
draw = ImageDraw.Draw(sheet)
font = ImageFont.truetype("arial.ttf", 22)
for row, view in enumerate(VIEWS):
    for col, renderer in enumerate(["mesh", "terrain3d"]):
        img = Image.open(src / f"{renderer}_{view}.png").convert("RGB")
        y = row * (cell_h + label_h)
        name = "own mesh" if renderer == "mesh" else "Terrain3D 1.1.0"
        draw.text((col * cell_w + 10, y + 5), f"{view} - {name}", fill="black", font=font)
        sheet.paste(img.resize((cell_w, cell_h), Image.LANCZOS), (col * cell_w, y + label_h))
sheet.save(dst / "comparison_sheet.jpg", quality=85)
