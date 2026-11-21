#!/usr/bin/env python3
"""Print the Base Sepolia source pool's current sqrtPriceX96 (read straight from PoolManager storage).

Usage (after loading .env):  python script/base_price.py
Then set INIT_SQRT_PRICE_X96 to the printed value before DeployUnichain and DeployReactive.
"""
import os, subprocess, sys

BASE_PM = "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408"
POOLS_SLOT = "6"  # v4-core StateLibrary.POOLS_SLOT

pool = os.environ.get("BASE_POOL_ID")
rpc = os.environ.get("BASE_SEPOLIA_RPC")
if not pool or not rpc:
    sys.exit("Missing BASE_POOL_ID or BASE_SEPOLIA_RPC. Load .env first.")
run = lambda *a: subprocess.run(["cast", *a], capture_output=True, text=True, check=True).stdout.strip()
slot = run("index", "bytes32", pool, POOLS_SLOT)
word = int(run("storage", BASE_PM, slot, "--rpc-url", rpc), 16)
sqrt = word & ((1 << 160) - 1)
if sqrt == 0:
    sys.exit("Pool not initialized?")
print(f"price = {(sqrt / 2**96) ** 2:.6f}")
print(f"INIT_SQRT_PRICE_X96={sqrt}")
