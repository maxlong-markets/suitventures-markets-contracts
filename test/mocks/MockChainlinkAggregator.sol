// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice A Chainlink price feed with a settable answer and update time, for the deploy script's tests only.
contract MockChainlinkAggregator {
    /// @dev Named as Chainlink's `decimals()` getter, which the script calls, not in upper snake case.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint8 public immutable decimals;
    int256 internal answer_;
    uint256 internal updatedAt_;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function set(int256 answer, uint256 updatedAt) external {
        answer_ = answer;
        updatedAt_ = updatedAt;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer_, updatedAt_, updatedAt_, 1);
    }
}
