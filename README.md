<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="brand/lagless-lockup-dark.svg">
    <img src="brand/lagless-lockup.svg" alt="Lagless" width="280">
  </picture>
</p>

<h3 align="center">Arbitrage should pay your LPs</h3>

<p align="center">
  Lagless raises a Uniswap v4 pool's fee on Unichain about two seconds after the same pair moves on Base,<br>
  then lowers it again when prices match. Fully on-chain, powered by Reactive Network.
</p>

<p align="center">
  <a href="https://uselagless.vercel.app"><b>Website</b></a> ·
  <a href="#how-it-works">How it works</a> ·
  <a href="#results">Results</a> ·
  <a href="#deploy-testnets-0">Deploy</a> ·
  <a href="#deployed-addresses-and-transactions">Contracts</a>
</p>

<p align="center">
  <img alt="Tests" src="https://img.shields.io/badge/tests-19%20passing-101828">
  <img alt="Median latency" src="https://img.shields.io/badge/median%20latency-2s-3D4FF2">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-101828">
</p>

## Problem

The same pair trades on Base and Unichain. When the price moves on Base, the Unichain pool keeps quoting the old price until someone arbitrages it. That gap is profit for the arbitrageur, paid by LPs (loss-versus-rebalancing, LVR).

## How it works

```
Base Sepolia                     Reactive Omni (Lasna)                 Unichain Sepolia
────────────                     ────────────────────────                 ────────────────
v4 pool ──Swap(sqrtPriceX96)──▶  LaglessReactive.react()                  
                                 • decode Base price                      
                                 • deviation vs Unichain price (bps)      
                                 • fee = min(max, base + slope × dev)     
                                 • emit Callback ───────────────────────▶ LaglessHook.setShield()
                                                                          • fee raised for N seconds
                                                                          • beforeSwap returns fee | OVERRIDE
Lagless pool ◀──Swap──────────── (arbitrage on Unichain)                  
             ──Swap(sqrtPriceX96)▶ react(): prices converged? ──────────▶ LaglessHook.clearShield()
```

- **All decisions happen in the reactive contract**: decoding prices, measuring deviation, choosing the fee, and deciding when to refresh or clear.
- **The hook stays small.** It accepts calls only from the Reactive callback proxy, and only when Reactive Omni has stamped the payload with the LaglessReactive contract's address. It caps the fee and the shield's duration, and lets shields expire by `block.timestamp`, never by block count.
- **Built for Reactive Omni.** `react()` is called directly by the Omni system contract (`0x8888…8888`, guarded by `onlySystem`; no ReactVM), subscriptions and callbacks go through that system contract (`requestCallbackV_1_0`), and fees are prepaid into the contract's Omni reserves. `src/omni/ReactiveOmni.sol` holds ABI-compatible bindings for solc 0.8.26, because `reactive-lib-omni` requires ^0.8.29 while Uniswap v4 pins 0.8.26.
- **A control pool** (same pair, static 0.30%, no hook) on Unichain is the baseline for the results.

With the old ~7s Reactive blocks, the fee would land after the arbitrage. With Omni's ~1s blocks and instant finality, it lands while the stale window is still open.

**Limitation:** a very fast arbitrageur can still trade before the callback lands. Lagless shrinks the free window and makes the rest of it more expensive; it does not claim to block arbitrage.

## Contracts

| Contract | Chain | Role |
|---|---|---|
| `src/LaglessReactive.sol` | Reactive Omni (Lasna) | Subscribes to `Swap` on both pools and makes all fee decisions |
| `src/omni/ReactiveOmni.sol` | — | Minimal Reactive Omni system-contract bindings (solc 0.8.26) |
| `src/LaglessHook.sol` | Unichain Sepolia | v4 dynamic-fee hook (`beforeInitialize`, `beforeSwap`) |
| `src/test/MockToken.sol` | Base + Unichain Sepolia | Open-mint test tokens, deployed with CREATE2 so both chains get the same addresses |

## Parameters (`script/Config.sol`)

| Parameter | Value |
|---|---|
| Base fee | 0.30% (3000 pips) |
| Max shield fee | 1.00% |
| Trigger | 20 bps price gap |
| Slope | +50 pips per bp of gap |
| Clear | gap ≤ 5 bps |
| Shield duration | 10 s per raise/refresh, hard cap 60 s on the hook |

## Run the tests

```bash
forge install   # or: git submodule update --init --recursive
forge test -vv
```

There are 19 tests covering the fee curve, caps, expiry, rejection of unauthorized callers and wrong reactive senders, the one-time `setReactive` binding, `onlySystem` on `react()`, rejection of static-fee pools, a fuzz test on the fee cap, and a local end-to-end loop (Base move → reactive callback → higher fee on Unichain → convergence → fee cleared).

