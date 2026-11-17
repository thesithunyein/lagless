#!/usr/bin/env python3
"""Run live Lagless rounds and log results to results.csv.

One round:
  1. Swap on the Base Sepolia pool (moves the "leading" price).
  2. Wait for LaglessReactive's callback: ShieldRaised on the Unichain hook (matched by price) -> latency.
  3. Arbitrage both Unichain pools with the same trade: the Lagless pool (dynamic fee) and the control pool
     (static 0.30%). Same size, same direction, so the only difference is the fee the LPs collect.
Rounds alternate direction so prices oscillate around the start instead of drifting.

Usage (PowerShell or bash, from the repo root, after loading .env):
  python script/rounds.py --sync 150     # one-time: catch the Unichain pools up to the Base price
  python script/rounds.py 20             # run 20 rounds
  python script/rounds.py 5 --amount 20  # 5 rounds of 20-token swaps

Env: DEPLOYER, TOKEN_A, TOKEN_B, HOOK, BASE_POOL_ID, LAGLESS_POOL_ID, CONTROL_POOL_ID,
     BASE_SEPOLIA_RPC, UNICHAIN_SEPOLIA_RPC
Signs with the Foundry keystore account `lagless` (override with LAGLESS_ACCOUNT). The keystore password is
asked once and passed to cast for this run only; it is never written to disk.
"""
import argparse, csv, getpass, json, os, statistics, subprocess, sys, time

SWAP_TOPIC = "0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f"
BASE_PM = "0x05e73354cfdd6745c338b50bcfdfa3aa6fa03408"
UNI_PM = "0x00b036b58a818b1bc34d502d3fe730db729e62ac"
BASE_ROUTER = "0x8B5bcC363ddE2614281aD875bad385E0A785D3B9"
UNI_ROUTER = "0x9140a78c1A137c7fF1c151EC8231272aF78a99A4"
MIN_SQRT_P1 = "4295128740"
MAX_SQRT_M1 = "1461446703485210103287273052203988822378723970341"
DYNAMIC_FEE = 8388608
SWAP_SIG = "swap((address,address,uint24,int24,address),(bool,int256,uint160),(bool,bool),bytes)"
SHIELD_SIG = "ShieldRaised(bytes32,uint24,uint40,uint160)"
CSV_PATH = "results.csv"
FIELDS = ["round", "direction", "amount_tokens", "base_tx", "callback_tx", "origin_ts", "callback_ts", "latency_s",
          "shield_fee_pips", "lagless_tx", "lagless_fee_pips", "lagless_lp_fee", "control_tx", "control_fee_pips",
          "control_lp_fee"]

PASSWORD = None


def env(name):
    v = os.environ.get(name)
    if not v:
        sys.exit(f"Missing env var {name}. Load .env first.")
    return v


def cast(*args, sign=False):
    cmd = ["cast", *args]
    if sign:
        cmd += ["--account", os.environ.get("LAGLESS_ACCOUNT", "lagless"), "--password", PASSWORD]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        safe = [("***" if PASSWORD and a == PASSWORD else a) for a in cmd]
        raise RuntimeError(f"{' '.join(safe[:4])} ... failed:\n{r.stderr.strip()[-800:]}")
    return r.stdout.strip()


def block_ts(block, rpc):
    return int(cast("block", str(block), "--field", "timestamp", "--rpc-url", rpc).split()[0], 0)


def word(data, i):
    return int(data[2 + 64 * i: 2 + 64 * (i + 1)], 16)


def signed(v, bits):
    return v - (1 << bits) if v >= 1 << (bits - 1) else v


def swap(rpc, router, pm, pool_id, key, zero_for_one, amount_wei):
    limit = MIN_SQRT_P1 if zero_for_one else MAX_SQRT_M1
    out = cast("send", router, SWAP_SIG, key, f"({str(zero_for_one).lower()},-{amount_wei},{limit})", "(false,false)",
               "0x", "--rpc-url", rpc, "--json", sign=True)
    rc = json.loads(out)
    if int(str(rc["status"]), 0) != 1:
        raise RuntimeError(f"swap reverted: {rc['transactionHash']}")
    for log in rc["logs"]:
        if log["address"].lower() == pm and log["topics"][0] == SWAP_TOPIC and log["topics"][1].lower() == pool_id.lower():
            d = log["data"]
            a0, a1 = signed(word(d, 0), 256), signed(word(d, 1), 256)
            return {"tx": rc["transactionHash"], "block": int(str(rc["blockNumber"]), 0), "sqrt": word(d, 2),
                    "fee": word(d, 5), "amount_in": -(a0 if zero_for_one else a1)}
    raise RuntimeError(f"no Swap event in {rc['transactionHash']}")


