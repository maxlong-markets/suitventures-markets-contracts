// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ISVRouter} from "../../src/interfaces/ISVRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {SVRouterTestBase} from "./SVRouter.t.sol";

/// @notice Fuzzed fee arithmetic: for every amount the app can trade and every rate the owner can set, the fee
///         is `amountIn * bps / 10_000` rounded down, the fee and the net add back up to `amountIn`, and the fee
///         never exceeds 0.5 % of the input.
/// @dev Shares the fixture of the unit suite (`SVRouterTestBase` in SVRouter.t.sol). `amountIn` is bounded to
///      `[1, 2**120]`: one wei is the smallest trade the router accepts, and `2**120` is far above any real
///      supply while leaving room inside the `uint128` the interface uses.
contract SVRouterFuzzTest is SVRouterTestBase {
    uint128 internal constant MAX_FUZZ_AMOUNT = uint128(2 ** 120);

    /// @dev `feeFor` alone: the rule the app quotes with, on every amount and rate.
    function testFuzz_feeFor_is_amountIn_times_bps_rounded_down(
        uint128 rawAmountIn,
        uint16 rawFeeBps,
        uint16 rawHolderFeeBps
    ) public {
        uint128 amountIn = uint128(bound(rawAmountIn, 1, MAX_FUZZ_AMOUNT));
        uint16 bps = uint16(bound(rawFeeBps, 0, router.MAX_FEE_BPS()));
        uint16 holderBps = uint16(bound(rawHolderFeeBps, 0, bps));

        vm.prank(owner);
        router.setFees(bps, holderBps);
        nft.mint(user, 1); // the user holds one Suit; the stranger holds none

        (uint256 standardFee, bool standardHolderRate) = router.feeFor(stranger, amountIn);
        assertFalse(standardHolderRate, "a non-holder pays the standard rate");
        assertEq(standardFee, uint256(amountIn) * bps / 10_000, "fee = amountIn * feeBps / 10_000");
        assertLe(standardFee, uint256(amountIn) / 200, "never more than 0.5 % of the input");
        _assertNetAddsUp(amountIn, standardFee);

        (uint256 holderFee, bool holderRate) = router.feeFor(user, amountIn);
        assertTrue(holderRate, "a holder pays the holder rate");
        assertEq(holderFee, uint256(amountIn) * holderBps / 10_000, "fee = amountIn * holderFeeBps / 10_000");
        assertLe(holderFee, standardFee, "the holder rate is never worse than the standard rate");
        assertLe(holderFee, uint256(amountIn) / 200, "never more than 0.5 % of the input");
        _assertNetAddsUp(amountIn, holderFee);
    }

    /// @dev `swapExactIn` derives the swap's input as `amountIn - uint128(fee)`. That cast must not truncate and
    ///      that subtraction must not underflow, whatever the rate: the two parts always add back up to the whole.
    function _assertNetAddsUp(uint128 amountIn, uint256 fee) private pure {
        assertLe(fee, type(uint128).max, "the fee fits the uint128 the router casts it to");
        // The assertion above is what makes this cast safe; it mirrors the one in `swapExactIn`.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 net = amountIn - uint128(fee);
        assertEq(uint256(net) + fee, amountIn, "fee + net = amountIn");
    }

    /// @notice One fuzzed trade, gathered in memory. The struct is not decoration: with `via_ir = false` the
    ///         legacy code generator runs out of stack if these live as locals across the `Trade` assertion.
    struct Case {
        uint128 amountIn;
        uint16 bps;
        uint16 holderBps;
        bool zeroForOne;
        bool holdsNft;
        uint256 fee;
        uint256 userInBefore;
        uint256 userOutBefore;
        uint256 amountOut;
    }

    /// @dev The same arithmetic through a whole trade, in both directions, measured in token balances: what the
    ///      fee wallet gets plus what the Universal Router gets is exactly what the user paid.
    function testFuzz_swapExactIn_splits_amountIn_into_the_fee_and_the_net(
        uint128 rawAmountIn,
        uint16 rawFeeBps,
        uint16 rawHolderFeeBps,
        bool zeroForOne,
        bool holdsNft
    ) public {
        Case memory c;
        c.amountIn = uint128(bound(rawAmountIn, 1, MAX_FUZZ_AMOUNT));
        c.bps = uint16(bound(rawFeeBps, 0, router.MAX_FEE_BPS()));
        c.holderBps = uint16(bound(rawHolderFeeBps, 0, c.bps));
        c.zeroForOne = zeroForOne;
        c.holdsNft = holdsNft;
        c.fee = uint256(c.amountIn) * (holdsNft ? c.holderBps : c.bps) / 10_000;

        vm.prank(owner);
        router.setFees(c.bps, c.holderBps);
        if (holdsNft) nft.mint(user, 1);

        _sendTrade(c);
        _assertSplit(c);
    }

    /// @dev Signs and sends one trade of `c`, asserting the `Trade` event exactly, and records what moved.
    function _sendTrade(Case memory c) private {
        (MockERC20 tokenIn, MockERC20 tokenOut) = _tokens(c.zeroForOne);
        tokenIn.mint(user, c.amountIn); // on top of the fixture's balance, so any bounded amount is affordable
        c.userInBefore = tokenIn.balanceOf(user);
        c.userOutBefore = tokenOut.balanceOf(user);

        universalRouter.setOutput(address(tokenOut), OUTPUT);
        ISVRouter.SwapParams memory p = _swapParams(c.zeroForOne, c.amountIn, OUTPUT);
        ISignatureTransfer.PermitTransferFrom memory permit = _permitFor(address(tokenIn), c.amountIn, 0);
        // Signed before the prank: reading Permit2's domain separator is an external call, which would
        // otherwise consume it and send the trade from the test contract instead of the user.
        bytes memory signature = _sign(USER_KEY, permit);

        vm.expectEmit(true, true, true, true, address(router));
        emit ISVRouter.Trade(
            user, PoolId.unwrap(key.toId()), address(tokenIn), address(tokenOut), c.amountIn, c.fee, OUTPUT, c.holdsNft
        );
        vm.prank(user);
        c.amountOut = router.swapExactIn(p, permit, signature);
    }

    /// @dev Everything the trade must have moved, in balances.
    function _assertSplit(Case memory c) private view {
        (MockERC20 tokenIn, MockERC20 tokenOut) = _tokens(c.zeroForOne);
        uint256 inFeeWallet = tokenIn.balanceOf(feeWallet);
        uint256 inUniversalRouter = tokenIn.balanceOf(address(universalRouter));

        assertEq(c.amountOut, OUTPUT, "returned amountOut");
        assertEq(inFeeWallet, c.fee, "fee = amountIn * bps / 10_000, in the fee wallet");
        assertEq(inFeeWallet, uint256(c.amountIn) * (c.holdsNft ? c.holderBps : c.bps) / 10_000, "the rate applied");
        assertEq(inUniversalRouter, c.amountIn - c.fee, "net reached the Universal Router");
        assertEq(
            universalRouter.lastSwapParams().settleAmount,
            c.amountIn - c.fee,
            "the router settles exactly the net amount, never the open delta"
        );
        assertEq(inFeeWallet + inUniversalRouter, c.amountIn, "fee + net = amountIn");
        assertLe(inFeeWallet, uint256(c.amountIn) / 200, "the fee never exceeds 0.5 % of the input");
        assertEq(tokenIn.balanceOf(user), c.userInBefore - c.amountIn, "the user paid exactly amountIn");
        assertEq(tokenOut.balanceOf(user), c.userOutBefore + OUTPUT, "the output went straight to the user");
        assertEq(tokenIn.balanceOf(address(router)), 0, "the router kept no input");
        assertEq(tokenOut.balanceOf(address(router)), 0, "the router kept no output");
    }
}
