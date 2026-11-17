// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {AbstractCallback} from "@reactive/abstract-base/AbstractCallback.sol";

/// @title LaglessHook
/// @notice Uniswap v4 dynamic-fee hook. A Reactive Network contract watching the same pair on another chain
///         raises this pool's LP fee for a short, timestamp-bounded window when the remote price moves, so
///         arbitrage against the stale local price pays LPs a higher fee.
/// @dev Only the Reactive callback proxy, carrying the expected RVM ID, can raise or clear a shield.
contract LaglessHook is IHooks, AbstractCallback {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    struct Shield {
        uint24 fee; // LP fee in pips (1_000_000 = 100%) while active
        uint40 expiry; // unix timestamp; shield inactive at/after this time
        uint160 refSqrtPriceX96; // remote (leading) price that triggered the shield
    }

    error NotPoolManager();
    error HookNotImplemented();
    error MustUseDynamicFee();
    error InvalidConfig();

    event ShieldRaised(PoolId indexed poolId, uint24 fee, uint40 expiry, uint160 refSqrtPriceX96);
    event ShieldCleared(PoolId indexed poolId);

    IPoolManager public immutable poolManager;
    /// @notice Fee charged when no shield is active (pips).
    uint24 public immutable baseFee;
    /// @notice Hard cap for any shield fee (pips).
    uint24 public immutable maxFee;
    /// @notice Hard cap for a shield's lifetime (seconds), so a stuck shield always decays.
    uint32 public immutable maxDuration;

    mapping(PoolId => Shield) public shields;

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @param _poolManager Uniswap v4 PoolManager on this chain.
    /// @param _callbackProxy Reactive callback proxy on this chain.
    /// @param _rvmId Address that deploys the reactive contract (its RVM ID). Set explicitly because this hook
    ///        is deployed through a CREATE2 factory, so msg.sender is not the RVM owner.
    constructor(
        IPoolManager _poolManager,
        address _callbackProxy,
        address _rvmId,
        uint24 _baseFee,
        uint24 _maxFee,
        uint32 _maxDuration
    ) payable AbstractCallback(_callbackProxy) {
        if (_rvmId == address(0) || _baseFee > _maxFee || _maxFee > LPFeeLibrary.MAX_LP_FEE || _maxDuration == 0) {
            revert InvalidConfig();
        }
        poolManager = _poolManager;
        rvm_id = _rvmId;
        baseFee = _baseFee;
        maxFee = _maxFee;
        maxDuration = _maxDuration;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
    }

    // ---------------------------------------------------------------- Reactive callbacks

    /// @notice Raise (or refresh) the shield for a pool. Called by the Reactive callback proxy.
    /// @dev First argument is overwritten with the RVM ID by Reactive Network.
    function setShield(address rvmId, PoolId poolId, uint24 fee, uint32 duration, uint160 refSqrtPriceX96)
        external
        authorizedSenderOnly
        rvmIdOnly(rvmId)
    {
        if (fee > maxFee) fee = maxFee;
        if (fee < baseFee) fee = baseFee;
        if (duration > maxDuration) duration = maxDuration;
        uint40 expiry = uint40(block.timestamp + duration);
        shields[poolId] = Shield(fee, expiry, refSqrtPriceX96);
        emit ShieldRaised(poolId, fee, expiry, refSqrtPriceX96);
    }

    /// @notice Clear the shield once prices have converged. Called by the Reactive callback proxy.
    function clearShield(address rvmId, PoolId poolId) external authorizedSenderOnly rvmIdOnly(rvmId) {
        delete shields[poolId];
        emit ShieldCleared(poolId);
    }

    // ---------------------------------------------------------------- Views

    /// @notice LP fee a swap on this pool would pay right now (pips).
    function currentFee(PoolId poolId) public view returns (uint24) {
        Shield memory s = shields[poolId];
        return block.timestamp < s.expiry ? s.fee : baseFee;
    }

    // ---------------------------------------------------------------- Hooks

    function beforeInitialize(address, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint24 fee = currentFee(key.toId());
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    // Unused hooks: flags are not set, so the PoolManager never calls them.
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