def wait_shield(hook, uni_rpc, from_block, sqrt, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        logs = json.loads(cast("logs", "--from-block", str(from_block), "--to-block", "latest", "--address", hook,
                               SHIELD_SIG, "--json", "--rpc-url", uni_rpc))
        for log in logs:
            d = log["data"]
            if word(d, 2) == sqrt:
                return {"tx": log["transactionHash"], "block": int(str(log["blockNumber"]), 0), "fee": word(d, 0)}
        time.sleep(0.5)
    return None


def main():
    global PASSWORD
    ap = argparse.ArgumentParser()
    ap.add_argument("rounds", nargs="?", type=int, default=1)
    ap.add_argument("--amount", type=float, default=20, help="swap size in tokens (default 20)")
    ap.add_argument("--sync", type=float, help="only swap AMOUNT tokens token0->token1 on both Unichain pools")
    ap.add_argument("--timeout", type=int, default=45)
    a = ap.parse_args()

    base_rpc, uni_rpc, hook = env("BASE_SEPOLIA_RPC"), env("UNICHAIN_SEPOLIA_RPC"), env("HOOK")
    t0, t1 = sorted([env("TOKEN_A"), env("TOKEN_B")], key=lambda x: int(x, 16))
    base_key = f"({t0},{t1},3000,60,0x0000000000000000000000000000000000000000)"
    lag_key = f"({t0},{t1},{DYNAMIC_FEE},60,{hook})"
    ctl_key = base_key  # control pool on Unichain has the same key as the Base source pool
    base_id, lag_id, ctl_id = env("BASE_POOL_ID"), env("LAGLESS_POOL_ID"), env("CONTROL_POOL_ID")

    PASSWORD = getpass.getpass("Keystore password (used for this run only): ")

    if a.sync:
        amt = int(a.sync * 10**18)
        for name, key, pid in (("lagless", lag_key, lag_id), ("control", ctl_key, ctl_id)):
            s = swap(uni_rpc, UNI_ROUTER, UNI_PM, pid, key, True, amt)
            print(f"sync {name}: {s['tx']}  fee={s['fee']}")
        return

    new_file = not os.path.exists(CSV_PATH)
    start = 1
    if not new_file:
        with open(CSV_PATH) as f:
            start = sum(1 for _ in f)  # header + n rows -> next round number
    amt = int(a.amount * 10**18)

    with open(CSV_PATH, "a", newline="") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS)
        if new_file:
            w.writeheader()
        for i in range(start, start + a.rounds):
            zfo = i % 2 == 0  # alternate direction each round
            uni_from = int(cast("block-number", "--rpc-url", uni_rpc))
            base = swap(base_rpc, BASE_ROUTER, BASE_PM, base_id, base_key, zfo, amt)
            shield = wait_shield(hook, uni_rpc, uni_from, base["sqrt"], a.timeout)
            lag = swap(uni_rpc, UNI_ROUTER, UNI_PM, lag_id, lag_key, zfo, amt)
            ctl = swap(uni_rpc, UNI_ROUTER, UNI_PM, ctl_id, ctl_key, zfo, amt)
            origin_ts = block_ts(base["block"], base_rpc)
            cb_ts = block_ts(shield["block"], uni_rpc) if shield else ""
            row = {
                "round": i, "direction": "0->1" if zfo else "1->0", "amount_tokens": a.amount,
                "base_tx": base["tx"], "callback_tx": shield["tx"] if shield else "",
                "origin_ts": origin_ts, "callback_ts": cb_ts,
                "latency_s": (cb_ts - origin_ts) if shield else "",
                "shield_fee_pips": shield["fee"] if shield else "",
                "lagless_tx": lag["tx"], "lagless_fee_pips": lag["fee"],
                "lagless_lp_fee": lag["amount_in"] * lag["fee"] / 1e6 / 1e18,
                "control_tx": ctl["tx"], "control_fee_pips": ctl["fee"],
                "control_lp_fee": ctl["amount_in"] * ctl["fee"] / 1e6 / 1e18,
            }
            w.writerow(row)
            f.flush()
            print(f"round {i}: latency={row['latency_s']}s  lagless fee={lag['fee']}  control fee={ctl['fee']}  "
                  f"LP fees {row['lagless_lp_fee']:.4f} vs {row['control_lp_fee']:.4f}"
                  + ("" if shield else "  (no shield: move below trigger or reactive out of funds)"))

    with open(CSV_PATH) as f:
        rows = list(csv.DictReader(f))
    lat = [float(r["latency_s"]) for r in rows if r["latency_s"]]
    lag_fees = sum(float(r["lagless_lp_fee"]) for r in rows)
    ctl_fees = sum(float(r["control_lp_fee"]) for r in rows)
    print(f"\n{len(rows)} rounds | shield hit {len(lat)}/{len(rows)} | median latency "
          f"{statistics.median(lat) if lat else 'n/a'}s | LP fees Lagless {lag_fees:.4f} vs control {ctl_fees:.4f}"
          + (f" | uplift {100 * (lag_fees / ctl_fees - 1):.0f}%" if ctl_fees else ""))


if __name__ == "__main__":
    main()
