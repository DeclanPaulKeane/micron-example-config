#!/usr/bin/env python3
"""Creates synthetic PDFs of several sizes in data/large/ (noise images, so they do not compress) for the large-file tests.
Run: .state/venv/bin/python data/make-large.py   (about 1 minute; output is git-ignored)"""
import numpy as np, random, textwrap, os, pathlib
from PIL import Image
from reportlab.lib.pagesizes import letter
from reportlab.pdfgen import canvas
random.seed(11); np.random.seed(11)
OUT = pathlib.Path(__file__).parent / "large"; OUT.mkdir(exist_ok=True)
def noisy_pdf(path, title, mb, pages):
    c = canvas.Canvas(str(path), pagesize=letter); side = int((int(mb * 1e6 / pages) / 3) ** 0.5); tmps = []
    for i in range(pages):
        c.setFont("Helvetica-Bold", 16); c.drawString(72, 740, f"{title} - page {i+1}"); c.setFont("Helvetica", 11); y = 715
        for line in textwrap.wrap(f"Synthetic section {i+1}: revenue grew {random.randint(2,14)} percent; headcount {random.randint(80,400)}; supplier lead time {random.randint(3,30)} days. All figures are fictional and generated for a demo.", 95): c.drawString(72, y, line); y -= 14
        t = f".tmp_{path.name}_{i}.png"; Image.fromarray(np.random.randint(0, 256, (side, side, 3), dtype=np.uint8)).save(t); tmps.append(t)
        c.drawImage(t, 72, 150, width=468, height=420); c.showPage()
    c.save(); [os.remove(t) for t in tmps]
# argument = target size before PDF overhead; files are named by their real size (about 1.25x the argument)
for real, arg in ((6, 5), (22, 18), (32, 26), (60, 48), (87, 70)):
    noisy_pdf(OUT / f"report-{real}MB.pdf", f"report-{real}MB", arg, max(10, arg))
print("done:", sorted(p.name for p in OUT.glob("*.pdf")))
