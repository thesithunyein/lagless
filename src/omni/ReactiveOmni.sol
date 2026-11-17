// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal, ABI-compatible Reactive Omni bindings for solc 0.8.26.
/// @dev Mirrors the interfaces of Reactive-Network/reactive-lib-omni (which requires ^0.8.29, while Uniswap v4
///      pins 0.8.26). On Omni there is no ReactVM: `react()` runs on the deployed contract and is called by the
///      system contract at 0x8888...8888, which also handles subscriptions, callbacks and fee accounting.

interface IOmniSystem {
    struct CallbackConfiguration_V_1_0 {
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
    }

    function subscribe(
        uint256 chainId,
        address contractAddress,
        uint256 topic0,
        uint256 topic1,
        uint256 topic2,
        uint256 topic3
    ) external;

    function requestCallbackV_1_0(CallbackConfiguration_V_1_0 memory config) external;

    function debt(address contractAddress) external view returns (uint256);

    function depositTo(address target) external payable;
}

interface IOmniReactive {
    struct LogRecord {
        uint256 chainId;
        address contractAddress;
        uint256 topic0;
        uint256 topic1;
        uint256 topic2;
        uint256 topic3;
        bytes data;
        uint256 blockNumber;
        uint256 opCode;
        uint256 blockHash;
        uint256 txHash;
        uint256 logIndex;
    }

    function react(LogRecord calldata log) external;
}

abstract contract OmniReactiveBase is IOmniReactive {
    IOmniSystem internal constant SYSTEM = IOmniSystem(0x8888888888888888888888888888888888888888);
    uint256 internal constant REACTIVE_IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    error NotSystem(address sender);
    error InsufficientFunds(uint256 required, uint256 available);
    error TransferFailed();

    modifier onlySystem() {
        if (msg.sender != address(SYSTEM)) revert NotSystem(msg.sender);
        _;
    }

    receive() external payable virtual {}

    /// @notice Lets the system contract collect fees from this contract's balance (keeps the contract ACTIVE).
    function pay(uint256 amount) external onlySystem {
        _send(payable(msg.sender), amount);
    }

    /// @notice Settle any outstanding Omni debt from this contract's balance.
    function coverDebt() external {
        _send(payable(address(SYSTEM)), SYSTEM.debt(address(this)));
    }

    function _send(address payable to, uint256 amount) internal {
        if (address(this).balance < amount) revert InsufficientFunds(amount, address(this).balance);
        if (amount > 0) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        }
    }
}
