// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @title SVLaunchToken
/// @notice The token a MaxLong Markets launch creates: a plain OpenZeppelin ERC20 with `burn`, 18 decimals, one
///         billion tokens minted once to the launchpad. No owner, no mint after construction, no pause, no
///         blocklist, no transfer fee, no hooks.
/// @dev Spec: docs/superpowers/specs/2026-09-28-instant-launchpad-design.md (frontend repo), section 4.1. Deployed
///      only by SVLaunchpad with CREATE2 inside the launch transaction; the launchpad burns the dust the pool did
///      not take, so it ends the launch holding none of it.
contract SVLaunchToken is ERC20, ERC20Burnable {
    /// @notice The whole supply, minted once in the constructor.
    uint256 public constant SUPPLY = 1_000_000_000e18;

    /// @notice Mints the whole supply to `recipient`, always the launchpad. 18 decimals, no owner, no mint after this.
    /// @param name_ The token name the creator chose.
    /// @param symbol_ The token symbol the creator chose.
    /// @param recipient The launchpad.
    constructor(string memory name_, string memory symbol_, address recipient) ERC20(name_, symbol_) {
        _mint(recipient, SUPPLY);
    }
}
