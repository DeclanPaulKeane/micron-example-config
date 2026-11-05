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
