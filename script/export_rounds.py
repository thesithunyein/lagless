#!/usr/bin/env python3
"""Export results.csv to web/rounds.json for the website.

Public RPCs prune old logs, so the site shows recorded rounds from this snapshot
and adds anything newer straight from the chain. Run after adding rounds:
    python script/export_rounds.py
"""
import csv, json, os

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
rows = list(csv.DictReader(open(os.path.join(root, "results.csv"), newline="")))
out = []
for r in rows:
    if r["mode"].startswith("excluded") or not r["latency_s"]:
        continue
    out.append({
        "round": int(r["round"]), "mode": r["mode"], "zfo": r["direction"] == "0->1",
        "amount": float(r["amount_tokens"]),
        "baseTx": r["base_tx"], "baseTs": int(r["origin_ts"]),
        "shieldTx": r["callback_tx"], "shieldTs": int(r["callback_ts"]), "shieldFee": int(r["shield_fee_pips"]),
        "lagTx": r["lagless_tx"], "lagFee": int(r["lagless_fee_pips"]),
        "ctlTx": r["control_tx"], "ctlFee": int(r["control_fee_pips"]),
    })
json.dump(out, open(os.path.join(root, "web", "rounds.json"), "w"), separators=(",", ":"))
print(f"wrote {len(out)} rounds to web/rounds.json")
