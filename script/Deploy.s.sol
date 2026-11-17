// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {MockToken} from "../src/test/MockToken.sol";
import {LaglessHook} from "../src/LaglessHook.sol";
import {LaglessReactive} from "../src/LaglessReactive.sol";
import {Config} from "./Config.sol";

abstract contract LaglessScript is Script {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant MINT = 1e27;
    ModifyLiquidityParams internal LP = ModifyLiquidityParams(-6000, 6000, 1e22, 0);

    function _currencies() internal view returns (Currency c0, Currency c1) {
        address a = vm.envAddress("TOKEN_A");
        address b = vm.envAddress("TOKEN_B");
        (c0, c1) = a < b ? (Currency.wrap(a), Currency.wrap(b)) : (Currency.wrap(b), Currency.wrap(a));
    }

    function _approve(address router) internal {
        MockToken(vm.envAddress("TOKEN_A")).approve(router, type(uint256).max);
        MockToken(vm.envAddress("TOKEN_B")).approve(router, type(uint256).max);
    }
}

/// @notice Step 1 — run on BOTH Base Sepolia and Unichain Sepolia with the same key.
/// CREATE2 + same salt => same token addresses on both chains => same token0/token1 order.
contract DeployTokens is LaglessScript {
    function run() external {
        vm.startBroadcast();
        MockToken a = new MockToken{salt: keccak256("lagless.lWETH.v1")}("Lagless WETH", "lWETH");
        MockToken b = new MockToken{salt: keccak256("lagless.lUSDC.v1")}("Lagless USDC", "lUSDC");
        a.mint(msg.sender, MINT);
        b.mint(msg.sender, MINT);
        vm.stopBroadcast();
        console2.log("TOKEN_A=%s", address(a));
        console2.log("TOKEN_B=%s", address(b));
    }
}

/// @notice Step 2 — Base Sepolia: plain v4 pool (price source) + liquidity.
contract DeployBasePool is LaglessScript {
    using PoolIdLibrary for PoolKey;

    function run() external {
        require(block.chainid == Config.BASE_SEPOLIA, "run on Base Sepolia");
        (Currency c0, Currency c1) = _currencies();
        PoolKey memory key = PoolKey(c0, c1, Config.STATIC_FEE, Config.TICK_SPACING, IHooks(address(0)));

        vm.startBroadcast();
        IPoolManager(Config.BASE_POOL_MANAGER).initialize(key, Config.SQRT_PRICE_1_1);
        _approve(Config.BASE_LP_ROUTER);
        _approve(Config.BASE_SWAP_ROUTER);
        PoolModifyLiquidityTest(Config.BASE_LP_ROUTER).modifyLiquidity(key, LP, "");
        vm.stopBroadcast();

        console2.log("BASE_POOL_ID=");
        console2.logBytes32(PoolId.unwrap(key.toId()));
    }
}

/// @notice Step 3 — Unichain Sepolia: LaglessHook + Lagless pool (dynamic fee) + control pool (static 0.30%).
contract DeployUnichain is LaglessScript {
    using PoolIdLibrary for PoolKey;

    function run() external {
        require(block.chainid == Config.UNICHAIN_SEPOLIA, "run on Unichain Sepolia");
        address rvmId = vm.envAddress("DEPLOYER"); // the EOA that will deploy LaglessReactive on Reactive
        uint256 funding = vm.envOr("HOOK_FUNDING_WEI", uint256(0.01 ether)); // pays Reactive callback fees

        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        bytes memory args = abi.encode(
            IPoolManager(Config.UNI_POOL_MANAGER),
            Config.UNI_CALLBACK_PROXY,
            rvmId,
            Config.BASE_FEE,
            Config.MAX_FEE,
            Config.MAX_SHIELD_DURATION
        );
        (address predicted, bytes32 salt) =
            HookMiner.find(Config.CREATE2_FACTORY, flags, type(LaglessHook).creationCode, args);

        (Currency c0, Currency c1) = _currencies();

        vm.startBroadcast();
        LaglessHook hook = new LaglessHook{salt: salt, value: funding}(
            IPoolManager(Config.UNI_POOL_MANAGER),
            Config.UNI_CALLBACK_PROXY,
            rvmId,
            Config.BASE_FEE,
            Config.MAX_FEE,
            Config.MAX_SHIELD_DURATION
        );
        require(address(hook) == predicted, "hook address mismatch");

        PoolKey memory lagless = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, Config.TICK_SPACING, IHooks(address(hook)));
        PoolKey memory control = PoolKey(c0, c1, Config.STATIC_FEE, Config.TICK_SPACING, IHooks(address(0)));
        IPoolManager(Config.UNI_POOL_MANAGER).initialize(lagless, Config.SQRT_PRICE_1_1);
        IPoolManager(Config.UNI_POOL_MANAGER).initialize(control, Config.SQRT_PRICE_1_1);
        _approve(Config.UNI_LP_ROUTER);
        _approve(Config.UNI_SWAP_ROUTER);
        PoolModifyLiquidityTest(Config.UNI_LP_ROUTER).modifyLiquidity(lagless, LP, "");
        PoolModifyLiquidityTest(Config.UNI_LP_ROUTER).modifyLiquidity(control, LP, "");
        vm.stopBroadcast();

        console2.log("HOOK=%s", address(hook));
        console2.log("LAGLESS_POOL_ID=");
        console2.logBytes32(PoolId.unwrap(lagless.toId()));
        console2.log("CONTROL_POOL_ID=");
        console2.logBytes32(PoolId.unwrap(control.toId()));
    }
}

/// @notice Step 4 — Reactive (Lasna): LaglessReactive subscribed to both pools.
/// Must be broadcast by DEPLOYER (its address is the RVM ID the hook trusts).
contract DeployReactive is Script {
    function run() external {
        LaglessReactive.Config memory cfg = LaglessReactive.Config({
            originChainId: Config.BASE_SEPOLIA,
            originPoolManager: Config.BASE_POOL_MANAGER,
            originPoolId: vm.envBytes32("BASE_POOL_ID"),
            destChainId: Config.UNICHAIN_SEPOLIA,
            destPoolManager: Config.UNI_POOL_MANAGER,
            destPoolId: vm.envBytes32("LAGLESS_POOL_ID"),
            hook: vm.envAddress("HOOK"),
            invertDest: false, // same token addresses on both chains (CREATE2)
            baseFee: Config.BASE_FEE,
            maxFee: Config.MAX_FEE,
            slopePipsPerBp: Config.SLOPE_PIPS_PER_BP,
            triggerBps: Config.TRIGGER_BPS,
            clearBps: Config.CLEAR_BPS,
            feeStep: Config.FEE_STEP,
            shieldDuration: Config.SHIELD_DURATION,
            callbackGasLimit: Config.CALLBACK_GAS_LIMIT
        });
        uint256 funding = vm.envOr("REACTIVE_FUNDING_WEI", uint256(1 ether)); // lREACT for reactive tx fees

        vm.startBroadcast();
        require(msg.sender == vm.envAddress("DEPLOYER"), "broadcast with DEPLOYER");
        LaglessReactive r = new LaglessReactive{value: funding}(cfg, Config.SQRT_PRICE_1_1);
        // Subscribing creates a small debt on Reactive; subscriptions stay INACTIVE until it is paid.
        r.coverDebt();
        vm.stopBroadcast();
        console2.log("REACTIVE=%s", address(r));
    }
}
