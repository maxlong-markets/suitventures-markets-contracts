// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

/// @notice The smallest anti-snipe-shaped hook: only `beforeSwap`, answering its selector with zero deltas and no
///         fee override. Its code is etched at an address carrying `BEFORE_SWAP_FLAG` alone. Unit tests only.
contract MockBeforeSwapHook {
    uint256 public swaps;

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        swaps++;
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }
}
