// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {ISVLaunchpad} from "../../src/interfaces/ISVLaunchpad.sol";
import {SVLaunchpadTestBase} from "./SVLaunchpad.t.sol";

/// @notice Spec section 8.1, fuzz: the snapped opening, the dust bound and the per-tick cap across the whole
///         valuation range in both orders; a real launch anywhere in that range; the first buy against the curve
///         `S x y / (V' + y)`; and the fee split for any share.
contract SVLaunchpadFuzzTest is SVLaunchpadTestBase {
    address internal constant LOW = address(0x1000);
    address internal constant HIGH = address(0x2000);

    function setUp() public override {
        super.setUp();
        vm.startPrank(owner);
        launchpad.setCurrency(address(stk), MIN_VALUATION, MAX_VALUATION, 0);
        launchpad.setDailyLaunchLimit(255);
        vm.stopPrank();
        stk.mint(creator, 1e42);
        usdg.mint(address(this), MINT);
    }

    function testFuzz_the_opening_snaps_down_within_one_step_and_the_pool_takes_the_supply_within_the_dust_bound(
        uint256 rawValuation,
        bool tokenFirst
    ) public view {
        uint256 valuation = bound(rawValuation, MIN_VALUATION, MAX_VALUATION);
        (address token, address quote) = tokenFirst ? (LOW, HIGH) : (HIGH, LOW);
        Expected memory e = _expected(token, quote, valuation);
        assertLe(e.snapped, valuation, "V' <= V, exactly");
        assertGe(e.snapped * 10_202_004, valuation * 10_000_000, "V' x 1.0202004 >= V, above 1.0001^200");
        assertEq(e.openTick % 200, 0, "a multiple of the spacing");
        assertGt(e.openTick, MIN_USABLE_TICK, "strictly inside the usable range, bottom");
        assertLt(e.openTick, MAX_USABLE_TICK, "strictly inside the usable range, top");
        assertLt(e.liquidity, Pool.tickSpacingToMaxLiquidityPerTick(200), "L under the per-tick cap");
        assertLe(e.owed, SUPPLY, "the pool charges at most S");
        assertLe(SUPPLY - e.owed, _dustBound(token, quote, e.sqrtPriceX96), "S - owed within the dust bound");
    }

    function testFuzz_a_launch_anywhere_in_the_range_opens_exactly_and_burns_only_the_dust(
        uint256 rawValuation,
        bool tokenFirst
    ) public {
        uint256 valuation = bound(rawValuation, MIN_VALUATION, MAX_VALUATION);
        ISVLaunchpad.LaunchParams memory p = _params(creator, address(stk), valuation, tokenFirst);
        Expected memory e = _expected(launchpad.predictToken(creator, p.salt, NAME, SYMBOL), address(stk), valuation);
        address token = _launch(CREATOR_KEY, p);
        (uint160 price, int24 tick) = _slot0(token);
        assertEq(price, e.sqrtPriceX96, "the pool opened at the snapped price");
        assertEq(tick, e.openTick, "on the snapped tick");
        assertEq(_positionLiquidity(token), e.liquidity, "holding L");
        assertEq(IERC20(token).totalSupply(), e.owed, "only the dust was burned");
        assertEq(IERC20(token).balanceOf(address(launchpad)), 0, "the launchpad holds none of the token");
    }

    function testFuzz_the_first_buy_follows_the_curve_to_a_relative_1e_minus_9(
        uint256 rawValuation,
        uint256 rawBuy,
        bool tokenFirst
    ) public {
        uint256 valuation = bound(rawValuation, 1e10, MAX_VALUATION);
        ISVLaunchpad.LaunchParams memory p = _params(creator, address(stk), valuation, tokenFirst);
        (,, uint256 snapped) =
            launchpad.openingFor(launchpad.predictToken(creator, p.salt, NAME, SYMBOL), address(stk), valuation);
        // Between a ten-thousandth and a fifth of V': well under the 20 % cap, which a fifth of V' buys 1/6 of.
        p.firstBuy = bound(rawBuy, snapped / 10_000, snapped / 5);
        uint256 net = p.firstBuy - p.firstBuy * 50 / 10_000;
        uint256 y = FullMath.mulDiv(net, 990_000, 1_000_000);
        uint256 expected = FullMath.mulDiv(SUPPLY, y, snapped + y);
        vm.recordLogs();
        address token = _launch(CREATOR_KEY, p);
        (, ISVLaunchpad.LaunchedData memory d) = _launchedFrom(vm.getRecordedLogs());
        assertApproxEqRel(d.firstBuyTokens, expected, 1e9, "tokens out = S x y / (V' + y) to a relative 1e-9");
        assertEq(IERC20(token).balanceOf(creator), d.firstBuyTokens, "and the creator holds them");
    }

    function testFuzz_the_fee_split_sums_to_the_fees_and_rounds_toward_the_fee_wallet(
        uint256 rawBuy,
        uint256 rawShare,
        bool tokenFirst
    ) public {
        uint256 share = bound(rawShare, 0, 10_000);
        vm.prank(owner);
        // forge-lint: disable-next-line(unsafe-typecast)
        launchpad.setCreatorShare(uint16(share));
        address token = _launchFree(address(usdg), USDG_MIN, tokenFirst);
        uint256 bought = _swap(token, true, bound(rawBuy, 1e6, 1_000_000e6));
        _swap(token, false, bought / 3);
        vm.recordLogs();
        launchpad.collectFees(token);
        (uint256 tokenFees, uint256 quoteFees, uint256 tokenToPayout, uint256 quoteToPayout) =
            _feesCollectedFrom(vm.getRecordedLogs());
        assertEq(tokenToPayout, tokenFees * share / 10_000, "the payout's token share rounds down");
        assertEq(quoteToPayout, quoteFees * share / 10_000, "the payout's quote share rounds down");
        assertEq(IERC20(token).balanceOf(creator), tokenToPayout, "the payout received its token share");
        assertEq(IERC20(token).balanceOf(feeWallet), tokenFees - tokenToPayout, "the fee wallet the rest");
        assertEq(usdg.balanceOf(feeWallet), quoteFees - quoteToPayout, "the fee wallet the rest of the quote");
        assertEq(usdg.balanceOf(address(launchpad)), 0, "nothing stays behind");
    }
}
