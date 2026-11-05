#!/usr/bin/env python3
"""Generate the synthetic Micron demo data set (all content is made up). Idempotent."""
import os, random, textwrap
from pathlib import Path
import numpy as np
from PIL import Image
from reportlab.lib.pagesizes import letter
from reportlab.pdfgen import canvas

ROOT = Path(__file__).parent
random.seed(7); np.random.seed(7)

def write(path, text):
    p = ROOT / path; p.parent.mkdir(parents=True, exist_ok=True); p.write_text(textwrap.dedent(text).lstrip())

# ---- 1. test repo with a payment module (no tests: Claude Code adds them) ----
write("test-repo/README.md", """
    # acme-shop (synthetic)
    Small demo service. `payment/` handles charges and refunds; it needs refactoring and unit tests.
    """)
write("test-repo/payment/__init__.py", "")
write("test-repo/payment/processor.py", '''
    import time, random

    FEES = {"card": 0.029, "ach": 0.008, "wire": 0.0}
    def process(o):
        # TODO: this function does too much
        if o["amount"] <= 0: raise Exception("bad amount")
        if o["method"] not in FEES: raise Exception("bad method")
        fee = o["amount"] * FEES[o["method"]]
        if o["method"] == "card" and o["amount"] > 10000: fee = fee + 25
        total = o["amount"] + fee
        if o.get("coupon") == "SAVE10": total = total * 0.9
        elif o.get("coupon") == "SAVE20": total = total * 0.8
        tx = {"id": "tx_%d" % random.randint(1000, 9999), "total": round(total, 2), "fee": round(fee, 2), "ts": time.time()}
        LEDGER.append(tx)
        print("processed", tx)
        return tx

    LEDGER = []

    def refund(txid, amt=None):
        for t in LEDGER:
            if t["id"] == txid:
                a = amt if amt else t["total"]
                if a > t["total"]: raise Exception("too much")
                LEDGER.append({"id": "rf_" + txid, "total": -a, "fee": 0, "ts": time.time()})
                return a
        raise Exception("not found")
    ''')
write("test-repo/payment/reports.py", '''
    from .processor import LEDGER
    def daily_total():
        s = 0
        for t in LEDGER: s += t["total"]
        return s
    def fee_total():
        s = 0
        for t in LEDGER: s = s + t["fee"]
        return s
    ''')

# ---- 2. Engineering handbook (one doc covers logging) ----
write("handbook/01-logging-standards.md", """
    # Logging Standards (Acme Engineering Handbook)
    - All services emit structured JSON logs to stdout; no log files on disk.
    - Required fields: `ts` (RFC3339), `level`, `service`, `trace_id`, `msg`.
    - Levels: ERROR pages on-call, WARN is reviewed weekly, INFO is business events, DEBUG is off in production.
    - Never log secrets, tokens, card numbers or personal data. Mask with `***`.
    - Retention: 30 days hot, 1 year cold storage. Sampling above 1,000 lines/s per pod is allowed for DEBUG only.
    - Every request log must carry the gateway request ID (`x-request-id`) so it can be traced end to end.
    """)
write("handbook/02-code-review.md", """
    # Code Review
    Two approvals for payment code, one for everything else. PRs under 400 changed lines. Reviewers respond within one business day.
    """)
write("handbook/03-oncall.md", """
    # On-call
    Rotation is weekly. Acknowledge pages within 5 minutes. Severity 1 incidents require a written post-mortem within 3 days.
    """)
write("handbook/04-release-process.md", """
    # Release Process
    Releases ship Tuesdays and Thursdays. Release notes are drafted from merged PR titles and reviewed by the release manager.
    Feature flags gate anything customer-visible. Rollback is a one-command redeploy of the previous tag.
    """)

# ---- 3. PDFs > 10 MB total: text pages + incompressible noise figures ----
def noisy_pdf(name, title, pages, target_mb):
    path = ROOT / "pdfs" / name; path.parent.mkdir(parents=True, exist_ok=True)
    c = canvas.Canvas(str(path), pagesize=letter)
    tmps = []
    per_img = int(target_mb * 1e6 / pages)
    side = int((per_img / 3) ** 0.5)
    for i in range(pages):
        c.setFont("Helvetica-Bold", 16); c.drawString(72, 740, f"{title} - section {i+1}")
        c.setFont("Helvetica", 11); y = 715
        for line in textwrap.wrap(f"Synthetic analysis {i+1}: Q{i%4+1} revenue grew {random.randint(2,14)}% against plan, driven by region {random.choice('ABCD')}. "
                                  f"Headcount stayed at {random.randint(80,400)}. Risk: supplier lead times of {random.randint(3,30)} days. "
                                  "All figures are fictional and generated for a demo.", 95):
            c.drawString(72, y, line); y -= 14
        img = Image.fromarray(np.random.randint(0, 256, (side, side, 3), dtype=np.uint8))
        tmp = ROOT / f".tmp_{name}_{i}.png"; img.save(tmp); tmps.append(tmp)
        c.drawImage(str(tmp), 72, 150, width=468, height=468 * 0.9); c.showPage()
    c.save(); [t.unlink(missing_ok=True) for t in tmps]

for n, t in [("finance-q3-review.pdf", "Q3 Finance Review"), ("supplier-contracts.pdf", "Supplier Contract Summary"),
             ("capacity-plan.pdf", "Capacity Plan 2027"), ("risk-register.pdf", "Enterprise Risk Register")]:
    noisy_pdf(n, t, pages=10, target_mb=3.0)

# ---- 4. synthetic invoice ----
c = canvas.Canvas(str(ROOT / "invoice.pdf"), pagesize=letter)
c.setFont("Helvetica-Bold", 18); c.drawString(72, 720, "INVOICE #INV-2026-0042")
c.setFont("Helvetica", 11)
for i, l in enumerate(["Bill to: Example Corp (fictional), 1 Demo Way, Testville", "Date: 2026-10-01   Due: 2026-10-31",
                       "Cloud hosting ........ 1 x 4,200.00", "Support plan ......... 1 x 1,150.00", "Training ............. 2 x 600.00",
                       "Subtotal 6,550.00   Tax 8% 524.00   TOTAL 7,074.00 USD"]):
    c.drawString(72, 690 - i * 20, l)
c.save()

# ---- 5. 12-second synthetic "meeting" video (section 8, Vertex video input) ----
import imageio.v2 as imageio
from PIL import ImageDraw
w = imageio.get_writer(str(ROOT / "meeting.mp4"), fps=10, codec="libx264", macro_block_size=None)
for f in range(120):
    im = Image.new("RGB", (640, 360), (30, 40, 60)); d = ImageDraw.Draw(im)
    d.text((20, 20), "Synthetic Sprint Planning Meeting", fill=(255, 255, 255))
    d.text((20, 50), ["Agenda: payment refactor", "Decision: ship Thursday", "Action: add unit tests"][f // 40], fill=(255, 220, 120))
    x = 40 + f * 4; d.ellipse((x, 200, x + 60, 260), fill=(90, 180, 255))
    w.append_data(np.array(im))
w.close()
print("done")
