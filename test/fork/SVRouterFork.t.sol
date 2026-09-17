// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {SVRouter} from "../../src/SVRouter.sol";
import {ISVRouter} from "../../src/interfaces/ISVRouter.sol";
import {MockERC721} from "../mocks/MockERC721.sol";
import {Permit2Signer} from "../utils/Permit2Signer.sol";

/// @notice The whole trade path against the real Robinhood Chain: a freshly deployed `SVRouter` in front of the
///         deployed Universal Router and the canonical Permit2, trading the three pools of the spec's section 2
///         in both directions with real Permit2 signatures from a `vm.addr` key.
///
/// @dev What this suite is for, and what the unit suite cannot say:
///      the unit suite proves the router's *calldata* is what the spec describes, against a mock that decodes it.
///      Only this suite proves the deployed Universal Router accepts that calldata, that the deployed pools and
///      their hooks (Pons' MemeHook, LONG's Doppler hook) behave the way the app's quote says they will, that the
///      Robinhood stock token NVDA carries no transfer restriction that would block Permit2 or the pool (spec
///      section 7, first risk), and that after every call - successful or reverted - neither this router nor the
///      Universal Router is left holding anything.
///
///      Skipping: `setUp` calls `vm.skip(true)` and returns when `ROBINHOOD_RPC_URL` is unset, so `forge test`
///      with no network reports these tests as skipped, never as failed (spec section 6).
///
///      The pinned block: `FORK_BLOCK` is the block this suite was written against, so Foundry's RPC cache makes
///      reruns cheap. The public endpoint is *not* a full archive: on 17 Sep 2026 it served roughly the last
///      50_000 blocks (about 80 minutes at this chain's ~0.1 s blocks) and answered
///      `historical state ... is not available` for anything older. A rerun long after the pin therefore needs
///      either Foundry's cache from an earlier run or a fresh block, which `ROBINHOOD_FORK_BLOCK` supplies
///      without editing this file. Every assertion here is relative to the state of whichever block is used -
///      the quote is read from the same fork, at the same state, as the swap it bounds - so a re-pin changes the
///      numbers in the logs and nothing else.
contract SVRouterForkTest is Test {
    // -------------------------------------------------------------------------------------------------------
    // Chain facts (spec section 2). Addresses are the spec's, in their EIP-55 checksummed spelling.
    // -------------------------------------------------------------------------------------------------------

    /// @dev Robinhood Chain (id 4663), block 65_232_000, 17 Sep 2026 08:42 UTC (16:42 Manila). The block this
    ///      suite was written and run against; see the note above on re-pinning past the endpoint's window.
    uint256 internal constant FORK_BLOCK = 65_232_000;

    address internal constant UNIVERSAL_ROUTER = 0x06AfBA43Fd06227fA663b0DAecF536f6EaA6bf99;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    IV4Quoter internal constant QUOTER = IV4Quoter(0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94);

    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant MARIO = 0x7a492b0A2d630b94791Af846C1842Db9e623420c;
    address internal constant MICRODUCK = 0xD5f1afEA47b1A9eab414D2ee740cF1d6d039E725;
    address internal constant AI = 0x68082B7EA5eE83cA3BD992f038ef02c0180b9Ba3;

    /// @dev Pons' MemeHook (afterSwap only, 1 % hook fee) on both Pons pools.
    address internal constant MEME_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    /// @dev LONG's Doppler hook on the AI/NVDA pool; the key's fee field carries v4's dynamic-fee flag.
    address internal constant DOPPLER_HOOK = 0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544;
    uint24 internal constant DYNAMIC_FEE_FLAG = 0x800000;

    /// @dev The pool ids the spec records, asserted against `key.toId()` so a mistyped key cannot pass silently.
    bytes32 internal constant MARIO_POOL_ID = 0xfad0b2c67dd7750f4f9392361ea1567db57b87ac015bfc519960089e73df2f15;
    bytes32 internal constant MICRODUCK_POOL_ID = 0xcde4d35e341901bc0308c2ffc789448ccd0f238a59597fe702e6710484b9c370;
    bytes32 internal constant AI_POOL_ID = 0x8b7f6b0cc404947b4c5d32b02353b82d432c98d61497a07f2a42f4ed5a3c19ee;

    // -------------------------------------------------------------------------------------------------------
    // Test fixture. Every account is a `vm.addr` key: no real wallet appears in this repository.
    // -------------------------------------------------------------------------------------------------------

    uint256 internal constant USER_KEY = 0x5F17;
    uint256 internal constant OWNER_KEY = 0x0E7E;
    uint256 internal constant FEE_WALLET_KEY = 0xFEE7;

    /// @dev The trade size for the two deep pools: one NVDA in, fee included.
    uint128 internal constant NVDA_IN = 1e18;
    /// @dev The AI/NVDA pool holds about 0.014 NVDA, so its buy trades dust: 0.001 NVDA.
    uint128 internal constant NVDA_DUST_IN = 1e15;
    /// @dev Sell sizes, small enough against 42 NVDA (MARIO) and 464 NVDA (microduck) of pool liquidity.
    uint128 internal constant MARIO_IN = 1_000_000e18;
    uint128 internal constant MICRODUCK_IN = 10_000e18;
    /// @dev Far more than the AI pool's whole NVDA side; used only for the trade that must revert.
    uint128 internal constant NVDA_OVERSIZE_IN = 1_000e18;

    /// @dev The deploy fee rate (spec section 5); 0.5 % of `amountIn`, rounded down.
    uint16 internal constant FEE_BPS = 50;
    /// @dev The slippage the app allows below the Quoter's number, in basis points: 1 %.
    uint256 internal constant SLIPPAGE_BPS = 100;

    address internal user;
    address internal owner;
    address internal feeWallet;

    SVRouter internal router;
    MockERC721 internal suitsNft;

    PoolKey internal marioKey;
    PoolKey internal microduckKey;
    PoolKey internal aiKey;

    /// @dev Permit2 nonces are unordered per owner; every signature this suite makes takes the next one.
    uint256 internal nextNonce;

    // -------------------------------------------------------------------------------------------------------
    // setUp
    // -------------------------------------------------------------------------------------------------------

    function setUp() public {
        string memory rpcUrl = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            // No network configured: the whole contract is skipped, not failed.
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpcUrl, vm.envOr("ROBINHOOD_FORK_BLOCK", FORK_BLOCK));
        assertEq(block.chainid, 4663, "forked the wrong chain");

        user = vm.addr(USER_KEY);
        owner = vm.addr(OWNER_KEY);
        feeWallet = vm.addr(FEE_WALLET_KEY);
        vm.label(user, "user");
        vm.label(owner, "owner");
        vm.label(feeWallet, "feeWallet");
        vm.label(UNIVERSAL_ROUTER, "UniversalRouter");
        vm.label(PERMIT2, "Permit2");
        vm.label(POOL_MANAGER, "PoolManager");
        vm.label(NVDA, "NVDA");
        vm.label(MARIO, "MARIO");
        vm.label(MICRODUCK, "microduck");
        vm.label(AI, "AI");

        // A mock ERC721 stands in for the Suits NFT, whose address is still TBD (spec section 2). Nobody holds
        // one until a test mints it, so every trade but the holder run pays the full 50 bps.
        suitsNft = new MockERC721();
        router = new SVRouter(owner, feeWallet, UNIVERSAL_ROUTER, PERMIT2, address(suitsNft));

        // The three pool keys of spec section 2, checked against the pool ids the spec records.
        marioKey = PoolKey({
            currency0: Currency.wrap(MARIO),
            currency1: Currency.wrap(NVDA),
            fee: 0,
            tickSpacing: 200,
            hooks: IHooks(MEME_HOOK)
        });
        microduckKey = PoolKey({
            currency0: Currency.wrap(NVDA),
            currency1: Currency.wrap(MICRODUCK),
            fee: 0,
            tickSpacing: 200,
            hooks: IHooks(MEME_HOOK)
        });
        aiKey = PoolKey({
            currency0: Currency.wrap(AI),
            currency1: Currency.wrap(NVDA),
            fee: DYNAMIC_FEE_FLAG,
            tickSpacing: 200,
            hooks: IHooks(DOPPLER_HOOK)
        });
        assertEq(PoolId.unwrap(marioKey.toId()), MARIO_POOL_ID, "MARIO/NVDA pool id");
        assertEq(PoolId.unwrap(microduckKey.toId()), MICRODUCK_POOL_ID, "microduck/NVDA pool id");
        assertEq(PoolId.unwrap(aiKey.toId()), AI_POOL_ID, "AI/NVDA pool id");

        // Funding. `deal` finds the balance slot of all three tokens the user pays with on this chain, so the
        // fallback the brief allows for - pranking the PoolManager, which holds every one of them - is not
        // needed. The assertions are the guard: if a token's storage layout ever defeats `deal`, this fails
        // loudly in setUp instead of as a confusing "transfer amount exceeds balance" inside a trade. That
        // these transfers work at all is also the first answer to spec section 7's open question about the
        // Robinhood stock tokens: NVDA moves between arbitrary addresses with no allowlist in the way.
        deal(NVDA, user, 2 * uint256(NVDA_OVERSIZE_IN));
        deal(MARIO, user, 2 * uint256(MARIO_IN));
        deal(MICRODUCK, user, 2 * uint256(MICRODUCK_IN));
        assertEq(IERC20(NVDA).balanceOf(user), 2 * uint256(NVDA_OVERSIZE_IN), "deal did not fund NVDA");
        assertEq(IERC20(MARIO).balanceOf(user), 2 * uint256(MARIO_IN), "deal did not fund MARIO");
        assertEq(IERC20(MICRODUCK).balanceOf(user), 2 * uint256(MICRODUCK_IN), "deal did not fund microduck");
        assertEq(IERC20(AI).balanceOf(user), 0, "the user's AI comes from the pool, not from deal");

        // One approval per token the user ever pays with; Permit2 does the per-trade authorisation from there.
        vm.startPrank(user);
        IERC20(NVDA).approve(PERMIT2, type(uint256).max);
        IERC20(MARIO).approve(PERMIT2, type(uint256).max);
        IERC20(MICRODUCK).approve(PERMIT2, type(uint256).max);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------------------------------------
    // The three pools, both directions
    // -------------------------------------------------------------------------------------------------------

    /// @notice Pons, MARIO/NVDA: buy MARIO with NVDA. NVDA is currency1, so this is the one-for-zero direction.
    function test_mario_buy_with_nvda() public {
        Trade memory t = _tradeAndAssert("MARIO buy ", marioKey, false, NVDA_IN, false);
        assertEq(t.tokenIn, NVDA, "paid NVDA");
        assertEq(t.tokenOut, MARIO, "received MARIO");
        assertGt(t.amountOut, 0, "the pool paid something");
    }

    /// @notice Pons, MARIO/NVDA: sell MARIO for NVDA. The fee arrives in MARIO, the token being sold, which is
    ///         what the README's Fees table says happens on the sell side (spec section 4, last line).
    function test_mario_sell_for_nvda() public {
        Trade memory t = _tradeAndAssert("MARIO sell", marioKey, true, MARIO_IN, false);
        assertEq(t.tokenIn, MARIO, "paid MARIO");
        assertEq(t.tokenOut, NVDA, "received NVDA");
        assertEq(IERC20(MARIO).balanceOf(feeWallet), t.fee, "the sell-side fee is in MARIO, not NVDA");
        assertEq(IERC20(NVDA).balanceOf(feeWallet), 0, "no NVDA reached the fee wallet");
    }

    /// @notice Pons, microduck/NVDA: the same pair the other way round in the key - NVDA is currency0 here - so
    ///         buying microduck is the zero-for-one direction. This is the case that would catch a router that
    ///         assumed "buy" always means one direction.
    function test_microduck_buy_with_nvda_reversed_currency_order() public {
        assertEq(Currency.unwrap(microduckKey.currency0), NVDA, "NVDA is currency0 in this pool");
        Trade memory t = _tradeAndAssert("duck buy  ", microduckKey, true, NVDA_IN, false);
        assertEq(t.tokenIn, NVDA, "paid NVDA");
        assertEq(t.tokenOut, MICRODUCK, "received microduck");
    }

    /// @notice Pons, microduck/NVDA: sell microduck for NVDA, the one-for-zero direction in this pool.
    function test_microduck_sell_for_nvda_reversed_currency_order() public {
        Trade memory t = _tradeAndAssert("duck sell ", microduckKey, false, MICRODUCK_IN, false);
        assertEq(t.tokenIn, MICRODUCK, "paid microduck");
        assertEq(t.tokenOut, NVDA, "received NVDA");
    }

    /// @notice LONG, AI/NVDA: a dust buy. The pool's whole NVDA side is about 0.014 NVDA, so 0.001 NVDA is the
    ///         largest trade that is not mostly price impact; it also exercises a Doppler hook and a key whose
    ///         fee field is v4's dynamic-fee flag rather than a fixed fee.
    function test_ai_buy_with_dust_nvda() public {
        Trade memory t = _tradeAndAssert("AI buy    ", aiKey, false, NVDA_DUST_IN, false);
        assertEq(t.tokenIn, NVDA, "paid NVDA");
        assertEq(t.tokenOut, AI, "received AI");
        // 0.001 NVDA at 50 bps rounds to 5e12 wei, well above zero: the dust case still pays a fee.
        assertEq(t.fee, 5e12, "fee on the dust trade");
    }

    // -------------------------------------------------------------------------------------------------------
    // The Suits NFT perk
    // -------------------------------------------------------------------------------------------------------

    /// @notice A Suits NFT holder pays nothing at the deploy rates (`holderFeeBps` = 0), and the fee wallet sees
    ///         no transfer at all - the router skips a zero-value transfer on purpose (spec section 6a).
    function test_holder_pays_no_fee() public {
        suitsNft.mint(user, 1);
        assertEq(suitsNft.balanceOf(user), 1, "the user holds a Suits NFT");

        // What the same trade would have paid at the full 50 bps, read before the trade moves the price.
        uint256 nonHolderQuote = _quote(marioKey, false, NVDA_IN - NVDA_IN * FEE_BPS / 10_000);

        Trade memory t = _tradeAndAssert("MARIO hold", marioKey, false, NVDA_IN, true);
        assertEq(t.fee, 0, "the holder rate is 0 bps at deploy");
        assertEq(IERC20(NVDA).balanceOf(feeWallet), 0, "nothing reached the fee wallet");
        // The perk reaches the pool, not just the bookkeeping: the whole input was swapped, so the holder's
        // output is strictly better than the same trade at the regular rate.
        assertGt(t.amountOut, nonHolderQuote, "the holder's whole input reached the pool");
    }

    // -------------------------------------------------------------------------------------------------------
    // Reverts on the real router
    // -------------------------------------------------------------------------------------------------------

    /// @notice An impossible minimum is refused by the deployed Universal Router itself, with v4-periphery's
    ///         `V4TooLittleReceived`, before the router's own `InsufficientOutput` could ever be reached. The
    ///         whole call rolls back: the user keeps their NVDA, the fee wallet gets nothing, and nothing is
    ///         left in either router.
    function test_impossible_amount_out_min_reverts_at_the_universal_router() public {
        uint256 userBefore = IERC20(NVDA).balanceOf(user);
        uint256 urBefore = IERC20(NVDA).balanceOf(UNIVERSAL_ROUTER);

        (ISVRouter.SwapParams memory p, ISignatureTransfer.PermitTransferFrom memory permit, bytes memory signature) =
            _sign(marioKey, false, NVDA_IN, type(uint128).max);

        // The second field is what the pool would have paid, which is chain state; only the bound is asserted.
        vm.expectPartialRevert(IV4Router.V4TooLittleReceived.selector);
        vm.prank(user);
        router.swapExactIn(p, permit, signature);

        assertEq(IERC20(NVDA).balanceOf(user), userBefore, "the user's NVDA is untouched");
        assertEq(IERC20(NVDA).balanceOf(feeWallet), 0, "no fee was kept");
        assertEq(IERC20(NVDA).balanceOf(UNIVERSAL_ROUTER), urBefore, "nothing left in the Universal Router");
        _assertRouterHoldsNothing(NVDA, MARIO);
    }

    /// @notice Permit2 refuses a nonce the user has already spent: the same signature cannot be replayed, and a
    ///         second trade signed with the same nonce is dead on arrival. Permit2's own `InvalidNonce()`.
    function test_reusing_a_permit2_nonce_reverts() public {
        uint256 nonce = nextNonce;

        (ISVRouter.SwapParams memory p, ISignatureTransfer.PermitTransferFrom memory permit, bytes memory signature) =
            _sign(marioKey, false, NVDA_IN, 0);
        vm.prank(user);
        router.swapExactIn(p, permit, signature);

        // Sign a fresh, otherwise valid trade that reuses the spent nonce. Signing reads Permit2's domain
        // separator, an external call: it has to happen before the prank, or the prank would be spent on it.
        nextNonce = nonce;
        (
            ISVRouter.SwapParams memory p2,
            ISignatureTransfer.PermitTransferFrom memory permit2,
            bytes memory signature2
        ) = _sign(marioKey, false, NVDA_IN, 0);

        vm.expectRevert(InvalidNonce.selector);
        vm.prank(user);
        router.swapExactIn(p2, permit2, signature2);
    }

    /// @notice A buy far larger than the AI/NVDA pool can serve, priced at the quote the app would have shown
    ///         for a dust trade, is refused by the Universal Router's own minimum and rolls back whole: the
    ///         Universal Router's NVDA balance is what it was, and so is everything else.
    ///
    /// @dev The spec (section 4) settles the *exact* net amount rather than the open delta precisely so that a
    ///      swap which outgrew a pool could not leave the remainder inside the Universal Router. Two findings
    ///      from this chain, recorded here because they bound what this test can claim:
    ///      1. On all three pools, in both directions, the deployed v4 consumes the *whole* exact input at any
    ///         size up to `type(int128).max` - the price never reaches `MIN_SQRT_PRICE`/`MAX_SQRT_PRICE`, so no
    ///         partial fill, and therefore no `CurrencyNotSettled`, can be produced by size alone. The exact-net
    ///         settle is still the right encoding; this chain simply never exercises its failure branch.
    ///      2. What a user who outgrows a pool actually meets is this: the pool consumes all the input and pays
    ///         out a small fraction of the quoted price (here about 4 % of it), so the slippage bound fires.
    ///      Either way the property the spec cares about holds and is what is asserted: the call reverts and
    ///      nothing is stranded in the Universal Router, where anyone could sweep it.
    function test_a_buy_that_outgrows_the_ai_pool_reverts_and_strands_nothing() public {
        // The price the app would quote from a dust trade, extrapolated to the size the user asks for.
        uint256 dustQuote = _quote(aiKey, false, NVDA_DUST_IN);
        (uint256 fee,) = router.feeFor(user, NVDA_OVERSIZE_IN);
        // The cast cannot truncate: the fee is at most 0.5 % of a uint128 amount.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 net = NVDA_OVERSIZE_IN - uint128(fee);
        uint256 quotedAtDustPrice = dustQuote * net / NVDA_DUST_IN;

        // What the pool would really pay for that size, for the record: far below the bound.
        uint256 realQuote = _quote(aiKey, false, net);
        assertLt(realQuote * 10, quotedAtDustPrice, "the oversized trade is worth less than a tenth of its price");
        console2.log("AI oversize: quoted at dust price", quotedAtDustPrice);
        console2.log("AI oversize: the pool would pay  ", realQuote);

        uint256 userBefore = IERC20(NVDA).balanceOf(user);
        uint256 urNvdaBefore = IERC20(NVDA).balanceOf(UNIVERSAL_ROUTER);
        uint256 urAiBefore = IERC20(AI).balanceOf(UNIVERSAL_ROUTER);

        (ISVRouter.SwapParams memory p, ISignatureTransfer.PermitTransferFrom memory permit, bytes memory signature) =
            _sign(aiKey, false, NVDA_OVERSIZE_IN, uint128(_withSlippage(quotedAtDustPrice)));
        vm.expectPartialRevert(IV4Router.V4TooLittleReceived.selector);
        vm.prank(user);
        router.swapExactIn(p, permit, signature);

        assertEq(IERC20(NVDA).balanceOf(UNIVERSAL_ROUTER), urNvdaBefore, "the Universal Router's NVDA is unchanged");
        assertEq(IERC20(AI).balanceOf(UNIVERSAL_ROUTER), urAiBefore, "the Universal Router's AI is unchanged");
        assertEq(IERC20(NVDA).balanceOf(user), userBefore, "the user's NVDA is untouched");
        assertEq(IERC20(NVDA).balanceOf(feeWallet), 0, "no fee was kept");
        _assertRouterHoldsNothing(NVDA, AI);
    }

    // -------------------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------------------

    /// @dev Permit2's own error for a nonce that has already been spent, from `permit2/src/PermitErrors.sol`.
    ///      Redeclared rather than imported because that file pins `pragma solidity 0.8.17` while this suite
    ///      compiles at 0.8.26; the name and argument list are identical, so the selector is Permit2's.
    error InvalidNonce();

    struct Trade {
        address tokenIn;
        address tokenOut;
        uint256 fee;
        uint256 quote;
        uint256 amountOut;
    }

    /// @dev Balances of everyone who could be left holding something, read before a trade.
    struct Balances {
        uint256 feeWallet;
        uint256 userIn;
        uint256 userOut;
        uint256 routerIn;
        uint256 routerOut;
        uint256 universalRouterIn;
        uint256 universalRouterOut;
    }

    /// @dev One trade through the real stack, with every assertion the spec's section 6 asks for:
    ///      - the fee, at the rate `feeFor` reports, arrived in the fee wallet in the *input* token;
    ///      - the user paid exactly `amountIn` and received `amountOut` of the output token;
    ///      - `amountOut` is at least the V4 Quoter's number for the net amount less 1 % slippage, the bound the
    ///        app would have set, and in fact equals the quote to the wei (the quote is taken from this same
    ///        fork at this same state, so any difference would mean the Universal Router's path and the
    ///        Quoter's disagree - which is exactly what this suite exists to catch);
    ///      - the `Trade` event carries those values and the right pool id, tokens and holder flag;
    ///      - neither this router nor the Universal Router holds either token afterwards.
    ///      Split across three small frames because this file compiles without via-IR, like `src/`.
    function _tradeAndAssert(
        string memory label,
        PoolKey memory key,
        bool zeroForOne,
        uint128 amountIn,
        bool expectHolderRate
    ) internal returns (Trade memory t) {
        t.tokenIn = Currency.unwrap(zeroForOne ? key.currency0 : key.currency1);
        t.tokenOut = Currency.unwrap(zeroForOne ? key.currency1 : key.currency0);

        bool holderRate;
        (t.fee, holderRate) = router.feeFor(user, amountIn);
        assertEq(holderRate, expectHolderRate, "holder rate");
        assertEq(t.fee, expectHolderRate ? 0 : uint256(amountIn) * FEE_BPS / 10_000, "fee at the deploy rate");

        // The app's quote for exactly what the router will swap: the net amount, not the gross.
        t.quote = _quote(key, zeroForOne, amountIn - uint128(t.fee));
        assertGt(t.quote, 0, "the pool quoted nothing");

        Balances memory before = _balances(t.tokenIn, t.tokenOut);
        t.amountOut = _execute(key, zeroForOne, amountIn, uint128(_withSlippage(t.quote)));
        console2.log(string.concat(label, ": in / fee / out"), uint256(amountIn), t.fee, t.amountOut);

        _assertBalancesMoved(t, before, amountIn);
        _assertTradeEvent(key, t, amountIn, expectHolderRate);
    }

    /// @dev Signs and sends one trade as the user, recording the logs the event assertions read.
    function _execute(PoolKey memory key, bool zeroForOne, uint128 amountIn, uint128 amountOutMin)
        internal
        returns (uint256 amountOut)
    {
        // Signed before the prank on purpose: signing reads Permit2's `DOMAIN_SEPARATOR()`, an external call,
        // which would otherwise consume the pending prank.
        (ISVRouter.SwapParams memory p, ISignatureTransfer.PermitTransferFrom memory permit, bytes memory signature) =
            _sign(key, zeroForOne, amountIn, amountOutMin);

        vm.recordLogs();
        vm.prank(user);
        amountOut = router.swapExactIn(p, permit, signature);
    }

    /// @dev Where every token went: the fee to the fee wallet, the output to the user, nothing anywhere else.
    function _assertBalancesMoved(Trade memory t, Balances memory before, uint128 amountIn) internal view {
        Balances memory a = _balances(t.tokenIn, t.tokenOut);

        assertEq(a.feeWallet - before.feeWallet, t.fee, "fee in the fee wallet");
        assertEq(before.userIn - a.userIn, amountIn, "the user paid exactly amountIn");
        assertEq(a.userOut - before.userOut, t.amountOut, "the output arrived at the user");
        assertGe(t.amountOut, _withSlippage(t.quote), "output at or above the quote less 1 % slippage");
        assertEq(t.amountOut, t.quote, "the Universal Router's path pays exactly what the Quoter quoted");

        // Nothing stranded anywhere: the router holds neither token (it never does, spec section 4.7), and the
        // Universal Router's balances are what they were, which is what settling the exact net amount buys.
        assertEq(a.routerIn, 0, "router holds no tokenIn");
        assertEq(a.routerOut, 0, "router holds no tokenOut");
        assertEq(a.universalRouterIn, before.universalRouterIn, "Universal Router: tokenIn unchanged");
        assertEq(a.universalRouterOut, before.universalRouterOut, "Universal Router: tokenOut unchanged");
    }

    function _balances(address tokenIn, address tokenOut) internal view returns (Balances memory b) {
        b.feeWallet = IERC20(tokenIn).balanceOf(feeWallet);
        b.userIn = IERC20(tokenIn).balanceOf(user);
        b.userOut = IERC20(tokenOut).balanceOf(user);
        b.routerIn = IERC20(tokenIn).balanceOf(address(router));
        b.routerOut = IERC20(tokenOut).balanceOf(address(router));
        b.universalRouterIn = IERC20(tokenIn).balanceOf(UNIVERSAL_ROUTER);
        b.universalRouterOut = IERC20(tokenOut).balanceOf(UNIVERSAL_ROUTER);
    }

    /// @dev Exactly one `Trade` from the router, with the eight values the indexer reads.
    function _assertTradeEvent(PoolKey memory key, Trade memory t, uint128 amountIn, bool expectHolderRate) internal {
        bytes32 topic0 = keccak256("Trade(address,bytes32,address,address,uint256,uint256,uint256,bool)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(router) || logs[i].topics[0] != topic0) continue;
            found++;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), user, "Trade.user");
            assertEq(logs[i].topics[2], PoolId.unwrap(key.toId()), "Trade.poolId");
            assertEq(address(uint160(uint256(logs[i].topics[3]))), t.tokenIn, "Trade.tokenIn");
            (address tokenOut, uint256 loggedIn, uint256 loggedFee, uint256 loggedOut, bool loggedHolder) =
                abi.decode(logs[i].data, (address, uint256, uint256, uint256, bool));
            assertEq(tokenOut, t.tokenOut, "Trade.tokenOut");
            assertEq(loggedIn, amountIn, "Trade.amountIn");
            assertEq(loggedFee, t.fee, "Trade.fee");
            assertEq(loggedOut, t.amountOut, "Trade.amountOut");
            assertEq(loggedHolder, expectHolderRate, "Trade.holderRate");
        }
        assertEq(found, 1, "exactly one Trade event");
    }

    /// @dev The router holds neither side of the trade afterwards; it never does, by design (spec section 4.7).
    function _assertRouterHoldsNothing(address tokenIn, address tokenOut) internal view {
        assertEq(IERC20(tokenIn).balanceOf(address(router)), 0, "router holds no tokenIn");
        assertEq(IERC20(tokenOut).balanceOf(address(router)), 0, "router holds no tokenOut");
    }

    /// @dev The V4 Quoter on this chain returns the quote (it does not revert with it): this is v4-periphery's
    ///      `V4Quoter`, which catches its own internal `QuoteSwap` revert and returns the amount. The call is
    ///      not a view - it unlocks the PoolManager and reverts inside - but it leaves no state behind, so the
    ///      swap that follows sees exactly the state the quote was taken at.
    function _quote(PoolKey memory key, bool zeroForOne, uint128 exactAmount) internal returns (uint256 amountOut) {
        (amountOut,) = QUOTER.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key, zeroForOne: zeroForOne, exactAmount: exactAmount, hookData: ""
            })
        );
    }

    /// @dev A quote less the 1 % slippage the app allows: the `amountOutMin` a real trade would carry.
    function _withSlippage(uint256 quote) internal pure returns (uint256) {
        return quote * (10_000 - SLIPPAGE_BPS) / 10_000;
    }

    /// @dev One signed trade for `user`: the router's params, the Permit2 message for the input token at the
    ///      next unspent nonce, and the user's EIP-712 signature over it with this router as the spender.
    function _sign(PoolKey memory key, bool zeroForOne, uint128 amountIn, uint128 amountOutMin)
        internal
        returns (
            ISVRouter.SwapParams memory p,
            ISignatureTransfer.PermitTransferFrom memory permit,
            bytes memory signature
        )
    {
        address tokenIn = Currency.unwrap(zeroForOne ? key.currency0 : key.currency1);
        p = ISVRouter.SwapParams({
            key: key,
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            hookData: "",
            deadline: block.timestamp + 1 hours
        });
        permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: tokenIn, amount: amountIn}),
            nonce: nextNonce++,
            deadline: block.timestamp + 1 hours
        });
        signature = Permit2Signer.sign(USER_KEY, PERMIT2, permit, address(router));
    }
}