## Deploy (testnets, $0)

You need a **dev-only** wallet funded on Base Sepolia, Unichain Sepolia and Reactive Lasna (lREACT). Copy `.env.example` to `.env`, fill it in, then `source .env`.

```bash
# 1. Tokens (same addresses on both chains)
forge script script/Deploy.s.sol:DeployTokens --rpc-url $BASE_SEPOLIA_RPC --private-key $PRIVATE_KEY --broadcast
forge script script/Deploy.s.sol:DeployTokens --rpc-url $UNICHAIN_SEPOLIA_RPC --private-key $PRIVATE_KEY --broadcast
#    → set TOKEN_A, TOKEN_B

# 2. Base source pool → set BASE_POOL_ID
forge script script/Deploy.s.sol:DeployBasePool --rpc-url $BASE_SEPOLIA_RPC --private-key $PRIVATE_KEY --broadcast

# 3. Hook + Lagless pool + control pool on Unichain → set HOOK, LAGLESS_POOL_ID, CONTROL_POOL_ID
forge script script/Deploy.s.sol:DeployUnichain --rpc-url $UNICHAIN_SEPOLIA_RPC --private-key $PRIVATE_KEY --broadcast

# 4. Reactive contract on Reactive Omni, prepaid with OMNI_RESERVE_WEI (default 0.1 lREACT) → set REACTIVE
forge script script/Deploy.s.sol:DeployReactive --rpc-url $LASNA_RPC --private-key $PRIVATE_KEY --broadcast

# 5. Bind the hook to the reactive contract (one-time)
forge script script/Deploy.s.sol:SetReactive --rpc-url $UNICHAIN_SEPOLIA_RPC --private-key $PRIVATE_KEY --broadcast
```

If the reactive contract's subscriptions show **INACTIVE** on Reactscan, the contract has debt on the **Omni** ledger (`0x8888…8888`). Top up its Omni reserves; `depositTo` settles the debt first:

```bash
cast send 0x8888888888888888888888888888888888888888 "depositTo(address)" $REACTIVE --value 0.1ether --rpc-url $LASNA_RPC --private-key $PRIVATE_KEY
```

