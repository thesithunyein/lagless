// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OmniReactiveBase, IOmniSystem} from "./omni/ReactiveOmni.sol";

/// @title LaglessReactive
/// @notice Runs on Reactive Network. Watches the same Uniswap v4 pair on a "leading" chain (Base) and a
///         "lagging" chain (Unichain). When the leading price moves away from the lagging pool's price, it
///         sends a callback that raises the lagging pool's LP fee; when prices converge again it clears it.
/// @dev All decision logic lives here: price decoding, deviation, fee curve, raise/refresh/clear.
contract LaglessReactive is OmniReactiveBase {
    /// @dev keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)") — Uniswap v4 PoolManager.
    uint256 public constant SWAP_TOPIC_0 = 0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f;
    uint256 internal constant ONE = 1e18;
    uint256 internal constant Q192 = 1 << 192;
    uint256 internal constant LP_FEE_DENOMINATOR = 1_000_000;

    struct Config {
        uint256 originChainId; // leading chain (Base Sepolia: 84532)
        address originPoolManager;
        bytes32 originPoolId;
        uint256 destChainId; // lagging chain (Unichain Sepolia: 1301)
        address destPoolManager;
        bytes32 destPoolId;
        address hook; // LaglessHook on destination chain
        bool invertDest; // true if token0/token1 order on destination is reversed vs origin
        uint24 baseFee; // pips
        uint24 maxFee; // pips
        uint24 slopePipsPerBp; // fee added per bp of deviation
        uint16 triggerBps; // raise shield at/above this deviation
        uint16 clearBps; // clear shield at/below this deviation
        uint24 feeStep; // only refresh if the fee changes by at least this much (pips)
        uint32 shieldDuration; // seconds (enforced on destination with block.timestamp)
        uint64 callbackGasLimit;
    }

    event ShieldDecision(uint256 deviationBps, uint24 fee, bool raised, bool cleared);

    error NotOwner();

    Config public cfg;
    address public immutable owner;

    // Contract state (Omni: single instance, no ReactVM copy)
    uint160 public originSqrtPriceX96;
    uint160 public destSqrtPriceX96; // already in origin orientation
    uint24 public lastSentFee; // 0 = no active shield as far as this contract knows

    constructor(Config memory _cfg, uint160 initialDestSqrtPriceX96) payable {
        require(_cfg.baseFee <= _cfg.maxFee && _cfg.clearBps < _cfg.triggerBps, "bad config");
        cfg = _cfg;
        owner = msg.sender;
        destSqrtPriceX96 = _orient(initialDestSqrtPriceX96, _cfg.invertDest);

        SYSTEM.subscribe(
            _cfg.originChainId, _cfg.originPoolManager, SWAP_TOPIC_0, uint256(_cfg.originPoolId), REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        SYSTEM.subscribe(
            _cfg.destChainId, _cfg.destPoolManager, SWAP_TOPIC_0, uint256(_cfg.destPoolId), REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }

    /// @notice Recover this contract's lREACT (testnet convenience for redeploys). Does not touch any pool or LP funds.
    function withdraw(address payable to, uint256 amount) external {
        if (msg.sender != owner) revert NotOwner();
        _send(to, amount);
    }

    /// @notice Called by the Omni system contract for every subscribed Swap log.
    function react(LogRecord calldata log) external onlySystem {
        if (log.topic0 != SWAP_TOPIC_0) return;
        (,, uint160 sqrtPriceX96,,,) = abi.decode(log.data, (int128, int128, uint160, uint128, int24, uint24));
        Config memory c = cfg;

        if (log.chainId == c.originChainId && log.contractAddress == c.originPoolManager && bytes32(log.topic1) == c.originPoolId) {
            originSqrtPriceX96 = sqrtPriceX96;
        } else if (log.chainId == c.destChainId && log.contractAddress == c.destPoolManager && bytes32(log.topic1) == c.destPoolId) {
            destSqrtPriceX96 = _orient(sqrtPriceX96, c.invertDest);
        } else {
            return;
        }
        if (originSqrtPriceX96 == 0 || destSqrtPriceX96 == 0) return;

        uint256 dev = deviationBps(originSqrtPriceX96, destSqrtPriceX96);

        if (dev >= c.triggerBps) {
            uint24 fee = feeFor(dev, c);
            // Refresh on every qualifying origin move (keeps the destination expiry alive),
            // but skip destination-side swaps that don't change the fee meaningfully.
            bool fromOrigin = log.chainId == c.originChainId;
            if (fromOrigin || lastSentFee == 0 || _absDiff(fee, lastSentFee) >= c.feeStep) {
                lastSentFee = fee;
                bytes memory payload = abi.encodeWithSignature(
                    "setShield(address,bytes32,uint24,uint32,uint160)",
                    address(0), // replaced with this contract's address by Reactive Network
                    c.destPoolId,
                    fee,
                    c.shieldDuration,
                    originSqrtPriceX96
                );
                _callback(c, payload);
                emit ShieldDecision(dev, fee, true, false);
            }
        } else if (dev <= c.clearBps && lastSentFee != 0) {
            lastSentFee = 0;
            bytes memory payload =
                abi.encodeWithSignature("clearShield(address,bytes32)", address(0), c.destPoolId);
            _callback(c, payload);
            emit ShieldDecision(dev, 0, false, true);
        }
    }

    // ---------------------------------------------------------------- Pure math (public for tests / dashboard)

    /// @notice |P_a / P_b − 1| in basis points, where P = (sqrtPriceX96 / 2^96)^2.
    function deviationBps(uint160 sqrtA, uint160 sqrtB) public pure returns (uint256) {
        uint256 r = (uint256(sqrtA) * ONE) / sqrtB; // sqrt ratio, 1e18 scale (sqrtA < 2^160 → no overflow)
        if (r > 1e27) return type(uint256).max; // absurd gap; avoid overflow in r*r
        uint256 ratio = (r * r) / ONE;
        uint256 diff = ratio > ONE ? ratio - ONE : ONE - ratio;
        return (diff * 10_000) / ONE;
    }

    /// @notice Fee curve: base + slope × deviation, capped at maxFee.
    function feeFor(uint256 dev, Config memory c) public pure returns (uint24) {
        if (dev > LP_FEE_DENOMINATOR) dev = LP_FEE_DENOMINATOR; // bound the multiplication below
        uint256 fee = uint256(c.baseFee) + uint256(c.slopePipsPerBp) * dev;
        return fee > c.maxFee ? c.maxFee : uint24(fee);
    }

    function _callback(Config memory c, bytes memory payload) internal {
        SYSTEM.requestCallbackV_1_0(IOmniSystem.CallbackConfiguration_V_1_0(c.destChainId, c.hook, c.callbackGasLimit, payload));
    }

    function _orient(uint160 sqrtPriceX96, bool invert) internal pure returns (uint160) {
        if (!invert || sqrtPriceX96 == 0) return sqrtPriceX96;
        return uint160(Q192 / sqrtPriceX96);
    }

    function _absDiff(uint24 a, uint24 b) internal pure returns (uint24) {
        return a > b ? a - b : b - a;
    }
}
