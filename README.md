# Lagless

**Arbitrage pays LPs.** A Uniswap v4 pool on Unichain whose LP fee goes up about a second after the same pair moves on Base, so trades against the stale price pay LPs more.

Built for the Reactive Omni Buildathon, track **Every Second Counts**.

## Problem

The same pair trades on Base and Unichain. When the price moves on Base, the Unichain pool keeps quoting the old price until someone arbitrages it. That gap is profit for the arbitrageur, paid by LPs (loss-versus-rebalancing, LVR).

## How it works

```
Base Sepolia                     Reactive Network (Lasna)                 Unichain Sepolia
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
- **The hook stays small.** It accepts calls only from the Reactive callback proxy carrying the expected RVM ID, caps the fee and the shield's duration, and lets shields expire by `block.timestamp`, never by block count.
- **A control pool** (same pair, static 0.30%, no hook) on Unichain is the baseline for the results.

With the old ~7s Reactive blocks, the fee would land after the arbitrage. With Omni's ~1s blocks and instant finality, it lands while the stale window is still open.

**Limitation:** a very fast arbitrageur can still trade before the callback lands. Lagless shrinks the free window and makes the rest of it more expensive; it does not claim to block arbitrage.

## Contracts

| Contract | Chain | Role |
|---|---|---|
| `src/LaglessReactive.sol` | Reactive Lasna | Subscribes to `Swap` on both pools and makes all fee decisions |
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

There are 15 tests covering the fee curve, caps, expiry, rejection of unauthorized callers and wrong RVM IDs, rejection of static-fee pools, a fuzz test on the fee cap, and a local end-to-end loop (Base move → reactive callback → higher fee on Unichain → convergence → fee cleared).

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

# 4. Reactive contract (must be the DEPLOYER key, whose address is the RVM ID) → set REACTIVE
forge script script/Deploy.s.sol:DeployReactive --rpc-url $LASNA_RPC --private-key $PRIVATE_KEY --broadcast
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

_To be filled after testnet deployment._

| Item | Address / tx |
|---|---|
| LaglessReactive (Lasna) | |
| LaglessHook (Unichain Sepolia) | |
| Full loop: Base swap → Reactive tx → Unichain callback | |

## Results

_To be filled with at least 20 live rounds: median latency, and LP fees earned in the Lagless pool vs the control pool._

## Trust model

- Only the Unichain Sepolia callback proxy (`0x775c…66C1`), carrying the RVM ID of the reactive contract's deployer, can raise or clear a shield.
- The fee is clamped to `[baseFee, maxFee]` and a shield always expires within `maxDuration`, so a stuck or misbehaving signal can't freeze the pool.
- The hook has no owner and no admin functions.

## Sources

- Uniswap v4 deployments: https://developers.uniswap.org/docs/protocols/v4/deployments
- Reactive origins & destinations: https://dev.reactive.network/origins-and-destinations

## License

MIT
