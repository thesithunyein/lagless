// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Config} from "./Config.sol";

/// @notice Exact-input swap on one of the demo pools.
/// env: POOL = base | lagless | control, AMOUNT (wei of input token), ZERO_FOR_ONE = true|false
///  - On Base: moves the "leading" price (triggers Lagless).
///  - On Unichain: acts as the arbitrageur against the Lagless or control pool.
contract Swap is Script {
    function run() external {
        string memory pool = vm.envString("POOL");
        uint256 amount = vm.envUint("AMOUNT");
        bool zeroForOne = vm.envBool("ZERO_FOR_ONE");

        address a = vm.envAddress("TOKEN_A");
        address b = vm.envAddress("TOKEN_B");
        (Currency c0, Currency c1) = a < b ? (Currency.wrap(a), Currency.wrap(b)) : (Currency.wrap(b), Currency.wrap(a));

        PoolKey memory key;
        address router;
        bytes32 p = keccak256(bytes(pool));
        if (p == keccak256("base")) {
            require(block.chainid == Config.BASE_SEPOLIA, "base pool lives on Base Sepolia");
            key = PoolKey(c0, c1, Config.STATIC_FEE, Config.TICK_SPACING, IHooks(address(0)));
            router = Config.BASE_SWAP_ROUTER;
        } else if (p == keccak256("lagless")) {
            require(block.chainid == Config.UNICHAIN_SEPOLIA, "lagless pool lives on Unichain Sepolia");
            key = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, Config.TICK_SPACING, IHooks(vm.envAddress("HOOK")));
            router = Config.UNI_SWAP_ROUTER;
        } else if (p == keccak256("control")) {
            require(block.chainid == Config.UNICHAIN_SEPOLIA, "control pool lives on Unichain Sepolia");
            key = PoolKey(c0, c1, Config.STATIC_FEE, Config.TICK_SPACING, IHooks(address(0)));
            router = Config.UNI_SWAP_ROUTER;
        } else {
            revert("POOL must be base | lagless | control");
        }

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        vm.startBroadcast();
        BalanceDelta d = PoolSwapTest(router).swap(key, params, PoolSwapTest.TestSettings(false, false), "");
        vm.stopBroadcast();
        console2.log("amount0 delta:", d.amount0());
        console2.log("amount1 delta:", d.amount1());
    }
}
