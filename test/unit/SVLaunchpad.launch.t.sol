// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {SignatureVerification} from "permit2/src/libraries/SignatureVerification.sol";
import {SVLaunchToken} from "../../src/SVLaunchToken.sol";
import {ISVLaunchpad} from "../../src/interfaces/ISVLaunchpad.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockQuirkyERC20} from "../mocks/MockQuirkyERC20.sol";
import {Permit2Signer} from "../utils/Permit2Signer.sol";
import {SVLaunchpadTestBase} from "./SVLaunchpad.t.sol";

/// @notice `launch` (spec section 4.5) on the local PoolManager: every value of a launch in both currency orders
///         and both quote decimals, the payment and the first buy, every revert at its step with call counts
///         proving nothing moved before it, the daily limit, the front-run retry, the hook and share settings, and
///         the callback guards of section 4.8.
contract SVLaunchpadLaunchTest is SVLaunchpadTestBase {
    /// @dev Permit2's own error, redeclared because permit2/src/PermitErrors.sol pins solc 0.8.17.
    error InvalidNonce();

    // -------------------------------------------------------------------------------------------------------
    // A free launch: every value (spec sections 3.2, 3.3, 4.5 steps 8 to 14)
    // -------------------------------------------------------------------------------------------------------

    function _freeLaunchData(PoolKey memory key, Expected memory e, bool tokenFirst)
        internal
        view
        returns (ISVLaunchpad.LaunchedData memory d)
    {
        d.poolId = PoolId.unwrap(key.toId());
        d.payout = creator;
        d.hook = address(0);
        d.tokenIsCurrency0 = tokenFirst;
        d.openTick = e.openTick;
        d.openingValuation = e.snapped;
        d.liquidity = e.liquidity;
        d.tokensInPool = e.owed;
        d.creatorShareBps = 7_000;
        d.name = NAME;
        d.symbol = SYMBOL;
        d.metadataUri = URI;
    }

    function _assertStoredLaunch(address token, address quote, Expected memory e, bool tokenFirst) internal view {
        ISVLaunchpad.Launch memory l = launchpad.getLaunch(token);
        assertEq(l.creator, creator, "creator");
        assertEq(l.launchedAt, block.timestamp, "launchedAt");
        assertEq(l.creatorShareBps, 7_000, "the share fixed at launch");
        assertEq(l.tokenIsCurrency0, tokenFirst, "the currency order");
        assertEq(l.payout, creator, "payout defaults to the caller");
        assertEq(l.openTick, e.openTick, "openTick");
        assertEq(l.quote, quote, "quote");
        assertEq(l.hook, address(0), "hookless");
        assertEq(l.liquidity, e.liquidity, "liquidity");
        PoolKey memory key = launchpad.poolKeyOf(token);
        assertEq(Currency.unwrap(key.currency0), tokenFirst ? token : quote, "currency0");
        assertEq(Currency.unwrap(key.currency1), tokenFirst ? quote : token, "currency1");
        assertEq(key.fee, 10_000, "1 % LP fee");
        assertEq(key.tickSpacing, 200, "tick spacing 200");
        assertEq(address(key.hooks), address(0), "no hook");
        assertEq(launchpad.launchCount(), 1, "one launch counted");
        assertEq(launchpad.launchesToday(creator), 1, "one launch today");
    }

    function _assertFreeLaunch(address quote, uint256 valuation, bool tokenFirst) internal {
        ISVLaunchpad.LaunchParams memory p = _params(creator, quote, valuation, tokenFirst);
        address predicted = launchpad.predictToken(creator, p.salt, NAME, SYMBOL);
        Expected memory e = _expected(predicted, quote, valuation);
        ISVLaunchpad.LaunchedData memory expectedData =
            _freeLaunchData(_keyFor(predicted, quote, address(0)), e, tokenFirst);
        // The emitting call must come straight after the expectation: no other call in between.
        vm.expectEmit(true, true, true, true, address(launchpad));
        emit ISVLaunchpad.Launched(predicted, creator, quote, expectedData);
        vm.prank(creator);
        address token = launchpad.launch(p, _emptyPermit(), "");

        assertEq(token, predicted, "predictToken named the deployed address");
        assertEq(token < quote, tokenFirst, "the token sits on the wanted side of the quote");
        (uint160 price, int24 tick) = _slot0(token);
        assertEq(price, e.sqrtPriceX96, "slot0 is exactly the opening tick's price");
        assertEq(tick, e.openTick, "slot0's tick is the opening tick");
        assertEq(e.openTick % 200, 0, "a multiple of the spacing");
        assertLe(e.snapped, valuation, "the snapped valuation is at or below the request");
        assertEq(_positionLiquidity(token), e.liquidity, "the position holds L");
        assertEq(_activeLiquidity(token), tokenFirst ? e.liquidity : 0, "active at once only as currency0");
        assertLe(e.owed, SUPPLY, "the pool took at most the supply");
        assertLe(SUPPLY - e.owed, _dustBound(token, quote, e.sqrtPriceX96), "the dust is within the section 3.3 bound");
        assertEq(IERC20(token).totalSupply(), e.owed, "the dust was burned");
        assertEq(IERC20(token).balanceOf(address(manager)), e.owed, "the pool holds what it took");
        assertEq(IERC20(token).balanceOf(address(launchpad)), 0, "the launchpad holds none of the token");
        assertEq(IERC20(quote).balanceOf(address(launchpad)), 0, "nor any quote");
        _assertStoredLaunch(token, quote, e, tokenFirst);
    }

    function test_a_free_usdg_launch_with_the_token_as_currency0_matches_every_spec_value() public {
        _assertFreeLaunch(address(usdg), 5_000e6, true);
    }

    function test_a_free_usdg_launch_with_the_token_as_currency1_matches_every_spec_value() public {
        _assertFreeLaunch(address(usdg), 1_000_000e6, false);
    }

    function test_a_free_18_decimal_launch_with_the_token_as_currency0_matches_every_spec_value() public {
        _assertFreeLaunch(address(stk), 50e18, true);
    }

    function test_a_free_18_decimal_launch_with_the_token_as_currency1_matches_every_spec_value() public {
        _assertFreeLaunch(address(stk), 100_000e18, false);
    }

    function test_a_free_launch_pulls_nothing_and_ignores_the_permit_and_the_signature() public {
        ISVLaunchpad.LaunchParams memory p = _params(creator, address(usdg), USDG_MIN, true);
        ISignatureTransfer.PermitTransferFrom memory junk = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(stk), amount: 1}), nonce: 7, deadline: 0
        });
        uint256 before = usdg.balanceOf(creator);
        _expectNoPermitPull();
        vm.prank(creator);
        address token = launchpad.launch(p, junk, hex"deadbeef");
        assertGt(token.code.length, 0, "launched");
        assertEq(usdg.balanceOf(creator), before, "the creator paid nothing but gas");
        assertEq(usdg.balanceOf(feeWallet), 0, "no fee moved");
    }

    // -------------------------------------------------------------------------------------------------------
    // Payment and the first buy (spec section 4.5 steps 7, 11.3 to 11.6, 12)
    // -------------------------------------------------------------------------------------------------------

    function test_a_paid_launch_pulls_exactly_the_first_buy_plus_the_creation_fee_and_pays_both_fees_out() public {
        vm.prank(owner);
        launchpad.setCurrency(address(usdg), USDG_MIN, USDG_MAX, 25e6);
        ISVLaunchpad.LaunchParams memory p = _params(creator, address(usdg), USDG_MIN, true);
        p.firstBuy = 1_000e6;
        uint256 routerFee = 1_000e6 * 50 / 10_000;
        uint256 net = 1_000e6 - routerFee;
        uint256 creatorBefore = usdg.balanceOf(creator);
        _expectOnePermitPull();
        vm.recordLogs();
        address token = _launch(CREATOR_KEY, p);
        (, ISVLaunchpad.LaunchedData memory d) = _launchedFrom(vm.getRecordedLogs());
        assertEq(creatorBefore - usdg.balanceOf(creator), 1_025e6, "the creator paid the first buy plus the fee");
        assertEq(usdg.balanceOf(feeWallet), routerFee + 25e6, "fee wallet: router fee plus creation fee, one transfer");
        assertEq(usdg.balanceOf(address(manager)), net, "exactly the net went into the pool");
        assertEq(usdg.balanceOf(address(launchpad)), 0, "the launchpad keeps no quote");
        assertEq(d.firstBuyIn, net, "event: net swapped");
        assertEq(d.routerFee, routerFee, "event: router fee, floor(firstBuy * 50 / 10000)");
        assertEq(d.creationFee, 25e6, "event: creation fee");
        assertEq(IERC20(token).balanceOf(creator), d.firstBuyTokens, "the creator holds the first buy");
    }

    function test_the_first_buy_reaches_the_creator_and_the_pool_keeps_the_rest_in_both_orders() public {
        for (uint256 i = 0; i < 2; i++) {
            bool tokenFirst = i == 0;
            vm.recordLogs();
            address token = _launchWithBuy(address(usdg), USDG_MIN, tokenFirst, 500e6);
            (, ISVLaunchpad.LaunchedData memory d) = _launchedFrom(vm.getRecordedLogs());
            assertGt(d.firstBuyTokens, 0, "the first buy bought");
            assertEq(IERC20(token).balanceOf(creator), d.firstBuyTokens, "the creator received exactly tokensOut");
            assertEq(
                IERC20(token).balanceOf(address(manager)),
                d.tokensInPool - d.firstBuyTokens,
                "the pool's balance did not rise by the first buy: it paid it out"
            );
            assertEq(IERC20(token).balanceOf(address(launchpad)), 0, "the launchpad holds none");
            assertEq(_activeLiquidity(token), d.liquidity, "after the first buy the position is active in both orders");
        }
    }

    function test_the_first_buy_reverts_FirstBuyTooLarge_just_above_the_cap_and_succeeds_just_below() public {
        uint256 cap = SUPPLY * 2_000 / 10_000;
        for (uint256 i = 0; i < 2; i++) {
            bool tokenFirst = i == 0;
            ISVLaunchpad.LaunchParams memory p = _params(creator, address(usdg), USDG_MIN, tokenFirst);
            address predicted = launchpad.predictToken(creator, p.salt, NAME, SYMBOL);
            (,, uint256 snapped) = launchpad.openingFor(predicted, address(usdg), USDG_MIN);
            // The gross first buy whose net, after the 0.5 % router fee and the 1 % pool fee, is a quarter of V'.
            // A quarter of V' buys a fifth of the supply (spec section 3.4): the cap.
            uint256 atCap = FullMath.mulDiv(snapped, 1e10, 4 * 990_000 * 9_950);
            p.firstBuy = atCap * 1_001 / 1_000;
            uint256 over = _dryRunTokensOut(p);
            assertGt(over, cap, "0.1 % above the cap's price buys more than the cap");
            _expectLaunchRevert(
                CREATOR_KEY, p, abi.encodeWithSelector(ISVLaunchpad.FirstBuyTooLarge.selector, over, cap)
            );
            p.firstBuy = atCap * 999 / 1_000;
            uint256 under = _dryRunTokensOut(p);
            assertLe(under, cap, "0.1 % below buys less than the cap");
            address token = _launch(CREATOR_KEY, p);
            assertEq(IERC20(token).balanceOf(creator), under, "the creator received the dry run's tokens");
        }
    }

    function test_minFirstBuyTokens_reverts_FirstBuyTooSmall_one_unit_above_the_output_and_succeeds_at_it() public {
        ISVLaunchpad.LaunchParams memory p = _params(creator, address(usdg), USDG_MIN, false);
        p.firstBuy = 500e6;
        uint256 out = _dryRunTokensOut(p);
        p.minFirstBuyTokens = out + 1;
        _expectLaunchRevert(
            CREATOR_KEY, p, abi.encodeWithSelector(ISVLaunchpad.FirstBuyTooSmall.selector, out, out + 1)
        );
        p.minFirstBuyTokens = out;
        address token = _launch(CREATOR_KEY, p);
        assertEq(IERC20(token).balanceOf(creator), out, "exactly the floor");
    }

    function test_a_minimum_without_a_first_buy_reverts_FirstBuyTooSmall() public {
        ISVLaunchpad.LaunchParams memory p = _params(creator, address(usdg), USDG_MIN, true);
        p.minFirstBuyTokens = 1;
        _expectLaunchRevert(CREATOR_KEY, p, abi.encodeWithSelector(ISVLaunchpad.FirstBuyTooSmall.selector, 0, 1));
    }

    function test_a_zero_first_buy_cap_blocks_any_first_buy_and_not_a_free_launch() public {
        vm.prank(owner);
        launchpad.setFirstBuyCap(0);
        ISVLaunchpad.LaunchParams memory p = _params(creator, address(usdg), USDG_MIN, true);
        p.firstBuy = 100e6;
        uint256 out = _dryRunTokensOut(p);
        _expectLaunchRevert(CREATOR_KEY, p, abi.encodeWithSelector(ISVLaunchpad.FirstBuyTooLarge.selector, out, 0));
        _launchFree(address(usdg), USDG_MIN, true);
    }

    /// @dev Review focus 3: the router fee floors to 0 and the pool's 1 % fee takes the one unit, so nothing is
    ///      bought, and no zero-value transfer goes to the fee wallet.
    function test_a_one_unit_first_buy_launches_buys_nothing_and_sends_no_fee() public {
        for (uint256 i = 0; i < 2; i++) {
            vm.recordLogs();
            address token = _launchWithBuy(address(usdg), USDG_MIN, i == 0, 1);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            (, ISVLaunchpad.LaunchedData memory d) = _launchedFrom(logs);
            assertEq(d.routerFee, 0, "the router fee floors to zero");
            assertEq(d.firstBuyIn, 1, "one unit went into the pool");
            assertEq(d.firstBuyTokens, 0, "and bought nothing");
            assertEq(IERC20(token).balanceOf(creator), 0, "the creator holds none");
            assertEq(_transfersTo(logs, address(usdg), feeWallet), 0, "no zero-value transfer to the fee wallet");
        }
        assertEq(usdg.balanceOf(feeWallet), 0, "the fee wallet received nothing");
    }

    /// @dev Review focus 4: the bounds themselves launch, and at MAX_VALUATION the pool takes the whole supply, so
    ///      nothing is burned and no burn call is made (the other side of step 13's branch).
    function test_launches_at_the_bounds_and_at_MAX_VALUATION_where_nothing_is_burned() public {
        vm.prank(owner);
        launchpad.setDailyLaunchLimit(10);
        _launchFree(address(usdg), USDG_MIN, true);
        _launchFree(address(usdg), USDG_MAX, false);
        vm.prank(owner);
        launchpad.setCurrency(address(stk), MIN_VALUATION, MAX_VALUATION, 0);
        for (uint256 i = 0; i < 2; i++) {
            _launchFree(address(stk), MIN_VALUATION, i == 0);
            vm.recordLogs();
            address token = _launchFree(address(stk), MAX_VALUATION, i == 0);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            (, ISVLaunchpad.LaunchedData memory d) = _launchedFrom(logs);
            assertEq(d.tokensInPool, SUPPLY, "at the top of the range the pool takes the whole supply");
            assertEq(IERC20(token).totalSupply(), SUPPLY, "nothing burned");
            assertEq(_transfersTo(logs, token, address(0)), 0, "no burn call at all");
        }
        assertEq(launchpad.launchCount(), 6, "six launches");
    }

    function test_payout_defaults_to_the_caller_and_takes_an_explicit_address() public {
        address token = _launchFree(address(usdg), USDG_MIN, true);
        assertEq(launchpad.getLaunch(token).payout, creator, "zero means the caller");
        address payout = makeAddr("payout");
        ISVLaunchpad.LaunchParams memory p = _params(creator, address(usdg), USDG_MIN, false);
        p.payout = payout;
        vm.recordLogs();
        token = _launch(CREATOR_KEY, p);
        (, ISVLaunchpad.LaunchedData memory d) = _launchedFrom(vm.getRecordedLogs());
        assertEq(launchpad.getLaunch(token).payout, payout, "the explicit payout is stored");
        assertEq(d.payout, payout, "and carried by the event");
    }

    function test_a_launch_with_a_first_buy_costs_under_2_5_million_gas() public {
        ISVLaunchpad.LaunchParams memory p = _params(creator, address(usdg), USDG_MIN, true);
        p.firstBuy = 500e6;
        (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory signature) =
            _permit(CREATOR_KEY, address(usdg), p.firstBuy);
        vm.prank(creator);
        uint256 gasBefore = gasleft();
        launchpad.launch(p, permit, signature);
        uint256 used = gasBefore - gasleft();
        console2.log("gas of a launch with a first buy", used);
        assertLt(
            used,
            2_500_000,
            "one deployment, initialize, mint, swap: about 1.14 million in the normal build, 1.58 million unoptimised under coverage"
        );
    }

    // -------------------------------------------------------------------------------------------------------
    // Every revert at its step (spec section 4.5 steps 1 to 7), nothing pulled before it
    // -------------------------------------------------------------------------------------------------------

    /// @dev One call failing every cheap check at once meets them in the spec's order, and none pulls money.
    function test_the_checks_run_in_the_spec_order_and_none_pulls_money() public {
        _expectNoPermitPull();
        ISVLaunchpad.LaunchParams memory p = _params(stranger, address(usdg), USDG_MAX + 1, true);
        p.firstBuy = 1_000e6;
        p.name = "";
        p.payout = address(launchpad);
        p.deadline = block.timestamp - 1;
        vm.prank(owner);
        launchpad.setDailyLaunchLimit(0);
        _expectLaunchRevert(STRANGER_KEY, p, abi.encodeWithSelector(ISVLaunchpad.Expired.selector));
        p.deadline = block.timestamp;
        _expectLaunchRevert(STRANGER_KEY, p, abi.encodeWithSelector(ISVLaunchpad.NotAllowedToLaunch.selector));
        gate.mint(stranger, 2);
        _expectLaunchRevert(STRANGER_KEY, p, abi.encodeWithSelector(ISVLaunchpad.DailyLimitReached.selector));
        vm.prank(owner);
        launchpad.setDailyLaunchLimit(5);
        _expectLaunchRevert(STRANGER_KEY, p, abi.encodeWithSelector(ISVLaunchpad.BadName.selector));
        p.name = NAME;
        _expectLaunchRevert(
            STRANGER_KEY,
            p,
            abi.encodeWithSelector(ISVLaunchpad.ValuationOutOfRange.selector, USDG_MAX + 1, USDG_MIN, USDG_MAX)
        );
        p.valuation = USDG_MIN;
        _expectLaunchRevert(STRANGER_KEY, p, abi.encodeWithSelector(ISVLaunchpad.BadPayout.selector));
    }

    function test_launch_reverts_Expired_after_the_deadline_and_accepts_the_deadline_itself() public {
        ISVLaunchpad.LaunchParams memory p = _params(creator, address(usdg), USDG_MIN, true);
        p.deadline = block.timestamp - 1;
        _expectLaunchRevert(CREATOR_KEY, p, abi.encodeWithSelector(ISVLaunchpad.Expired.selector));
        p.deadline = block.timestamp;
        _launch(CREATOR_KEY, p);
    }

    function test_launch_reverts_NotAllowedToLaunch_for_a_non_holder_and_a_cleared_gate_lets_anyone_launch() public {
        _expectLaunchRevert(
            STRANGER_KEY,
            _params(stranger, address(usdg), USDG_MIN, true),
            abi.encodeWithSelector(ISVLaunchpad.NotAllowedToLaunch.selector)
        );
        vm.prank(owner);
        launchpad.setLauncherGate(address(0));
        address token = _launch(STRANGER_KEY, _params(stranger, address(usdg), USDG_MIN, true));
        assertEq(launchpad.getLaunch(token).creator, stranger, "the stranger launched once the gate was cleared");
    }

    function test_launch_checks_text_lengths_in_bytes_and_accepts_the_maximums_and_an_empty_uri() public {
        ISVLaunchpad.LaunchParams memory p = _params(creator, address(usdg), USDG_MIN, true);
        p.name = "";
        _expectLaunchRevert(CREATOR_KEY, p, abi.encodeWithSelector(ISVLaunchpad.BadName.selector));
        p.name = "abcdefghijklmnopqrstuvwxyz0123456"; // 33 bytes
        _expectLaunchRevert(CREATOR_KEY, p, abi.encodeWithSelector(ISVLaunchpad.BadName.selector));
        p.name = NAME;
        p.symbol = "";
        _expectLaunchRevert(CREATOR_KEY, p, abi.encodeWithSelector(ISVLaunchpad.BadSymbol.selector));
        p.symbol = unicode"éééééé"; // six characters, twelve bytes
        _expectLaunchRevert(CREATOR_KEY, p, abi.encodeWithSelector(ISVLaunchpad.BadSymbol.selector));
        p.symbol = SYMBOL;
        p.metadataUri = string(new bytes(129));
        _expectLaunchRevert(CREATOR_KEY, p, abi.encodeWithSelector(ISVLaunchpad.UriTooLong.selector));
        p.name = "abcdefghijklmnopqrstuvwxyz012345"; // 32 bytes
        p.symbol = "ABCDEFGHIJK"; // 11 bytes
        p.metadataUri = string(new bytes(128));
        address token = _launch(CREATOR_KEY, p);
        assertEq(SVLaunchToken(token).name(), p.name, "the longest name launches");
        assertEq(SVLaunchToken(token).symbol(), p.symbol, "the longest symbol launches");
        p = _params(creator, address(usdg), USDG_MIN, false);
        p.metadataUri = "";
        _launch(CREATOR_KEY, p);
    }

    function test_launch_reverts_CurrencyNotAllowed_and_ValuationOutOfRange_with_the_bounds() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        _expectLaunchRevert(
            CREATOR_KEY,
            _params(creator, address(other), USDG_MIN, true),
            abi.encodeWithSelector(ISVLaunchpad.CurrencyNotAllowed.selector)
        );
        _expectLaunchRevert(
            CREATOR_KEY,
            _params(creator, address(usdg), USDG_MIN - 1, true),
            abi.encodeWithSelector(ISVLaunchpad.ValuationOutOfRange.selector, USDG_MIN - 1, USDG_MIN, USDG_MAX)
        );
        _expectLaunchRevert(
            CREATOR_KEY,
            _params(creator, address(usdg), USDG_MAX + 1, true),
            abi.encodeWithSelector(ISVLaunchpad.ValuationOutOfRange.selector, USDG_MAX + 1, USDG_MIN, USDG_MAX)
        );
        vm.prank(owner);
        launchpad.setCurrency(address(usdg), 0, 0, 0);
        _expectLaunchRevert(
            CREATOR_KEY,
            _params(creator, address(usdg), USDG_MIN, true),
            abi.encodeWithSelector(ISVLaunchpad.CurrencyNotAllowed.selector)
        );
    }

    function test_launch_reverts_BadPayout_for_the_launchpad_or_the_pool_manager_before_any_pull() public {
        _expectNoPermitPull();
        ISVLaunchpad.LaunchParams memory p = _params(creator, address(usdg), USDG_MIN, true);
        p.firstBuy = 100e6;
        p.payout = address(launchpad);
        _expectLaunchRevert(CREATOR_KEY, p, abi.encodeWithSelector(ISVLaunchpad.BadPayout.selector));
        p.payout = address(manager);
        _expectLaunchRevert(CREATOR_KEY, p, abi.encodeWithSelector(ISVLaunchpad.BadPayout.selector));
    }

    function test_launch_reverts_PermitMismatch_for_another_token_or_a_short_permit_before_any_pull() public {
        _expectNoPermitPull();
        ISVLaunchpad.LaunchParams memory p = _params(creator, address(usdg), USDG_MIN, true);
        p.firstBuy = 100e6;
        (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory signature) =
            _permit(CREATOR_KEY, address(stk), 100e6);
        vm.prank(creator);
        vm.expectRevert(ISVLaunchpad.PermitMismatch.selector);
        launchpad.launch(p, permit, signature);
        (permit, signature) = _permit(CREATOR_KEY, address(usdg), 100e6 - 1);
        vm.prank(creator);
        vm.expectRevert(ISVLaunchpad.PermitMismatch.selector);
        launchpad.launch(p, permit, signature);
    }

    function test_Permit2_refuses_a_signature_by_another_key_and_a_reused_nonce() public {
        ISVLaunchpad.LaunchParams memory p = _params(creator, address(usdg), USDG_MIN, true);
        p.firstBuy = 100e6;
        (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory wrong) =
            _permit(STRANGER_KEY, address(usdg), 100e6);
        vm.prank(creator);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        launchpad.launch(p, permit, wrong);
        bytes memory right = Permit2Signer.sign(CREATOR_KEY, permit2, permit, address(launchpad));
        vm.prank(creator);
        launchpad.launch(p, permit, right);
        ISVLaunchpad.LaunchParams memory again = _params(creator, address(usdg), USDG_MIN, true);
        again.firstBuy = 100e6;
        vm.prank(creator);
        vm.expectRevert(InvalidNonce.selector);
        launchpad.launch(again, permit, right);
    }

    function test_a_fee_on_transfer_quote_fails_the_measured_pull_of_a_creation_fee_only_launch() public {
        MockQuirkyERC20 q = _quirkyQuote(25e6);
        q.setTransferFee(100, address(0));
        ISVLaunchpad.LaunchParams memory p = _params(creator, address(q), USDG_MIN, true);
        _expectLaunchRevert(CREATOR_KEY, p, abi.encodeWithSelector(ISVLaunchpad.PermitMismatch.selector));
        q.setTransferFee(0, address(0));
        _launch(CREATOR_KEY, p);
        assertEq(q.balanceOf(feeWallet), 25e6, "without the fee the creation fee arrives whole");
    }

    function test_a_fee_on_transfer_quote_fails_the_measured_pull_of_a_first_buy() public {
        MockQuirkyERC20 q = _quirkyQuote(0);
        q.setTransferFee(100, address(0));
        ISVLaunchpad.LaunchParams memory p = _params(creator, address(q), USDG_MIN, false);
        p.firstBuy = 100e6;
        _expectLaunchRevert(CREATOR_KEY, p, abi.encodeWithSelector(ISVLaunchpad.PermitMismatch.selector));
    }

    /// @dev Nothing is pulled for a free launch, so a taxed quote cannot short-pay anything: it launches.
    function test_a_free_launch_in_a_fee_on_transfer_quote_succeeds() public {
        MockQuirkyERC20 q = _quirkyQuote(0);
        q.setTransferFee(100, address(0));
        address token = _launchFree(address(q), USDG_MIN, true);
        assertEq(launchpad.getLaunch(token).quote, address(q), "launched in the taxed quote");
        assertEq(q.balanceOf(address(launchpad)), 0, "and holds none of it");
    }

    function test_a_quote_that_short_pays_the_pool_manager_reverts_CurrencyNotSettled() public {
        MockQuirkyERC20 q = _quirkyQuote(0);
        q.setTransferFee(100, address(manager));
        ISVLaunchpad.LaunchParams memory p = _params(creator, address(q), USDG_MIN, true);
        p.firstBuy = 100e6;
        _expectLaunchRevert(CREATOR_KEY, p, abi.encodeWithSelector(IPoolManager.CurrencyNotSettled.selector));
    }

    function test_a_fee_wallet_that_refuses_the_quote_stops_paid_launches_until_the_owner_moves_it() public {
        MockQuirkyERC20 q = _quirkyQuote(0);
        q.setRefusal(feeWallet, MockQuirkyERC20.Refusal.Revert);
        ISVLaunchpad.LaunchParams memory p = _params(creator, address(q), USDG_MIN, true);
        p.firstBuy = 100e6;
        _expectLaunchRevert(CREATOR_KEY, p, abi.encodeWithSelector(MockQuirkyERC20.Refused.selector, feeWallet));
        _launchFree(address(q), USDG_MIN, true);
        address other = makeAddr("other fee wallet");
        vm.prank(owner);
        launchpad.setFeeWallet(other);
        _launch(CREATOR_KEY, p);
        assertEq(q.balanceOf(other), 100e6 * 50 / 10_000, "the new fee wallet took the router fee");
    }

    // -------------------------------------------------------------------------------------------------------
    // The daily limit (spec section 4.5 step 3)
    // -------------------------------------------------------------------------------------------------------

    function test_the_daily_limit_allows_five_refuses_the_sixth_and_resets_at_00_00_UTC() public {
        for (uint256 i = 0; i < 5; i++) {
            _launchFree(address(usdg), USDG_MIN, i % 2 == 0);
        }
        assertEq(launchpad.launchesToday(creator), 5, "five today");
        uint256 midnight = (block.timestamp / 1 days + 1) * 1 days;
        vm.warp(midnight - 1);
        _expectLaunchRevert(
            CREATOR_KEY,
            _params(creator, address(usdg), USDG_MIN, true),
            abi.encodeWithSelector(ISVLaunchpad.DailyLimitReached.selector)
        );
        assertEq(launchpad.launchesToday(creator), 5, "still today at 23:59:59");
        vm.warp(midnight);
        assertEq(launchpad.launchesToday(creator), 0, "a new UTC day");
        _launchFree(address(usdg), USDG_MIN, true);
        assertEq(launchpad.launchesToday(creator), 1, "counting again");
        assertEq(launchpad.launchesToday(stranger), 0, "counts are per wallet");
    }

    function test_a_daily_limit_of_zero_stops_every_launch() public {
        vm.prank(owner);
        launchpad.setDailyLaunchLimit(0);
        _expectLaunchRevert(
            CREATOR_KEY,
            _params(creator, address(usdg), USDG_MIN, true),
            abi.encodeWithSelector(ISVLaunchpad.DailyLimitReached.selector)
        );
    }

    // -------------------------------------------------------------------------------------------------------
    // CREATE2, the front-run retry, settings fixed at launch (spec sections 4.1, 4.9, 4.10)
    // -------------------------------------------------------------------------------------------------------

    function test_the_same_wallet_salt_name_and_symbol_cannot_launch_twice_and_the_salt_is_per_wallet() public {
        ISVLaunchpad.LaunchParams memory p = _params(creator, address(usdg), USDG_MIN, true);
        address first = _launch(CREATOR_KEY, p);
        vm.prank(creator);
        vm.expectRevert();
        launchpad.launch(p, _emptyPermit(), "");
        gate.mint(stranger, 2);
        address second = _launch(STRANGER_KEY, p);
        assertTrue(second != first, "another caller with the same salt gets another address");
        assertEq(second, launchpad.predictToken(stranger, p.salt, NAME, SYMBOL), "the stranger's own prediction");
    }

    function test_a_front_run_initialize_reverts_PoolAlreadyInitialized_and_a_new_salt_launches() public {
        ISVLaunchpad.LaunchParams memory p = _params(creator, address(usdg), USDG_MIN, true);
        address predicted = launchpad.predictToken(creator, p.salt, NAME, SYMBOL);
        vm.prank(stranger);
        manager.initialize(_keyFor(predicted, address(usdg), address(0)), TickMath.getSqrtPriceAtTick(0));
        _expectLaunchRevert(CREATOR_KEY, p, abi.encodeWithSelector(Pool.PoolAlreadyInitialized.selector));
        address token = _launch(CREATOR_KEY, _params(creator, address(usdg), USDG_MIN, true));
        assertTrue(token != predicted, "the retry landed on a new address and a new key");
        assertEq(launchpad.launchesToday(creator), 1, "the failed attempt did not count");
    }

    function test_a_hook_set_after_a_launch_applies_to_later_launches_only() public {
        address first = _launchFree(address(usdg), USDG_MIN, true);
        address hookAddress = _hookAt(Hooks.AFTER_SWAP_FLAG);
        vm.prank(owner);
        launchpad.setHook(hookAddress);
        vm.recordLogs();
        address second = _launchFree(address(usdg), USDG_MIN, true);
        (, ISVLaunchpad.LaunchedData memory d) = _launchedFrom(vm.getRecordedLogs());
        assertEq(launchpad.getLaunch(first).hook, address(0), "the earlier launch stays hookless");
        assertEq(address(launchpad.poolKeyOf(first).hooks), address(0), "its key too");
        assertEq(launchpad.getLaunch(second).hook, hookAddress, "the later launch carries the hook");
        assertEq(address(launchpad.poolKeyOf(second).hooks), hookAddress, "in its pool key");
        assertEq(d.hook, hookAddress, "and in the event");
    }

    function test_the_creator_share_is_fixed_into_each_launch_at_launch_time() public {
        address first = _launchFree(address(usdg), USDG_MIN, true);
        vm.prank(owner);
        launchpad.setCreatorShare(5_000);
        vm.recordLogs();
        address second = _launchFree(address(usdg), USDG_MIN, false);
        (, ISVLaunchpad.LaunchedData memory d) = _launchedFrom(vm.getRecordedLogs());
        assertEq(launchpad.getLaunch(first).creatorShareBps, 7_000, "the earlier launch keeps 70 %");
        assertEq(launchpad.getLaunch(second).creatorShareBps, 5_000, "the later launch takes 50 %");
        assertEq(d.creatorShareBps, 5_000, "the event carries the launch's share");
    }

    // -------------------------------------------------------------------------------------------------------
    // The callback guards and the unknown-token views (spec sections 4.4, 4.8)
    // -------------------------------------------------------------------------------------------------------

    function test_unlockCallback_refuses_a_stranger_and_the_pool_manager_outside_a_launch() public {
        vm.prank(stranger);
        vm.expectRevert(ISVLaunchpad.NotPoolManager.selector);
        launchpad.unlockCallback("");
        vm.prank(address(manager));
        vm.expectRevert(ISVLaunchpad.UnexpectedCallback.selector);
        launchpad.unlockCallback("");
    }

    function test_getLaunch_is_empty_and_poolKeyOf_reverts_UnknownLaunch_for_an_unknown_token() public {
        assertEq(launchpad.getLaunch(address(usdg)).creator, address(0), "no launch for this address");
        vm.expectRevert(ISVLaunchpad.UnknownLaunch.selector);
        launchpad.poolKeyOf(address(usdg));
    }
}
