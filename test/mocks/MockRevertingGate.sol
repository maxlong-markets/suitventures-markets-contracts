// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice A launcher gate whose `balanceOf` reverts. The launchpad must read it as "not allowed", never bubble
///         the revert. Unit tests only.
contract MockRevertingGate {
    error GateIsUnwell();

    function balanceOf(address) external pure returns (uint256) {
        revert GateIsUnwell();
    }
}
