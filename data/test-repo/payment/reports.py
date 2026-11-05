from .processor import LEDGER
def daily_total():
    s = 0
    for t in LEDGER: s += t["total"]
    return s
def fee_total():
    s = 0
    for t in LEDGER: s = s + t["fee"]
    return s
