// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {SVLaunchpad} from "../../src/SVLaunchpad.sol";
import {ISVLaunchpad} from "../../src/interfaces/ISVLaunchpad.sol";
import {ISVRouter} from "../../src/interfaces/ISVRouter.sol";
import {Permit2Signer} from "../utils/Permit2Signer.sol";

/// @notice The launchpad against the real Robinhood Chain: a fresh SVLaunchpad in front of the deployed PoolManager
///         and the canonical Permit2, launching in USDG with no first buy and in NVDA with one, trading the new
///         pools through the deployed SVRouter and the Universal Router it forwards to, with the V4 Quoter agreeing
///         to the unit, and `uncollectedFees` checked against the deployed StateView's fee maths and an actual
///         collection. This is the proof that the deployed PoolManager's storage matches v4.0.0 (spec 4.6).
/// @dev Skipping: `setUp` calls `vm.skip(true)` and returns when `ROBINHOOD_RPC_URL` is unset, so a run with no
///      network reports these tests as skipped, never failed. Every assertion is relative to the forked state.
///      Funding is by `deal`, asserted; if the USDG assertion fails, fund by pranking the PoolManager, which holds
///      USDG for the live pools: `vm.prank(POOL_MANAGER); IERC20(USDG).transfer(wallet, amount);`.
contract SVLaunchpadForkTest is Test {
    /// @dev Robinhood Chain (id 4663): the head 75,238,614 minus 200, read at 00:47 UTC on 29 Sep 2026. Re-pin per
    ///      the plan's Task 5 Step 3 before running.
    uint256 internal constant FORK_BLOCK = 75_238_414;

    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    ISVRouter internal constant SVROUTER = ISVRouter(0xc9E6b76aA834e746080b1F8Ad6943930eD5147a9);
    IV4Quoter internal constant QUOTER = IV4Quoter(0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94);
    IStateView internal constant STATE_VIEW = IStateView(0xF3334192D15450CdD385c8B70e03f9A6bD9E673b);
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // 6 decimals
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC; // 18 decimals
    address internal constant SUITS_NFT = 0x05C2174aa494BBDf72AEeab0cA3C10216D33B297;
    string internal constant URI = "ipfs://bafkreigh2akiscaildcqabsyg3dfr6chu3fgpregiymsck7e7aqa4s52zy";

    uint256 internal constant CREATOR_KEY = 0xC4EA;
    uint256 internal constant OWNER_KEY = 0x0E7E;
    uint256 internal constant FEE_WALLET_KEY = 0xFEE7;
    uint256 internal constant TRADER_KEY = 0x7A4DE;

    SVLaunchpad internal launchpad;
    address internal creator;
    address internal owner;
    address internal feeWallet;
    address internal trader;
    uint256 internal nextNonce;

    function setUp() public {
        string memory rpcUrl = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            // No network configured: the whole contract is skipped, not failed.
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpcUrl, vm.envOr("ROBINHOOD_FORK_BLOCK", FORK_BLOCK));
        assertEq(block.chainid, 4663, "forked the wrong chain");
        console2.log("forked block", block.number);

        creator = vm.addr(CREATOR_KEY);
        owner = vm.addr(OWNER_KEY);
        feeWallet = vm.addr(FEE_WALLET_KEY);
        trader = vm.addr(TRADER_KEY);
        vm.label(creator, "creator");
        vm.label(feeWallet, "feeWallet");
        vm.label(trader, "trader");
        vm.label(POOL_MANAGER, "PoolManager");
        vm.label(PERMIT2, "Permit2");
        vm.label(USDG, "USDG");
        vm.label(NVDA, "NVDA");

        launchpad =
            new SVLaunchpad(IPoolManager(POOL_MANAGER), ISignatureTransfer(PERMIT2), owner, feeWallet, SUITS_NFT);
        assertFalse(launchpad.isAllowedLauncher(creator), "through the real Suits NFT a fresh key is not a holder");
        vm.startPrank(owner);
        launchpad.setLauncherGate(address(0));
        launchpad.setCurrency(USDG, 5_000e6, 10_000_000e6, 0);
        launchpad.setCurrency(NVDA, 1e18, 1e24, 0);
        vm.stopPrank();
        _fund(creator);
        _fund(trader);
    }

    function _fund(address wallet) internal {
        deal(USDG, wallet, 100_000e6);
        deal(NVDA, wallet, 100e18);
        assertEq(IERC20(USDG).balanceOf(wallet), 100_000e6, "deal did not fund USDG");
        assertEq(IERC20(NVDA).balanceOf(wallet), 100e18, "deal did not fund NVDA");
        vm.startPrank(wallet);
        IERC20(USDG).approve(PERMIT2, type(uint256).max);
        IERC20(NVDA).approve(PERMIT2, type(uint256).max);
        vm.stopPrank();
    }

    /// @dev One launch by the creator; the Permit2 message is signed before the prank.
    function _launch(address quote, uint256 valuation, uint256 firstBuy, bytes32 salt)
        internal
        returns (address token)
    {
        ISVLaunchpad.LaunchParams memory p = ISVLaunchpad.LaunchParams({
            name: "Fork Launch",
            symbol: "FORK",
            metadataUri: URI,
            quote: quote,
            valuation: valuation,
            firstBuy: firstBuy,
            minFirstBuyTokens: 0,
            payout: address(0),
            salt: salt,
            deadline: block.timestamp + 1 hours
        });
        ISignatureTransfer.PermitTransferFrom memory permit;
        bytes memory signature;
        if (firstBuy > 0) {
            permit = ISignatureTransfer.PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions({token: quote, amount: firstBuy}),
                nonce: nextNonce++,
                deadline: block.timestamp + 1 hours
            });
            signature = Permit2Signer.sign(CREATOR_KEY, PERMIT2, permit, address(launchpad));
        }
        vm.prank(creator);
        uint256 gasBefore = gasleft();
        token = launchpad.launch(p, permit, signature);
        console2.log("launch gas, first buy", firstBuy, gasBefore - gasleft());
    }

    /// @dev One trade through the deployed SVRouter, which forwards it to the deployed Universal Router. The V4
    ///      Quoter's quote for the router's net input must equal what the trader receives, to the unit.
    function _trade(PoolKey memory key, bool zeroForOne, uint128 amountIn) internal returns (uint256 amountOut) {
        address tokenIn = Currency.unwrap(zeroForOne ? key.currency0 : key.currency1);
        (uint256 fee,) = SVROUTER.feeFor(trader, amountIn);
        (uint256 quoted,) = QUOTER.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                // fee <= amountIn / 200, so the difference fits the uint128 it came from.
                // forge-lint: disable-next-line(unsafe-typecast)
                exactAmount: uint128(amountIn - fee),
                hookData: ""
            })
        );
        ISVRouter.SwapParams memory p = ISVRouter.SwapParams({
            key: key,
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            amountOutMin: 1,
            hookData: "",
            deadline: block.timestamp + 1 hours
        });
        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: tokenIn, amount: amountIn}),
            nonce: nextNonce++,
            deadline: block.timestamp + 1 hours
        });
        bytes memory signature = Permit2Signer.sign(TRADER_KEY, PERMIT2, permit, address(SVROUTER));
        vm.prank(trader);
        amountOut = SVROUTER.swapExactIn(p, permit, signature);
        console2.log("trade in, router fee", amountIn, fee);
        console2.log("trade quoted, received", quoted, amountOut);
        assertEq(amountOut, quoted, "the Universal Router paid exactly what the V4 Quoter quoted");
    }

    function _range(address token) internal view returns (int24 tickLower, int24 tickUpper) {
        ISVLaunchpad.Launch memory l = launchpad.getLaunch(token);
        return l.tokenIsCurrency0 ? (l.openTick, int24(887_200)) : (int24(-887_200), l.openTick);
    }

    /// @dev `Position.update`'s maths over the deployed StateView, independent of the launchpad's StateLibrary.
    function _stateViewFees(address token) internal view returns (uint256 tokenFees, uint256 quoteFees) {
        (int24 tickLower, int24 tickUpper) = _range(token);
        PoolId id = launchpad.poolKeyOf(token).toId();
        (uint256 fees0, uint256 fees1) = _positionFees(id, tickLower, tickUpper);
        (tokenFees, quoteFees) = launchpad.getLaunch(token).tokenIsCurrency0 ? (fees0, fees1) : (fees1, fees0);
    }

    function _positionFees(PoolId id, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint256 fees0, uint256 fees1)
    {
        (uint128 liquidity, uint256 last0, uint256 last1) =
            STATE_VIEW.getPositionInfo(id, address(launchpad), tickLower, tickUpper, bytes32(0));
        (uint256 inside0, uint256 inside1) = STATE_VIEW.getFeeGrowthInside(id, tickLower, tickUpper);
        unchecked {
            fees0 = FullMath.mulDiv(inside0 - last0, liquidity, FixedPoint128.Q128);
            fees1 = FullMath.mulDiv(inside1 - last1, liquidity, FixedPoint128.Q128);
        }
    }

    /// @dev The launch transaction's one `Initialize` log from the PoolManager names the launch pool and records the
    ///      opening: exactly the snapped tick and its price, at a 1 % fee and a spacing of 200. The log is the
    ///      opening's record even when a first buy in the same transaction has already moved the price.
    function _assertInitializeLog(Vm.Log[] memory logs, PoolKey memory key, int24 openTick) internal pure {
        uint256 seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != POOL_MANAGER || logs[i].topics[0] != IPoolManager.Initialize.selector) continue;
            seen++;
            assertEq(logs[i].topics[1], PoolId.unwrap(key.toId()), "Initialize.id is the launch pool");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), Currency.unwrap(key.currency0), "currency0");
            assertEq(address(uint160(uint256(logs[i].topics[3]))), Currency.unwrap(key.currency1), "currency1");
            (uint24 fee, int24 tickSpacing,, uint160 sqrtPriceX96, int24 tick) =
                abi.decode(logs[i].data, (uint24, int24, address, uint160, int24));
            assertEq(fee, 10_000, "Initialize.fee is 1 %");
            assertEq(tickSpacing, 200, "Initialize.tickSpacing is 200");
            assertEq(tick, openTick, "the real pool opened at the snapped tick");
            assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(openTick), "exactly at its price");
        }
        assertEq(seen, 1, "exactly one Initialize in the launch");
    }

    function _launchedFrom(Vm.Log[] memory logs) internal view returns (ISVLaunchpad.LaunchedData memory d) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(launchpad) || logs[i].topics[0] != ISVLaunchpad.Launched.selector) continue;
            return abi.decode(logs[i].data, (ISVLaunchpad.LaunchedData));
        }
        revert("no Launched event in the recorded logs");
    }

    /// @dev The real pool holds L at a 1 % LP fee and, when nothing has traded yet, still sits exactly at the
    ///      snapped tick; logs the protocol fee facts spec section 12 asks for.
    function _assertOpened(address token, bool untraded) internal view {
        ISVLaunchpad.Launch memory l = launchpad.getLaunch(token);
        PoolId id = launchpad.poolKeyOf(token).toId();
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = STATE_VIEW.getSlot0(id);
        if (untraded) {
            assertEq(tick, l.openTick, "the untraded pool sits at the snapped tick");
            assertEq(price, TickMath.getSqrtPriceAtTick(l.openTick), "exactly at its price");
        }
        assertEq(lpFee, 10_000, "1 % LP fee");
        (int24 tickLower, int24 tickUpper) = _range(token);
        (uint128 liquidity,,) = STATE_VIEW.getPositionInfo(id, address(launchpad), tickLower, tickUpper, bytes32(0));
        assertEq(liquidity, l.liquidity, "the position holds L");
        console2.log("pool protocolFee", protocolFee);
        console2.log("PoolManager protocolFeeController", IPoolManager(POOL_MANAGER).protocolFeeController());
    }

    function test_usdg_free_launch_trades_both_ways_and_collects_what_stateview_predicts() public {
        vm.recordLogs();
        address token = _launch(USDG, 5_000e6, 0, keccak256("fork usdg"));
        PoolKey memory key = launchpad.poolKeyOf(token);
        _assertInitializeLog(vm.getRecordedLogs(), key, launchpad.getLaunch(token).openTick);
        _assertOpened(token, true);

        bool usdgIs0 = Currency.unwrap(key.currency0) == USDG;
        uint256 bought = _trade(key, usdgIs0, 100e6);
        assertEq(IERC20(token).balanceOf(trader), bought, "the trader holds the tokens");
        vm.prank(trader);
        IERC20(token).approve(PERMIT2, type(uint256).max);
        // forge-lint: disable-next-line(unsafe-typecast)
        _trade(key, !usdgIs0, uint128(bought / 2));

        (uint256 svTokenFees, uint256 svQuoteFees) = _stateViewFees(token);
        ISVLaunchpad.PendingFees memory f = launchpad.uncollectedFees(token);
        assertEq(f.tokenFees, svTokenFees, "uncollectedFees equals StateView's fee maths, token");
        assertEq(f.quoteFees, svQuoteFees, "uncollectedFees equals StateView's fee maths, quote");
        assertGt(f.tokenFees, 0, "the sell paid token fees");
        assertGt(f.quoteFees, 0, "the buy paid quote fees");

        uint256 creatorUsdg = IERC20(USDG).balanceOf(creator);
        launchpad.collectFees(token);
        assertEq(IERC20(USDG).balanceOf(creator) - creatorUsdg, f.quoteToPayout, "the payout's quote share");
        assertEq(IERC20(USDG).balanceOf(feeWallet), f.quoteToFeeWallet, "the fee wallet's quote share");
        assertEq(IERC20(token).balanceOf(creator), f.tokenToPayout, "the payout's token share");
        assertEq(IERC20(token).balanceOf(feeWallet), f.tokenToFeeWallet, "the fee wallet's token share");
        assertEq(IERC20(USDG).balanceOf(address(launchpad)), 0, "the launchpad keeps no USDG");
    }

    function test_nvda_launch_with_a_first_buy_pays_the_creator_the_router_fee_and_the_pool_fee() public {
        uint256 firstBuy = 1e18;
        vm.recordLogs();
        address token = _launch(NVDA, 50e18, firstBuy, keccak256("fork nvda"));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        PoolKey memory key = launchpad.poolKeyOf(token);
        _assertInitializeLog(logs, key, launchpad.getLaunch(token).openTick);
        // The first buy in the launch transaction moved the price off the opening, so only the log records it.
        _assertOpened(token, false);
        ISVLaunchpad.LaunchedData memory d = _launchedFrom(logs);
        assertEq(d.routerFee, firstBuy * 50 / 10_000, "router fee out of the first buy");
        assertEq(d.firstBuyIn, firstBuy - d.routerFee, "the net went into the pool");
        assertGt(d.firstBuyTokens, 0, "the first buy bought");
        assertEq(IERC20(token).balanceOf(creator), d.firstBuyTokens, "the creator holds the first buy");
        assertEq(IERC20(NVDA).balanceOf(feeWallet), d.routerFee, "the fee wallet holds the router fee");
        assertEq(IERC20(NVDA).balanceOf(address(launchpad)), 0, "the launchpad keeps no NVDA");

        ISVLaunchpad.PendingFees memory f = launchpad.uncollectedFees(token);
        (, uint256 svQuoteFees) = _stateViewFees(token);
        assertEq(f.quoteFees, svQuoteFees, "uncollectedFees equals StateView's fee maths");
        uint256 poolFee = d.firstBuyIn - FullMath.mulDiv(d.firstBuyIn, 990_000, 1_000_000);
        assertLe(f.quoteFees, poolFee, "the position earned at most the 1 % pool fee");
        (,, uint24 protocolFee,) = STATE_VIEW.getSlot0(key.toId());
        if (protocolFee == 0) assertApproxEqAbs(f.quoteFees, poolFee, 1, "with no protocol fee, all of it");

        _trade(key, Currency.unwrap(key.currency0) == NVDA, 1e17);
    }
}
