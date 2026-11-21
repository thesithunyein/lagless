// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@uniswap/v4-core/lib/solmate/src/tokens/ERC20.sol";

/// @notice TESTNET ONLY. Open-mint ERC-20 used for the Lagless demo pools.
/// @dev Deployed with CREATE2 from the same deployer + salt on Base Sepolia and Unichain Sepolia, so both
///      chains get identical token addresses and identical token0/token1 ordering.
contract MockToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_, 18) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
