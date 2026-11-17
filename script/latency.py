#!/usr/bin/env python3
"""Measure the Lagless loop for one Base swap: Base Swap -> Reactive -> Unichain ShieldRaised.

Usage:
  python3 script/latency.py <base_swap_tx_hash> [--wait 30]

Env: BASE_SEPOLIA_RPC, UNICHAIN_SEPOLIA_RPC, HOOK
Matches the Unichain ShieldRaised event whose refSqrtPriceX96 equals the sqrtPriceX96 emitted by the Base swap,
then prints one CSV row (paste into the Metrics sheet):
  base_tx,unichain_tx,origin_block_ts,callback_block_ts,latency_s,shield_fee_pips
Note: block timestamps have 1-second resolution, so latency is reported in whole seconds.
"""
import json, os, subprocess, sys, time

SWAP_TOPIC = "0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f"
BASE_PM = "0x05e73354cfdd6745c338b50bcfdfa3aa6fa03408"


def cast(*args):
    return subprocess.check_output(["cast", *args], text=True).strip()


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    tx = sys.argv[1]
    wait = int(sys.argv[sys.argv.index("--wait") + 1]) if "--wait" in sys.argv else 30
    base_rpc, uni_rpc, hook = os.environ["BASE_SEPOLIA_RPC"], os.environ["UNICHAIN_SEPOLIA_RPC"], os.environ["HOOK"]

    receipt = json.loads(cast("receipt", tx, "--json", "--rpc-url", base_rpc))
    swap = next(l for l in receipt["logs"] if l["address"].lower() == BASE_PM and l["topics"][0] == SWAP_TOPIC)
    data = swap["data"][2:]
    sqrt_price = int(data[64 * 2:64 * 3], 16)  # 3rd word: sqrtPriceX96
    origin_ts = int(cast("block", str(int(receipt["blockNumber"], 16)), "timestamp", "--rpc-url", base_rpc))

    start = int(cast("block-number", "--rpc-url", uni_rpc)) - 120
    deadline = time.time() + wait
    while time.time() < deadline:
        logs = json.loads(cast("logs", "--from-block", str(start), "--to-block", "latest", "--address", hook,
                               "ShieldRaised(bytes32,uint24,uint40,uint160)", "--json", "--rpc-url", uni_rpc))
        for l in logs:
            d = l["data"][2:]
            fee, ref = int(d[0:64], 16), int(d[128:192], 16)
            if ref == sqrt_price:
                bn = int(l["blockNumber"], 16)
                cb_ts = int(cast("block", str(bn), "timestamp", "--rpc-url", uni_rpc))
                print("base_tx,unichain_tx,origin_block_ts,callback_block_ts,latency_s,shield_fee_pips")
                print(f"{tx},{l['transactionHash']},{origin_ts},{cb_ts},{cb_ts - origin_ts},{fee}")
                return
        time.sleep(1)
    sys.exit(f"No ShieldRaised matching sqrtPriceX96={sqrt_price} within {wait}s "
             "(move was below trigger, or the reactive contract needs funds).")


if __name__ == "__main__":
    main()
