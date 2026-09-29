// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice A launcher gate whose `balanceOf` never answers: it hashes until the call's gas allowance is gone. The
///         launchpad's 100,000 gas cap must turn it into "not allowed". Unit tests only.
contract MockGasBurningGate {
    function balanceOf(address) external view returns (uint256 total) {
        total = uint256(blockhash(block.number - 1));
        while (gasleft() > 0) {
            total = uint256(keccak256(abi.encode(total)));
        }
    }
}
