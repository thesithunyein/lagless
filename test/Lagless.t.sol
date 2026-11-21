// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {TestERC20} from "@uniswap/v4-core/src/test/TestERC20.sol";
import {IOmniReactive, IOmniSystem, OmniReactiveBase} from "../src/omni/ReactiveOmni.sol";

import {LaglessHook} from "../src/LaglessHook.sol";
import {LaglessReactive} from "../src/LaglessReactive.sol";

/// @dev Stand-in for the Reactive Omni system contract at 0x8888...8888.
contract MockOmniSystem {
    event Subscribed(uint256 chainId, address contractAddress, uint256 topic0, uint256 topic1);
    event CallbackRequested(uint256 chainId, address recipient, uint64 gasLimit, bytes payload);

    uint256 public subscriptions;

    function subscribe(uint256 chainId, address c, uint256 t0, uint256 t1, uint256, uint256) external {
        subscriptions++;
        emit Subscribed(chainId, c, t0, t1);
    }

    function requestCallbackV_1_0(IOmniSystem.CallbackConfiguration_V_1_0 memory cfg) external {
        emit CallbackRequested(cfg.chainId, cfg.recipient, cfg.gasLimit, cfg.payload);
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }
}

contract LaglessTest is Test {
    using PoolIdLibrary for PoolKey;

    uint24 constant BASE_FEE = 3000; // 0.30%
    uint24 constant MAX_FEE = 10_000; // 1.00%
    uint32 constant MAX_DURATION = 60;
    uint160 constant SQRT_1_1 = 79228162514264337593543950336; // 2^96

    address proxy = makeAddr("callbackProxy");
    address constant SYSTEM = 0x8888888888888888888888888888888888888888;

    PoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    LaglessHook hook;
    PoolKey key; // Lagless pool
    PoolKey controlKey; // same pair, static 0.30%, no hook
    LaglessReactive reactive;

    function setUp() public {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);

        TestERC20 a = new TestERC20(1e30);
        TestERC20 b = new TestERC20(1e30);
        (Currency c0, Currency c1) = address(a) < address(b)
            ? (Currency.wrap(address(a)), Currency.wrap(address(b)))
            : (Currency.wrap(address(b)), Currency.wrap(address(a)));
        a.approve(address(swapRouter), type(uint256).max);
        b.approve(address(swapRouter), type(uint256).max);
        a.approve(address(lpRouter), type(uint256).max);
        b.approve(address(lpRouter), type(uint256).max);

        address hookAddr = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG) | (uint160(0x4444) << 144));
        deployCodeTo(
            "LaglessHook.sol:LaglessHook",
            abi.encode(IPoolManager(address(manager)), proxy, address(this), BASE_FEE, MAX_FEE, MAX_DURATION),
            hookAddr
        );
        hook = LaglessHook(payable(hookAddr));

        key = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hookAddr));
        controlKey = PoolKey(c0, c1, 3000, 60, IHooks(address(0)));
        manager.initialize(key, SQRT_1_1);
        manager.initialize(controlKey, SQRT_1_1);
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-6000, 6000, 1e21, 0);
        lpRouter.modifyLiquidity(key, lp, "");
        lpRouter.modifyLiquidity(controlKey, lp, "");

        LaglessReactive.Config memory cfg = LaglessReactive.Config({
            originChainId: 84532,
            originPoolManager: makeAddr("basePoolManager"),
            originPoolId: keccak256("basePool"),
            destChainId: 1301,
            destPoolManager: address(manager),
            destPoolId: PoolId.unwrap(key.toId()),
            hook: hookAddr,
            invertDest: false,
            baseFee: BASE_FEE,
            maxFee: MAX_FEE,
            slopePipsPerBp: 50,
            triggerBps: 20,
            clearBps: 5,
            feeStep: 250,
            shieldDuration: 10,
            callbackGasLimit: 300_000
        });
        vm.etch(SYSTEM, address(new MockOmniSystem()).code);
        reactive = new LaglessReactive(cfg, SQRT_1_1);
        hook.setReactive(address(reactive));
    }

    function _react(IOmniReactive.LogRecord memory log) internal {
        vm.prank(SYSTEM);
        reactive.react(log);
    }

    // ---------------------------------------------------------------- helpers

    function _swap(PoolKey memory k, int256 amountSpecified) internal returns (int128 out) {
        BalanceDelta d = swapRouter.swap(
            k,
            SwapParams(true, amountSpecified, TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        return d.amount1();
    }

    function _swapLog(uint256 chainId, address pm, bytes32 poolId, uint160 sqrtPriceX96)
        internal
        pure
        returns (IOmniReactive.LogRecord memory log)
    {
        log.chainId = chainId;
        log.contractAddress = pm;
        log.topic0 = 0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f;
        log.topic1 = uint256(poolId);
        log.data = abi.encode(int128(-1), int128(1), sqrtPriceX96, uint128(1), int24(0), uint24(3000));
    }

    /// @dev sqrtPriceX96 for price = 1 + bps/10000 (approx, via integer sqrt).
    function _sqrtForBps(uint256 bps) internal pure returns (uint160) {
        uint256 priceX192 = (uint256(SQRT_1_1) * SQRT_1_1 / 10_000) * (10_000 + bps);
        return uint160(_isqrt(priceX192));
    }

    function _isqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /// @dev Takes callbacks requested from the system contract and delivers them like Reactive Network would:
    ///      from the callback proxy, with the first argument replaced by the reactive contract's address.
    function _deliverCallbacks(Vm.Log[] memory logs) internal returns (uint256 delivered) {
        bytes32 cbTopic = keccak256("CallbackRequested(uint256,address,uint64,bytes)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] != cbTopic) continue;
            (,,, bytes memory payload) = abi.decode(logs[i].data, (uint256, address, uint64, bytes));
            bytes4 sel;
            assembly { sel := mload(add(payload, 32)) }
            bytes memory rest = new bytes(payload.length - 36);
            for (uint256 j; j < rest.length; j++) rest[j] = payload[36 + j];
            bytes memory call = abi.encodePacked(sel, abi.encode(address(reactive)), rest);
            vm.prank(proxy);
            (bool ok,) = address(hook).call(call);
            require(ok, "callback failed");
            delivered++;
        }
    }

    // ---------------------------------------------------------------- hook tests

    function test_baseFeeWhenNoShield() public view {
        assertEq(hook.currentFee(key.toId()), BASE_FEE);
    }

    function test_swapMatchesControlPoolWithoutShield() public {
        int128 outLagless = _swap(key, -1e18);
        int128 outControl = _swap(controlKey, -1e18);
        assertEq(outLagless, outControl);
    }

    function test_shieldRaisesFeeAndCutsArbOutput() public {
        vm.prank(proxy);
        hook.setShield(address(reactive), key.toId(), 8000, 10, SQRT_1_1);
        assertEq(hook.currentFee(key.toId()), 8000);
        int128 outLagless = _swap(key, -1e18);
        int128 outControl = _swap(controlKey, -1e18);
        assertLt(outLagless, outControl, "shielded swap must pay more fee");
    }

    function test_shieldExpiresByTimestamp() public {
        vm.prank(proxy);
        hook.setShield(address(reactive), key.toId(), 8000, 10, SQRT_1_1);
        vm.warp(block.timestamp + 10);
        assertEq(hook.currentFee(key.toId()), BASE_FEE);
    }

    function test_feeAndDurationAreCapped() public {
        vm.prank(proxy);
        hook.setShield(address(reactive), key.toId(), 900_000, 3600, SQRT_1_1);
        (uint24 fee, uint40 expiry,) = hook.shields(key.toId());
        assertEq(fee, MAX_FEE);
        assertEq(expiry, block.timestamp + MAX_DURATION);
    }

    function test_clearShield() public {
        vm.startPrank(proxy);
        hook.setShield(address(reactive), key.toId(), 8000, 10, SQRT_1_1);
        hook.clearShield(address(reactive), key.toId());
        vm.stopPrank();
        assertEq(hook.currentFee(key.toId()), BASE_FEE);
    }

    function test_revert_notCallbackProxy() public {
        vm.expectRevert(abi.encodeWithSelector(LaglessHook.NotCallbackProxy.selector, address(this)));
        hook.setShield(address(reactive), key.toId(), 8000, 10, SQRT_1_1);
    }

    function test_revert_wrongReactiveSender() public {
        vm.prank(proxy);
        vm.expectRevert(abi.encodeWithSelector(LaglessHook.NotReactive.selector, address(0xBAD)));
        hook.setShield(address(0xBAD), key.toId(), 8000, 10, SQRT_1_1);
    }

    function test_revert_setReactiveOnlyOnce() public {
        vm.expectRevert(LaglessHook.ReactiveAlreadySet.selector);
        hook.setReactive(address(0xBEEF));
    }

    function test_revert_setReactiveOnlyOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(LaglessHook.NotOwner.selector);
        hook.setReactive(address(0xBEEF));
    }

    function test_reactive_subscribesToBothPools() public view {
        assertEq(MockOmniSystem(SYSTEM).subscriptions(), 2);
    }

    function test_revert_reactOnlySystem() public {
        IOmniReactive.LogRecord memory log = _swapLog(84532, makeAddr("basePoolManager"), keccak256("basePool"), _sqrtForBps(60));
        vm.expectRevert(abi.encodeWithSelector(OmniReactiveBase.NotSystem.selector, address(this)));
        reactive.react(log);
    }

    function test_revert_staticFeePoolCannotUseHook() public {
        PoolKey memory bad = PoolKey(key.currency0, key.currency1, 3000, 10, key.hooks);
        vm.expectRevert();
        manager.initialize(bad, SQRT_1_1);
    }

    // ---------------------------------------------------------------- reactive tests

    function test_deviationMath() public view {
        assertEq(reactive.deviationBps(SQRT_1_1, SQRT_1_1), 0);
        uint256 dev = reactive.deviationBps(_sqrtForBps(100), SQRT_1_1);
        assertApproxEqAbs(dev, 100, 1);
        dev = reactive.deviationBps(SQRT_1_1, _sqrtForBps(100)); // other direction ≈ 99 bps
        assertApproxEqAbs(dev, 99, 1);
    }

    function test_reactive_smallMoveDoesNothing() public {
        vm.recordLogs();
        _react(_swapLog(84532, makeAddr("basePoolManager"), keccak256("basePool"), _sqrtForBps(10)));
        assertEq(_deliverCallbacks(vm.getRecordedLogs()), 0);
        assertEq(reactive.lastSentFee(), 0);
    }

    function test_reactive_ignoresUnknownPool() public {
        vm.recordLogs();
        _react(_swapLog(84532, makeAddr("basePoolManager"), keccak256("otherPool"), _sqrtForBps(500)));
        assertEq(_deliverCallbacks(vm.getRecordedLogs()), 0);
    }

    /// @notice End-to-end loop: Base move → reactive decision → callback → Unichain fee up → convergence → fee down.
    function test_fullLoop_raiseThenClear() public {
        bytes32 destPoolId = PoolId.unwrap(key.toId());

        // 1. Base price moves +60 bps → shield = 3000 + 50*60 = 6000 pips
        vm.recordLogs();
        _react(_swapLog(84532, makeAddr("basePoolManager"), keccak256("basePool"), _sqrtForBps(60)));
        assertEq(_deliverCallbacks(vm.getRecordedLogs()), 1);
        uint24 fee = hook.currentFee(key.toId());
        assertApproxEqAbs(fee, 6000, 100);

        // 2. Arb on Unichain pays the higher fee vs control pool
        assertLt(_swap(key, -1e18), _swap(controlKey, -1e18));

        // 3. Unichain price converges to Base → reactive clears the shield
        vm.recordLogs();
        _react(_swapLog(1301, address(manager), destPoolId, _sqrtForBps(59)));
        assertEq(_deliverCallbacks(vm.getRecordedLogs()), 1);
        assertEq(hook.currentFee(key.toId()), BASE_FEE);
        assertEq(reactive.lastSentFee(), 0);
    }

    function test_reactive_feeCappedAtMax() public {
        vm.recordLogs();
        _react(_swapLog(84532, makeAddr("basePoolManager"), keccak256("basePool"), _sqrtForBps(2000)));
        _deliverCallbacks(vm.getRecordedLogs());
        assertEq(hook.currentFee(key.toId()), MAX_FEE);
    }

    /// @notice While prices stay apart, the raise is renewed before it lapses, so a bot can't just wait it out.
    function test_reactive_keepsShieldAliveUntilPricesMatch() public {
        bytes32 destPoolId = PoolId.unwrap(key.toId());
        vm.recordLogs();
        _react(_swapLog(84532, makeAddr("basePoolManager"), keccak256("basePool"), _sqrtForBps(60)));
        assertEq(_deliverCallbacks(vm.getRecordedLogs()), 1);
        uint64 until = reactive.shieldUntil();
        assertEq(until, block.timestamp + 10);

        // Early destination swap that barely moves the gap: nothing to send.
        vm.recordLogs();
        _react(_swapLog(1301, address(manager), destPoolId, _sqrtForBps(1)));
        assertEq(_deliverCallbacks(vm.getRecordedLogs()), 0);

        // Past half its life with the gap still open: renewed instead of lapsing.
        vm.warp(block.timestamp + 6);
        vm.recordLogs();
        _react(_swapLog(1301, address(manager), destPoolId, _sqrtForBps(2)));
        assertEq(_deliverCallbacks(vm.getRecordedLogs()), 1);
        assertEq(reactive.shieldUntil(), block.timestamp + 10);
        vm.warp(block.timestamp + 6); // would have expired without the renewal
        assertGt(hook.currentFee(key.toId()), BASE_FEE);

        // Prices match: cleared, and the timer resets.
        vm.recordLogs();
        _react(_swapLog(1301, address(manager), destPoolId, _sqrtForBps(59)));
        assertEq(_deliverCallbacks(vm.getRecordedLogs()), 1);
        assertEq(hook.currentFee(key.toId()), BASE_FEE);
        assertEq(reactive.shieldUntil(), 0);
    }

    function testFuzz_feeNeverExceedsMax(uint16 bps) public view {
        LaglessReactive.Config memory c;
        (,,,,,,,, c.baseFee, c.maxFee, c.slopePipsPerBp,,,,,) = reactive.cfg();
        uint24 fee = reactive.feeFor(uint256(bps) * 7, c);
        assertLe(fee, MAX_FEE);
        assertGe(fee, BASE_FEE);
    }
}
