# Lagless

**Arbitrage pays LPs.** A Uniswap v4 pool on Unichain whose LP fee goes up about a second after the same pair moves on Base, so trades against the stale price pay LPs more.

Built for the Reactive Omni Buildathon, track **Every Second Counts**.

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

## Demo loop

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

_To be filled with at least 20 live rounds: median latency, and LP fees earned in the Lagless pool vs the control pool._

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
