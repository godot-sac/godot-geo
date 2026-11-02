"""Contact sheet of the bookmark views that city.tscn saves with --tour --out <dir>.

    tools/.venv/Scripts/python.exe demo/places_sheet.py <dir> <out.jpg> [--only-checks]

Bookmarks are taken in demo/places.json order; --only-checks keeps the reference views (check = true).
"""
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

src, dst = Path(sys.argv[1]), Path(sys.argv[2])
places = json.loads((Path(__file__).parent / "places.json").read_text(encoding="utf-8"))["places"]
if "--only-checks" in sys.argv:
    places = [p for p in places if p.get("check")]
places = [p for p in places if (src / f"{p['id']}.png").exists()]
cols = 2 if len(places) <= 4 else 3
cell_w, cell_h, label_h = 800, 450, 32
rows = (len(places) + cols - 1) // cols
sheet = Image.new("RGB", (cell_w * cols, (cell_h + label_h) * rows), "white")
draw = ImageDraw.Draw(sheet)
try:
    font = ImageFont.truetype("arial.ttf", 20)
except OSError:
    font = ImageFont.load_default()
for i, p in enumerate(places):
    x, y = (i % cols) * cell_w, (i // cols) * (cell_h + label_h)
    draw.text((x + 10, y + 5), p["name"], fill="black", font=font)
    img = Image.open(src / f"{p['id']}.png").convert("RGB")
    sheet.paste(img.resize((cell_w, cell_h), Image.LANCZOS), (x, y + label_h))
dst.parent.mkdir(parents=True, exist_ok=True)
sheet.save(dst, quality=85)
print(f"{dst}: {len(places)} views")
