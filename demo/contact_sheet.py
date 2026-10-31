"""Builds docs/phase2/views_sheet.jpg from the PNGs terrain_view.tscn saves with --out."""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

VIEWS = ["overview", "city", "hills_east", "valley", "low_city", "top_down"]
src, dst = Path(sys.argv[1]), Path(sys.argv[2])
dst.mkdir(parents=True, exist_ok=True)
cell_w, cell_h, label_h = 960, 540, 34
rows = (len(VIEWS) + 1) // 2
sheet = Image.new("RGB", (cell_w * 2, (cell_h + label_h) * rows), "white")
draw = ImageDraw.Draw(sheet)
font = ImageFont.truetype("arial.ttf", 22)
for i, view in enumerate(VIEWS):
    x, y = (i % 2) * cell_w, (i // 2) * (cell_h + label_h)
    draw.text((x + 10, y + 5), view, fill="black", font=font)
    img = Image.open(src / f"{view}.png").convert("RGB")
    sheet.paste(img.resize((cell_w, cell_h), Image.LANCZOS), (x, y + label_h))
sheet.save(dst / "views_sheet.jpg", quality=85)
Image.open(src / "city.png").convert("RGB").save(dst / "city.jpg", quality=88)