Note: depositing to the legacy service `0x…fffFfF` or calling `coverDebt()` (reactive-lib's default vendor) does **not** clear Omni-era debt.

## Run a live round

```bash
# Move the Base price (leading venue)
POOL=base AMOUNT=50000000000000000000 ZERO_FOR_ONE=true \
  forge script script/Swap.s.sol:Swap --rpc-url $BASE_SEPOLIA_RPC --private-key $PRIVATE_KEY --broadcast

# Measure Base swap → Unichain ShieldRaised (prints a CSV row)
python3 script/latency.py <base_swap_tx_hash>

# Arbitrage both Unichain pools and compare
POOL=lagless AMOUNT=... ZERO_FOR_ONE=true forge script script/Swap.s.sol:Swap --rpc-url $UNICHAIN_SEPOLIA_RPC --private-key $PRIVATE_KEY --broadcast
POOL=control AMOUNT=... ZERO_FOR_ONE=true forge script script/Swap.s.sol:Swap --rpc-url $UNICHAIN_SEPOLIA_RPC --private-key $PRIVATE_KEY --broadcast
```

## Live rounds (automated)

`script/rounds.py` runs full rounds and appends one row per round to `results.csv`: Base move → wait for the shield on Unichain (latency) → the same arbitrage trade on the Lagless pool and on the control pool (LP fee collected by each).

```bash
python3 script/rounds.py --sync 150   # one-time: align the Unichain pools with the Base price
python3 script/rounds.py 20           # 20 rounds, alternating direction
python3 script/rounds.py 10 --race    # arbitrage fires right after the Base move (fast bot)
```

It signs with the Foundry keystore account `lagless` and asks for the password once per run.

## Deployed addresses and transactions

| Item | Address / tx |
|---|---|
| Tokens lWETH / lUSDC (same address on Base + Unichain Sepolia) | `0x9063cE4EBFBA81206E621158B7586024eeC6d0B3` / `0x41eFe7a3A065a5094Eb88c9F486238Fc227E7893` |
| Base Sepolia source pool id | `0xba49af2a7fd75f159181a85b3a2dabff571a9ea24eba7cc3bf943f5d9b512ffd` |
| LaglessReactive (Reactive Omni, Lasna) | [`0x1eee3853d5C0dEB9702eC4e7EEd205ff58d878e5`](https://lasna.reactscan.net/address/0x1eee3853d5C0dEB9702eC4e7EEd205ff58d878e5) |
| LaglessHook (Unichain Sepolia) | [`0x03A696938EF795a0B1496FC407CF7B53F4702080`](https://sepolia.uniscan.xyz/address/0x03A696938EF795a0B1496FC407CF7B53F4702080) |
| Lagless pool id (Unichain, dynamic fee) | `0x5c20493e45711a98dd4fd618626e5dd17b13d3c3d68690c9a4c7c70460bcbfd9` |
| Control pool id (Unichain, static 0.30%) | `0xba49af2a7fd75f159181a85b3a2dabff571a9ea24eba7cc3bf943f5d9b512ffd` |

### First live loop (Nov 17, 2026)

| Step | Chain | Tx | Block time |
|---|---|---|---|
| 1. Swap moves the price | Base Sepolia | [`0x4a7debcf…fd0a2b`](https://sepolia.basescan.org/tx/0x4a7debcfbb53a749d61c496c76f26bc7bac32b839cf79064dadd33c648fd0a2b) | 1794911210 |
| 2. `react()` decides, requests callback | Reactive Omni | [`0xedc886a7…420f9f`](https://lasna.reactscan.net/tx/0xedc886a79064459e38ec3e2372d8fd51c024054065f8bfdad268726178420f9f) | 1794911210 |
| 3. `setShield` raises the LP fee to 1.00% | Unichain Sepolia | [`0x77ec25f3…d2480`](https://sepolia.uniscan.xyz/tx/0x77ec25f373f91e53071b8ca7162e940ad0ee758d0bcbb66dfe366737d65d2480) | 1794911212 |

Base swap → Unichain fee change: **2 s** (block timestamps, 1 s resolution).

## Results

24 live rounds on testnet (Nov 17, 2026), `script/rounds.py`, 20-token swaps alternating direction:

| Metric | Result |
|---|---|
| Rounds where the shield landed | **24 / 24** |
| Base swap → Unichain fee change (median) | **2 s** |
| Latency distribution | 1 s ×1, 2 s ×14, 3 s ×8, 4 s ×1 (block timestamps, 1 s resolution) |
| Shield fee for a ~0.4% Base move | 0.495–0.50% (vs 0.30% base) |
| LP fees from the same arbitrage trades | **2.388** (Lagless) vs **1.440** (control) → **+66%** |

### Fast arbitrage (race mode)

The 24 rounds above wait for the shield before trading, so they show the best case. Race mode sends the arbitrage the moment the Base swap is confirmed, like a bot watching Base over a public RPC:

```bash
python3 script/rounds.py 10 --race
```

10 race rounds on testnet (Nov 21, 2026):

| Metric | Result |
|---|---|
| Base swap → Unichain fee change (median) | **2 s** (2 s ×6, 3 s ×4) |
| Base swap → arbitrage landed on Unichain | 3–4 s, always 1–2 blocks **after** the shield |
| Arbitrage trades that paid the higher fee | **10 / 10** (0.495–0.50% vs 0.30%) |
| LP fees, Lagless vs control | **0.995** vs **0.600** → **+66%** |

Every row, with all transaction hashes, is in [`results.csv`](results.csv).

### What this means

- An arbitrageur who reacts to the **confirmed** Base swap, as most bots on public infrastructure do, lands after the shield and pays LPs **+66%** in this setup.
- A faster bot can still win. One that reads Base's 200 ms pre-confirmations, or sits next to the Unichain sequencer, can trade inside the ~2 s window and pay the base 0.30%. These runs don't show that case because the test script isn't that fast; it is a real limit, not a solved one.
- Lagless shortens the free window to about 2 seconds. On legacy Reactive (~7 s blocks) the same design would leave a window several times longer. Omni's ~1 s blocks are what make it useful.

The website splits every round into "after the fee rose" and "before the fee rose", read live from the chain.

## Trust model

- Only the Unichain Sepolia callback proxy (`0x775c…66C1`), with a payload that Reactive Omni stamped with the LaglessReactive address, can raise or clear a shield.
- The deployer binds the hook to that reactive address once (`setReactive`); it can never be changed afterwards.
- The fee is clamped to `[baseFee, maxFee]` and a shield always expires within `maxDuration`, so a stuck or misbehaving signal can't freeze the pool.
- Apart from that one-time binding, the hook has no admin functions.

## Sources

- Uniswap v4 deployments: https://developers.uniswap.org/docs/protocols/v4/deployments
- Reactive origins & destinations: https://dev.reactive.network/origins-and-destinations

## License

MIT

## Background

Lagless was first built for the Reactive Omni Buildathon (track: Every Second Counts).
