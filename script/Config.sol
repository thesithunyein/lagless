// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Chain constants. Sources:
///  - Uniswap v4: https://developers.uniswap.org/docs/protocols/v4/deployments
///  - Reactive callback proxies: https://dev.reactive.network/origins-and-destinations
library Config {
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant UNICHAIN_SEPOLIA = 1301;

    // Uniswap v4 — Base Sepolia
    address internal constant BASE_POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address internal constant BASE_SWAP_ROUTER = 0x8B5bcC363ddE2614281aD875bad385E0A785D3B9; // PoolSwapTest
    address internal constant BASE_LP_ROUTER = 0x37429cD17Cb1454C34E7F50b09725202Fd533039; // PoolModifyLiquidityTest

    // Uniswap v4 — Unichain Sepolia
    address internal constant UNI_POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address internal constant UNI_SWAP_ROUTER = 0x9140a78c1A137c7fF1c151EC8231272aF78a99A4; // PoolSwapTest
    address internal constant UNI_LP_ROUTER = 0x5fa728C0A5cfd51BEe4B060773f50554c0C8A7AB; // PoolModifyLiquidityTest

    // Reactive callback proxy on Unichain Sepolia
    address internal constant UNI_CALLBACK_PROXY = 0x775c9B990ADe401060B78D0e98684eEf8d2466C1;

    // Standard CREATE2 deployer used by forge scripts
    address internal constant CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Pool shape (identical on both chains)
    int24 internal constant TICK_SPACING = 60;
    uint24 internal constant STATIC_FEE = 3000; // 0.30% (Base source pool + Unichain control pool)
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    // Lagless parameters (tune with measured data)
    uint24 internal constant BASE_FEE = 3000; // 0.30%
    uint24 internal constant MAX_FEE = 10_000; // 1.00%
    uint32 internal constant MAX_SHIELD_DURATION = 120; // seconds, hard cap enforced by the hook
    uint32 internal constant SHIELD_DURATION = 60; // seconds per raise; refreshed while the gap stays open, cleared when prices match
    uint24 internal constant SLOPE_PIPS_PER_BP = 50;
    uint16 internal constant TRIGGER_BPS = 20;
    uint16 internal constant CLEAR_BPS = 5;
    uint24 internal constant FEE_STEP = 250;
    uint64 internal constant CALLBACK_GAS_LIMIT = 300_000;
}
