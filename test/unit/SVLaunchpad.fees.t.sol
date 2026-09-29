// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {ISVLaunchpad} from "../../src/interfaces/ISVLaunchpad.sol";
import {MockQuirkyERC20} from "../mocks/MockQuirkyERC20.sol";
import {MockBeforeSwapHook} from "../mocks/MockBeforeSwapHook.sol";
import {SVLaunchpadTestBase} from "./SVLaunchpad.t.sol";

/// @notice Spec section 4.6: `collectFees` pokes the position with a zero liquidity delta, takes the fees into
///         the launchpad measuring what arrived, splits them with the share fixed at launch, and delivers each
///         share with a tolerant transfer that credits `owed` on refusal; `claim`, `setPayout`, `uncollectedFees`,
///         and the storage layout of section 4.4. Trades go through v4-core's PoolSwapTest, paid by this contract.
contract SVLaunchpadFeesTest is SVLaunchpadTestBase {
    /// @dev Balances of the two recipients in both currencies of one launch.
    struct Balances {
        uint256 payoutToken;
        uint256 payoutQuote;
        uint256 walletToken;
        uint256 walletQuote;
    }

    function setUp() public override {
        super.setUp();
        usdg.mint(address(this), MINT);
        stk.mint(address(this), MINT);
    }

    function _balances(address token, address quote, address payout, address wallet)
        internal
        view
        returns (Balances memory b)
    {
        b.payoutToken = IERC20(token).balanceOf(payout);
        b.payoutQuote = IERC20(quote).balanceOf(payout);
        b.walletToken = IERC20(token).balanceOf(wallet);
        b.walletQuote = IERC20(quote).balanceOf(wallet);
    }

    /// @dev A free launch in a fresh quirky quote, this contract funded in it to trade.
    function _quirkyLaunch(bool tokenFirst) internal returns (MockQuirkyERC20 q, address token) {
        q = _quirkyQuote(0);
        q.mint(address(this), MINT);
        token = _launchFree(address(q), USDG_MIN, tokenFirst);
    }

    /// @dev The launchpad holds, per currency, exactly the sum of what it owes (spec section 4.6 invariant).
    function _assertHeldEqualsOwed(address quote, address token, address[3] memory accounts) internal view {
        uint256 owedQuote;
        uint256 owedToken;
        for (uint256 i = 0; i < accounts.length; i++) {
            owedQuote += launchpad.owed(accounts[i], quote);
            owedToken += launchpad.owed(accounts[i], token);
        }
        assertEq(IERC20(quote).balanceOf(address(launchpad)), owedQuote, "quote held equals the owed sum");
        assertEq(IERC20(token).balanceOf(address(launchpad)), owedToken, "token held equals the owed sum");
    }

    // -------------------------------------------------------------------------------------------------------
    // uncollectedFees and collectFees
    // -------------------------------------------------------------------------------------------------------

    function test_the_first_buys_pool_fee_shows_in_uncollectedFees_straight_after_in_both_orders() public {
        for (uint256 i = 0; i < 2; i++) {
            vm.recordLogs();
            address token = _launchWithBuy(address(usdg), USDG_MIN, i == 0, 1_000e6);
            (, ISVLaunchpad.LaunchedData memory d) = _launchedFrom(vm.getRecordedLogs());
            ISVLaunchpad.PendingFees memory f = launchpad.uncollectedFees(token);
            uint256 poolFee = d.firstBuyIn - FullMath.mulDiv(d.firstBuyIn, 990_000, 1_000_000);
            assertApproxEqAbs(f.quoteFees, poolFee, 1, "1 % of the net first buy accrued to the launch position");
            assertEq(f.tokenFees, 0, "no token came in");
            assertEq(f.quoteToPayout, f.quoteFees * 7_000 / 10_000, "70 % to the payout");
            assertEq(f.quoteToFeeWallet, f.quoteFees - f.quoteToPayout, "the rest to the fee wallet");
        }
    }

    function test_uncollectedFees_equals_what_collectFees_pays_after_trades_both_ways_in_both_orders() public {
        for (uint256 i = 0; i < 2; i++) {
            address token = _launchFree(address(usdg), USDG_MIN, i == 0);
            uint256 bought = _swap(token, true, 2_000e6);
            _swap(token, false, bought / 2);
            ISVLaunchpad.PendingFees memory f = launchpad.uncollectedFees(token);
            assertGt(f.tokenFees, 0, "token fees accrued on the sell");
            assertGt(f.quoteFees, 0, "quote fees accrued on the buy");
            Balances memory before = _balances(token, address(usdg), creator, feeWallet);
            vm.expectEmit(true, true, true, true, address(launchpad));
            emit ISVLaunchpad.FeesCollected(token, creator, f.tokenFees, f.quoteFees, f.tokenToPayout, f.quoteToPayout);
            vm.prank(stranger); // anyone may collect
            launchpad.collectFees(token);
            Balances memory got = _balances(token, address(usdg), creator, feeWallet);
            assertEq(got.payoutToken - before.payoutToken, f.tokenToPayout, "payout: token share to the unit");
            assertEq(got.payoutQuote - before.payoutQuote, f.quoteToPayout, "payout: quote share to the unit");
            assertEq(got.walletToken - before.walletToken, f.tokenToFeeWallet, "fee wallet: token share");
            assertEq(got.walletQuote - before.walletQuote, f.quoteToFeeWallet, "fee wallet: quote share");
            assertEq(IERC20(token).balanceOf(address(launchpad)), 0, "the launchpad keeps no token");
            assertEq(usdg.balanceOf(address(launchpad)), 0, "nor any quote");
            assertEq(_positionLiquidity(token), launchpad.getLaunch(token).liquidity, "the poke left L untouched");
            ISVLaunchpad.PendingFees memory rest = launchpad.uncollectedFees(token);
            assertEq(rest.tokenFees + rest.quoteFees, 0, "nothing uncollected after the collection");
        }
    }

    function test_collectFees_splits_70_30_with_the_rounding_dust_to_the_fee_wallet() public {
        address token = _launchFree(address(usdg), USDG_MIN, true);
        _swap(token, true, 1_234_567);
        ISVLaunchpad.PendingFees memory f = launchpad.uncollectedFees(token);
        assertGt(f.quoteFees * 7_000 % 10_000, 0, "this amount leaves rounding dust");
        assertEq(f.quoteToPayout, f.quoteFees * 7_000 / 10_000, "the payout's share rounds down");
        assertEq(f.quoteToFeeWallet, f.quoteFees - f.quoteToPayout, "the fee wallet takes the rest, dust included");
        uint256 creatorBefore = usdg.balanceOf(creator);
        launchpad.collectFees(token);
        assertEq(usdg.balanceOf(creator) - creatorBefore, f.quoteToPayout, "payout paid its floor");
        assertEq(usdg.balanceOf(feeWallet), f.quoteToFeeWallet, "fee wallet paid the rest");
    }

    function test_collectFees_reverts_NothingToCollect_before_any_trade_and_right_after_a_collection() public {
        address token = _launchFree(address(usdg), USDG_MIN, false);
        vm.expectRevert(ISVLaunchpad.NothingToCollect.selector);
        launchpad.collectFees(token);
        _swap(token, true, 1_000e6);
        launchpad.collectFees(token);
        vm.expectRevert(ISVLaunchpad.NothingToCollect.selector);
        launchpad.collectFees(token);
    }

    function test_a_second_collection_pays_only_the_fees_since_the_first() public {
        address token = _launchFree(address(usdg), USDG_MIN, true);
        _swap(token, true, 1_000e6);
        launchpad.collectFees(token);
        uint256 afterFirst = usdg.balanceOf(creator);
        _swap(token, true, 500e6);
        ISVLaunchpad.PendingFees memory f = launchpad.uncollectedFees(token);
        assertApproxEqAbs(f.quoteFees, 500e6 / 100, 1, "only the second trade's 1 %");
        launchpad.collectFees(token);
        assertEq(usdg.balanceOf(creator) - afterFirst, f.quoteToPayout, "only the new fees were paid");
    }

    function test_a_one_way_trade_pays_one_currency_and_transfers_nothing_in_the_other() public {
        address token = _launchFree(address(usdg), USDG_MIN, false);
        _swap(token, true, 1_000e6);
        vm.recordLogs();
        launchpad.collectFees(token);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 tokenFees, uint256 quoteFees,,) = _feesCollectedFrom(logs);
        assertEq(tokenFees, 0, "no token fees on a buy");
        assertGt(quoteFees, 0, "quote fees");
        assertEq(_transfersTo(logs, token, creator), 0, "no zero-value token transfer to the payout");
        assertEq(_transfersTo(logs, token, feeWallet), 0, "nor to the fee wallet");
    }

    function test_collectFees_and_uncollectedFees_revert_UnknownLaunch_for_an_unknown_token() public {
        vm.expectRevert(ISVLaunchpad.UnknownLaunch.selector);
        launchpad.collectFees(address(usdg));
        vm.expectRevert(ISVLaunchpad.UnknownLaunch.selector);
        launchpad.uncollectedFees(address(usdg));
    }

    // -------------------------------------------------------------------------------------------------------
    // setPayout
    // -------------------------------------------------------------------------------------------------------

    function test_only_the_current_payout_moves_it_and_the_creator_loses_that_right_once_it_hands_it_on() public {
        address token = _launchFree(address(usdg), USDG_MIN, true);
        address next = makeAddr("next payout");
        vm.prank(stranger);
        vm.expectRevert(ISVLaunchpad.NotPayout.selector);
        launchpad.setPayout(token, stranger);
        vm.expectEmit(true, true, true, true, address(launchpad));
        emit ISVLaunchpad.PayoutChanged(token, creator, next);
        vm.prank(creator);
        launchpad.setPayout(token, next);
        assertEq(launchpad.getLaunch(token).payout, next, "handed on");
        vm.prank(creator);
        vm.expectRevert(ISVLaunchpad.NotPayout.selector);
        launchpad.setPayout(token, creator);
        vm.prank(next);
        launchpad.setPayout(token, creator);
        assertEq(launchpad.getLaunch(token).payout, creator, "the current payout may hand it back");
    }

    function test_setPayout_reverts_UnknownLaunch_ZeroAddress_and_BadPayout() public {
        vm.expectRevert(ISVLaunchpad.UnknownLaunch.selector);
        launchpad.setPayout(address(usdg), creator);
        address token = _launchFree(address(usdg), USDG_MIN, true);
        vm.startPrank(creator);
        vm.expectRevert(ISVLaunchpad.ZeroAddress.selector);
        launchpad.setPayout(token, address(0));
        vm.expectRevert(ISVLaunchpad.BadPayout.selector);
        launchpad.setPayout(token, address(launchpad));
        vm.expectRevert(ISVLaunchpad.BadPayout.selector);
        launchpad.setPayout(token, address(manager));
        vm.stopPrank();
    }

    function test_fees_follow_the_payout_address() public {
        address token = _launchFree(address(usdg), USDG_MIN, true);
        address next = makeAddr("next payout");
        vm.prank(creator);
        launchpad.setPayout(token, next);
        _swap(token, true, 1_000e6);
        ISVLaunchpad.PendingFees memory f = launchpad.uncollectedFees(token);
        uint256 creatorBefore = usdg.balanceOf(creator);
        launchpad.collectFees(token);
        assertEq(usdg.balanceOf(next), f.quoteToPayout, "the new payout received the share");
        assertEq(usdg.balanceOf(creator), creatorBefore, "the creator's own address received nothing");
    }

    // -------------------------------------------------------------------------------------------------------
    // Delivery, owed and claim (spec section 4.6 steps 3 to 5, claim)
    // -------------------------------------------------------------------------------------------------------

    function test_a_payout_the_quote_refuses_is_credited_while_the_fee_wallet_is_paid() public {
        (MockQuirkyERC20 q, address token) = _quirkyLaunch(true);
        _swap(token, true, 1_000e6);
        ISVLaunchpad.PendingFees memory f = launchpad.uncollectedFees(token);
        q.setRefusal(creator, MockQuirkyERC20.Refusal.Revert);
        vm.expectEmit(true, true, true, true, address(launchpad));
        emit ISVLaunchpad.FeesCollected(token, creator, 0, f.quoteFees, 0, f.quoteToPayout);
        launchpad.collectFees(token);
        assertEq(q.balanceOf(feeWallet), f.quoteToFeeWallet, "the fee wallet was paid");
        assertEq(launchpad.owed(creator, address(q)), f.quoteToPayout, "the payout's share is credited");
        assertEq(q.balanceOf(address(launchpad)), f.quoteToPayout, "and held here, nothing else");
    }

    function test_a_fee_wallet_the_quote_refuses_is_credited_while_the_payout_is_paid() public {
        (MockQuirkyERC20 q, address token) = _quirkyLaunch(false);
        _swap(token, true, 1_000e6);
        ISVLaunchpad.PendingFees memory f = launchpad.uncollectedFees(token);
        q.setRefusal(feeWallet, MockQuirkyERC20.Refusal.Revert);
        uint256 creatorBefore = q.balanceOf(creator);
        launchpad.collectFees(token);
        assertEq(q.balanceOf(creator) - creatorBefore, f.quoteToPayout, "the payout was paid");
        assertEq(launchpad.owed(feeWallet, address(q)), f.quoteToFeeWallet, "the fee wallet's share is credited");
        assertEq(q.balanceOf(address(launchpad)), f.quoteToFeeWallet, "and held here");
    }

    function test_a_false_answer_counts_as_refused_and_no_return_data_counts_as_paid() public {
        (MockQuirkyERC20 q, address token) = _quirkyLaunch(true);
        _swap(token, true, 1_000e6);
        ISVLaunchpad.PendingFees memory f = launchpad.uncollectedFees(token);
        q.setRefusal(creator, MockQuirkyERC20.Refusal.ReturnFalse);
        q.setNoReturnData(true);
        uint256 creatorBefore = q.balanceOf(creator);
        launchpad.collectFees(token);
        assertEq(q.balanceOf(creator), creatorBefore, "a false answer moved nothing");
        assertEq(launchpad.owed(creator, address(q)), f.quoteToPayout, "and is credited");
        assertEq(q.balanceOf(feeWallet), f.quoteToFeeWallet, "no return data is a delivery");
        assertEq(launchpad.owed(feeWallet, address(q)), 0, "nothing credited to the fee wallet");
    }

    function test_claim_pays_the_owed_balance_once_then_reverts_NothingOwed() public {
        (MockQuirkyERC20 q, address token) = _quirkyLaunch(true);
        _swap(token, true, 1_000e6);
        q.setRefusal(creator, MockQuirkyERC20.Refusal.Revert);
        launchpad.collectFees(token);
        uint256 owedAmount = launchpad.owed(creator, address(q));
        assertGt(owedAmount, 0, "credited");
        q.setRefusal(creator, MockQuirkyERC20.Refusal.None);
        uint256 before = q.balanceOf(creator);
        vm.prank(creator);
        launchpad.claim(address(q), creator);
        assertEq(q.balanceOf(creator) - before, owedAmount, "paid in full");
        assertEq(launchpad.owed(creator, address(q)), 0, "zeroed");
        assertEq(q.balanceOf(address(launchpad)), 0, "nothing left here");
        vm.prank(creator);
        vm.expectRevert(ISVLaunchpad.NothingOwed.selector);
        launchpad.claim(address(q), creator);
    }

    function test_a_claim_the_token_refuses_reverts_and_a_claim_to_another_address_pays_in_full() public {
        (MockQuirkyERC20 q, address token) = _quirkyLaunch(false);
        _swap(token, true, 1_000e6);
        q.setRefusal(creator, MockQuirkyERC20.Refusal.Revert);
        launchpad.collectFees(token);
        uint256 owedAmount = launchpad.owed(creator, address(q));
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(MockQuirkyERC20.Refused.selector, creator));
        launchpad.claim(address(q), creator);
        assertEq(launchpad.owed(creator, address(q)), owedAmount, "a failed claim leaves the balance");
        address rescue = makeAddr("rescue");
        vm.prank(creator);
        launchpad.claim(address(q), rescue);
        assertEq(q.balanceOf(rescue), owedAmount, "the second address received it all");
        assertEq(launchpad.owed(creator, address(q)), 0, "zeroed");
    }

    function test_claim_reverts_BadPayout_for_zero_the_launchpad_and_the_pool_manager() public {
        vm.startPrank(creator);
        vm.expectRevert(ISVLaunchpad.BadPayout.selector);
        launchpad.claim(address(usdg), address(0));
        vm.expectRevert(ISVLaunchpad.BadPayout.selector);
        launchpad.claim(address(usdg), address(launchpad));
        vm.expectRevert(ISVLaunchpad.BadPayout.selector);
        launchpad.claim(address(usdg), address(manager));
        vm.stopPrank();
    }

    function test_a_fee_on_transfer_quote_is_split_on_what_arrived() public {
        (MockQuirkyERC20 q, address token) = _quirkyLaunch(true);
        _swap(token, true, 1_000e6);
        ISVLaunchpad.PendingFees memory f = launchpad.uncollectedFees(token);
        q.setTransferFee(100, address(0));
        uint256 measured = f.quoteFees - f.quoteFees * 100 / 10_000;
        uint256 toPayout = measured * 7_000 / 10_000;
        vm.expectEmit(true, true, true, true, address(launchpad));
        emit ISVLaunchpad.FeesCollected(token, creator, 0, measured, 0, toPayout);
        launchpad.collectFees(token);
        assertEq(q.balanceOf(address(launchpad)), 0, "every measured unit left; nothing of earlier credits was used");
        assertEq(launchpad.owed(creator, address(q)) + launchpad.owed(feeWallet, address(q)), 0, "nothing credited");
    }

    function test_the_launchpads_balance_equals_the_owed_sum_through_failed_deliveries_and_claims() public {
        (MockQuirkyERC20 q, address token) = _quirkyLaunch(false);
        address rescue = makeAddr("rescue");
        address[3] memory accounts = [creator, feeWallet, rescue];
        _swap(token, true, 2_000e6);
        q.setRefusal(creator, MockQuirkyERC20.Refusal.Revert);
        launchpad.collectFees(token);
        _assertHeldEqualsOwed(address(q), token, accounts);
        uint256 bought = _swap(token, true, 1_000e6);
        _swap(token, false, bought / 2);
        q.setTransferFee(100, address(0));
        q.setRefusal(feeWallet, MockQuirkyERC20.Refusal.ReturnFalse);
        launchpad.collectFees(token);
        _assertHeldEqualsOwed(address(q), token, accounts);
        vm.prank(creator);
        launchpad.claim(address(q), rescue);
        _assertHeldEqualsOwed(address(q), token, accounts);
        assertGt(launchpad.owed(feeWallet, address(q)), 0, "the fee wallet's refused share still waits");
    }

    // -------------------------------------------------------------------------------------------------------
    // Review focus 1, 2 and 5
    // -------------------------------------------------------------------------------------------------------

    function test_settings_changed_after_a_launch_touch_it_only_through_the_fee_wallet() public {
        address token = _launchFree(address(usdg), USDG_MIN, true);
        _swap(token, true, 1_000e6);
        address newWallet = makeAddr("new fee wallet");
        address laterHook = _hookAt(Hooks.AFTER_SWAP_FLAG);
        address unheldGate = makeAddr("a gate nobody holds");
        vm.startPrank(owner);
        launchpad.setCurrency(address(usdg), 0, 0, 0);
        launchpad.setCreatorShare(0);
        launchpad.setRouterFee(0);
        launchpad.setFirstBuyCap(0);
        launchpad.setDailyLaunchLimit(0);
        launchpad.setLauncherGate(unheldGate);
        launchpad.setHook(laterHook);
        launchpad.setFeeWallet(newWallet);
        vm.stopPrank();
        ISVLaunchpad.PendingFees memory f = launchpad.uncollectedFees(token);
        assertEq(f.quoteToPayout, f.quoteFees * 7_000 / 10_000, "the share fixed at launch still applies");
        uint256 creatorBefore = usdg.balanceOf(creator);
        vm.prank(stranger);
        launchpad.collectFees(token);
        assertEq(usdg.balanceOf(creator) - creatorBefore, f.quoteToPayout, "the payout still earns 70 %");
        assertEq(usdg.balanceOf(newWallet), f.quoteToFeeWallet, "the platform share follows the new fee wallet");
        assertEq(usdg.balanceOf(feeWallet), 0, "the old fee wallet gets nothing new");
        address next = makeAddr("next payout");
        vm.prank(creator);
        launchpad.setPayout(token, next);
        assertEq(launchpad.getLaunch(token).payout, next, "payout changes still work");
        assertEq(launchpad.getLaunch(token).hook, address(0), "the launch keeps its hookless key");
        assertEq(_positionLiquidity(token), launchpad.getLaunch(token).liquidity, "the position is untouched");
    }

    /// @dev Audit finding L-01 regression: a launch made under an allowed hook, here a live before-swap-only hook
    ///      as an anti-snipe hook would be, still trades and still collects through the zero-delta fee poke.
    function test_a_launch_under_an_allowed_before_swap_hook_trades_and_collects_fees() public {
        address hookAddress = _hookAt(Hooks.BEFORE_SWAP_FLAG);
        vm.etch(hookAddress, address(new MockBeforeSwapHook()).code);
        vm.prank(owner);
        launchpad.setHook(hookAddress);
        address token = _launchFree(address(usdg), USDG_MIN, true);
        assertEq(launchpad.getLaunch(token).hook, hookAddress, "the launch carries the hook");
        assertGt(_swap(token, true, 1_000e6), 0, "the buy went through the hook");
        assertEq(MockBeforeSwapHook(hookAddress).swaps(), 1, "the hook saw the trade");
        ISVLaunchpad.PendingFees memory f = launchpad.uncollectedFees(token);
        assertGt(f.quoteFees, 0, "the trade earned a fee");
        uint256 creatorBefore = usdg.balanceOf(creator);
        vm.prank(stranger);
        launchpad.collectFees(token);
        assertEq(usdg.balanceOf(creator) - creatorBefore, f.quoteToPayout, "the payout was paid");
        assertEq(usdg.balanceOf(feeWallet), f.quoteToFeeWallet, "and the fee wallet");
    }

    function test_a_sell_before_the_first_buy_costs_nothing_leaves_nothing_to_collect_and_changes_no_price() public {
        for (uint256 i = 0; i < 2; i++) {
            address token = _launchFree(address(usdg), USDG_MIN, i == 0);
            uint256 snapshot = vm.snapshotState();
            uint256 plainBuy = _swap(token, true, 1_000e6);
            vm.revertToState(snapshot);
            uint256 quoteBefore = usdg.balanceOf(address(this));
            assertEq(IERC20(token).balanceOf(address(this)), 0, "the seller holds no token at all");
            uint256 received = _swap(token, false, 1_000_000e18);
            assertEq(received, 0, "the seller received nothing");
            assertEq(usdg.balanceOf(address(this)), quoteBefore, "and paid nothing");
            vm.expectRevert(ISVLaunchpad.NothingToCollect.selector);
            launchpad.collectFees(token);
            assertEq(_swap(token, true, 1_000e6), plainBuy, "the next buy gets exactly what it would have got");
        }
    }

    function test_owed_shares_from_two_launches_in_one_currency_add_up_and_one_claim_pays_both() public {
        MockQuirkyERC20 q = _quirkyQuote(0);
        q.mint(address(this), MINT);
        address first = _launchFree(address(q), USDG_MIN, true);
        address second = _launchFree(address(q), USDG_MIN, false);
        _swap(first, true, 1_000e6);
        _swap(second, true, 2_000e6);
        uint256 expected =
            launchpad.uncollectedFees(first).quoteToPayout + launchpad.uncollectedFees(second).quoteToPayout;
        q.setRefusal(creator, MockQuirkyERC20.Refusal.Revert);
        launchpad.collectFees(first);
        launchpad.collectFees(second);
        assertEq(launchpad.owed(creator, address(q)), expected, "both launches' shares in one balance");
        q.setRefusal(creator, MockQuirkyERC20.Refusal.None);
        uint256 before = q.balanceOf(creator);
        vm.prank(creator);
        launchpad.claim(address(q), creator);
        assertEq(q.balanceOf(creator) - before, expected, "one claim paid both");
    }

    // -------------------------------------------------------------------------------------------------------
    // Storage layout (spec section 4.4)
    // -------------------------------------------------------------------------------------------------------

    function test_the_storage_layout_matches_spec_section_4_4() public {
        (MockQuirkyERC20 q, address token) = _quirkyLaunch(true);
        _swap(token, true, 1_000e6);
        q.setRefusal(creator, MockQuirkyERC20.Refusal.Revert);
        launchpad.collectFees(token);
        address lp = address(launchpad);
        assertEq(address(uint160(uint256(vm.load(lp, bytes32(uint256(0)))))), owner, "slot 0: Ownable._owner");
        uint256 slot2 = uint256(vm.load(lp, bytes32(uint256(2))));
        // The casts below cut packed fields out of one storage word on purpose; truncation is the point.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(address(uint160(slot2)), feeWallet, "slot 2: feeWallet");
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(uint16(slot2 >> 160), 50, "slot 2: routerFeeBps");
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(uint16(slot2 >> 176), 7_000, "slot 2: creatorShareBps");
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(uint16(slot2 >> 192), 2_000, "slot 2: firstBuyCapBps");
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(uint8(slot2 >> 208), 5, "slot 2: dailyLaunchLimit");
        assertEq(address(uint160(uint256(vm.load(lp, bytes32(uint256(3)))))), address(gate), "slot 3: launcherGate");
        assertEq(uint256(vm.load(lp, bytes32(uint256(4)))), 0, "slot 4: hook");
        assertEq(uint256(vm.load(lp, bytes32(uint256(5)))), 1, "slot 5: launchCount");
        assertEq(
            uint256(vm.load(lp, keccak256(abi.encode(address(q), uint256(6))))),
            USDG_MIN,
            "slot 6: currencies, minValuation first"
        );
        bytes32 launchSlot = keccak256(abi.encode(token, uint256(7)));
        uint256 first = uint256(vm.load(lp, launchSlot));
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(address(uint160(first)), creator, "slot 7: launches, creator first");
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(uint64(first >> 160), block.timestamp, "then launchedAt");
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(uint16(first >> 224), 7_000, "then creatorShareBps");
        assertEq(
            address(uint160(uint256(vm.load(lp, bytes32(uint256(launchSlot) + 2))))),
            address(q),
            "the third word is the quote"
        );
        uint256 dayWord = uint256(vm.load(lp, keccak256(abi.encode(creator, uint256(8)))));
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(uint64(dayWord), block.timestamp / 1 days, "slot 8: days, the day number");
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(uint8(dayWord >> 64), 1, "then the count");
        bytes32 owedSlot = keccak256(abi.encode(address(q), keccak256(abi.encode(creator, uint256(9)))));
        assertGt(launchpad.owed(creator, address(q)), 0, "a credited share to find");
        assertEq(uint256(vm.load(lp, owedSlot)), launchpad.owed(creator, address(q)), "slot 9: owed[account][currency]");
    }
}
