// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SVLaunchpad} from "../../src/SVLaunchpad.sol";
import {SVLaunchToken} from "../../src/SVLaunchToken.sol";
import {ISVLaunchpad} from "../../src/interfaces/ISVLaunchpad.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC721} from "../mocks/MockERC721.sol";
import {MockERC721ShortReply} from "../mocks/MockERC721ShortReply.sol";
import {MockGasBurningGate} from "../mocks/MockGasBurningGate.sol";
import {MockRevertingGate} from "../mocks/MockRevertingGate.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {MockQuirkyERC20} from "../mocks/MockQuirkyERC20.sol";
import {Permit2Signer} from "../utils/Permit2Signer.sol";

/// @notice Shared fixture for the launchpad unit suites: a local PoolManager and v4-core's swap test router, the
///         real Permit2 etched at its canonical address, two mock quotes at 6 and 18 decimals allowed at the
///         DEFAULT USD 5,000 to 10,000,000 bounds (the 18-decimal one priced at USD 100), a mock Suits NFT as the
///         launcher gate with the creator holding one, and an SVLaunchpad at the spec's initial settings.
/// @dev Every account is a `vm.addr` key or a `makeAddr` label; no real wallet or key appears. The clock starts at
///      a fixed timestamp so the tests read the same everywhere.
abstract contract SVLaunchpadTestBase is Test {
    using StateLibrary for IPoolManager;

    uint256 internal constant CREATOR_KEY = 0xC4EA;
    uint256 internal constant STRANGER_KEY = 0xB0BB1E;
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    uint256 internal constant MIN_VALUATION = 1e8;
    uint256 internal constant MAX_VALUATION = 1e36;
    uint256 internal constant USDG_MIN = 5_000e6;
    uint256 internal constant USDG_MAX = 10_000_000e6;
    uint256 internal constant STK_MIN = 50e18;
    uint256 internal constant STK_MAX = 100_000e18;
    uint256 internal constant MINT = 1e30;
    uint256 internal constant NOW = 1_790_000_000;
    int24 internal constant MIN_USABLE_TICK = -887_200;
    int24 internal constant MAX_USABLE_TICK = 887_200;

    IPoolManager internal manager;
    PoolSwapTest internal swapRouter;
    address internal permit2;
    MockERC20 internal usdg;
    MockERC20 internal stk;
    MockERC721 internal gate;
    SVLaunchpad internal launchpad;
    address internal creator;
    address internal stranger;
    address internal owner;
    address internal feeWallet;
    /// @dev Permit2 nonces are unordered per owner; every signature the suites make takes the next one.
    uint256 internal nextNonce;
    bytes4 internal constant PERMIT_PULL =
        bytes4(keccak256("permitTransferFrom(((address,uint256),uint256,uint256),(address,uint256),address,bytes)"));
    string internal constant NAME = "Launch Token";
    string internal constant SYMBOL = "LT";
    string internal constant URI = "ipfs://bafkreigh2akiscaildcqabsyg3dfr6chu3fgpregiymsck7e7aqa4s52zy";

    /// @dev Where the next salt search starts, so every launch in a test gets a fresh salt.
    uint256 internal saltCursor;

    /// @dev What a launch at a valuation must produce, computed here with the libraries the pool itself uses.
    struct Expected {
        int24 openTick;
        uint160 sqrtPriceX96;
        uint256 snapped;
        uint128 liquidity;
        uint256 owed;
    }

    function setUp() public virtual {
        vm.warp(NOW);
        creator = vm.addr(CREATOR_KEY);
        stranger = vm.addr(STRANGER_KEY);
        owner = makeAddr("owner");
        feeWallet = makeAddr("feeWallet");
        vm.label(creator, "creator");
        vm.label(stranger, "stranger");
        manager = IPoolManager(address(new PoolManager(address(this))));
        swapRouter = new PoolSwapTest(manager);
        // The real Permit2, etched at its canonical address from the bytecode shipped in its repository.
        permit2 = new DeployPermit2().deployPermit2();
        usdg = new MockERC20("USD Global", "USDG", 6);
        stk = new MockERC20("Stock", "STK", 18);
        gate = new MockERC721();
        gate.mint(creator, 1);
        launchpad = new SVLaunchpad(manager, ISignatureTransfer(permit2), owner, feeWallet, address(gate));
        vm.startPrank(owner);
        launchpad.setCurrency(address(usdg), USDG_MIN, USDG_MAX, 0);
        launchpad.setCurrency(address(stk), STK_MIN, STK_MAX, 0);
        vm.stopPrank();
        _fund(creator, address(usdg));
        _fund(creator, address(stk));
        _fund(stranger, address(usdg));
        _fund(stranger, address(stk));
    }

    // -------------------------------------------------------------------------------------------------------
    // Fixture helpers
    // -------------------------------------------------------------------------------------------------------

    /// @dev Mints `MINT` of a mock quote to `wallet` and approves Permit2 for it, the app's one-time approval.
    function _fund(address wallet, address token) internal {
        MockERC20(token).mint(wallet, MINT);
        vm.prank(wallet);
        MockERC20(token).approve(permit2, type(uint256).max);
    }

    /// @dev An address whose low 14 bits are exactly `flags`, with one byte of code: what mining a hook address
    ///      produces, without the mining.
    function _hookAt(uint160 flags) internal returns (address hookAddress) {
        hookAddress = address((uint160(uint256(keccak256(abi.encode("hook", flags)))) & ~Hooks.ALL_HOOK_MASK) | flags);
        vm.etch(hookAddress, hex"00");
    }

    // -------------------------------------------------------------------------------------------------------
    // Launch helpers
    // -------------------------------------------------------------------------------------------------------

    /// @dev Searches salts until the token `who` would deploy sits on the wanted side of `quote`, so every
    ///      behaviour runs in both currency orders against the real CREATE2 address. Each salt is a fair coin.
    function _saltFor(address who, address quote, bool tokenFirst) internal returns (bytes32 salt) {
        for (uint256 i = 0; i < 512; i++) {
            salt = bytes32(saltCursor++);
            if ((launchpad.predictToken(who, salt, NAME, SYMBOL) < quote) == tokenFirst) return salt;
        }
        revert("no salt within 512 tries puts the token on the wanted side of the quote");
    }

    /// @dev A valid free launch by `who`: no first buy, no minimum, payout zero (the caller), an hour to go.
    function _params(address who, address quote, uint256 valuation, bool tokenFirst)
        internal
        returns (ISVLaunchpad.LaunchParams memory p)
    {
        p.name = NAME;
        p.symbol = SYMBOL;
        p.metadataUri = URI;
        p.quote = quote;
        p.valuation = valuation;
        p.salt = _saltFor(who, quote, tokenFirst);
        p.deadline = block.timestamp + 1 hours;
    }

    /// @dev A Permit2 message for `amount` of `token` with the launchpad as spender, signed by `key`, or an empty
    ///      message and signature for a zero amount, which is what the app sends for a free launch. Signed before
    ///      any prank: reading Permit2's `DOMAIN_SEPARATOR()` is an external call and would consume it.
    function _permit(uint256 key, address token, uint256 amount)
        internal
        returns (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory signature)
    {
        if (amount == 0) return (permit, signature);
        permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: token, amount: amount}),
            nonce: nextNonce++,
            deadline: block.timestamp + 1 hours
        });
        signature = Permit2Signer.sign(key, permit2, permit, address(launchpad));
    }

    function _emptyPermit() internal pure returns (ISignatureTransfer.PermitTransferFrom memory permit) {
        return permit;
    }

    /// @dev One launch by the holder of `key`, paying `firstBuy + creationFee` through Permit2 when above zero.
    function _launch(uint256 key, ISVLaunchpad.LaunchParams memory p) internal returns (address token) {
        uint256 total = p.firstBuy + launchpad.currency(p.quote).creationFee;
        (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory signature) = _permit(key, p.quote, total);
        address who = vm.addr(key);
        vm.prank(who);
        token = launchpad.launch(p, permit, signature);
    }

    function _launchFree(address quote, uint256 valuation, bool tokenFirst) internal returns (address token) {
        return _launch(CREATOR_KEY, _params(creator, quote, valuation, tokenFirst));
    }

    function _launchWithBuy(address quote, uint256 valuation, bool tokenFirst, uint256 firstBuy)
        internal
        returns (address token)
    {
        ISVLaunchpad.LaunchParams memory p = _params(creator, quote, valuation, tokenFirst);
        p.firstBuy = firstBuy;
        return _launch(CREATOR_KEY, p);
    }

    /// @dev The launch must revert with exactly `revertData`; the permit is signed first, outside the prank.
    function _expectLaunchRevert(uint256 key, ISVLaunchpad.LaunchParams memory p, bytes memory revertData) internal {
        uint256 total = p.firstBuy + launchpad.currency(p.quote).creationFee;
        (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory signature) = _permit(key, p.quote, total);
        address who = vm.addr(key);
        vm.prank(who);
        vm.expectRevert(revertData);
        launchpad.launch(p, permit, signature);
    }

    /// @dev What the first buy of `p` gives the creator, measured in a launch that is then undone, with the cap
    ///      lifted and the minimum cleared for the measurement only.
    function _dryRunTokensOut(ISVLaunchpad.LaunchParams memory p) internal returns (uint256 tokensOut) {
        uint256 snapshot = vm.snapshotState();
        uint256 minimum = p.minFirstBuyTokens;
        p.minFirstBuyTokens = 0;
        vm.prank(owner);
        launchpad.setFirstBuyCap(10_000);
        vm.recordLogs();
        _launch(CREATOR_KEY, p);
        (, ISVLaunchpad.LaunchedData memory d) = _launchedFrom(vm.getRecordedLogs());
        tokensOut = d.firstBuyTokens;
        p.minFirstBuyTokens = minimum;
        vm.revertToState(snapshot);
    }

    /// @dev A 6-decimal quirky quote allowed at the USDG bounds with `creationFee`, the creator funded in it.
    function _quirkyQuote(uint256 creationFee) internal returns (MockQuirkyERC20 q) {
        q = new MockQuirkyERC20("Quirky USD", "QUSD", 6);
        vm.prank(owner);
        launchpad.setCurrency(address(q), USDG_MIN, USDG_MAX, creationFee);
        _fund(creator, address(q));
    }

    /// @dev Spec sections 3.2 and 3.3 recomputed: the opening, `L` from `LiquidityAmounts`, and the amount the
    ///      pool charges for `L`, rounded up as `Pool.modifyLiquidity` does.
    function _expected(address token, address quote, uint256 valuation) internal view returns (Expected memory e) {
        (e.openTick, e.sqrtPriceX96, e.snapped) = launchpad.openingFor(token, quote, valuation);
        if (token < quote) {
            uint160 top = TickMath.getSqrtPriceAtTick(MAX_USABLE_TICK);
            e.liquidity = LiquidityAmounts.getLiquidityForAmount0(e.sqrtPriceX96, top, SUPPLY);
            e.owed = SqrtPriceMath.getAmount0Delta(e.sqrtPriceX96, top, e.liquidity, true);
        } else {
            uint160 bottom = TickMath.getSqrtPriceAtTick(MIN_USABLE_TICK);
            e.liquidity = LiquidityAmounts.getLiquidityForAmount1(bottom, e.sqrtPriceX96, SUPPLY);
            e.owed = SqrtPriceMath.getAmount1Delta(bottom, e.sqrtPriceX96, e.liquidity, true);
        }
    }

    /// @dev Spec section 3.3: the token amount one unit of liquidity is worth at the opening price, plus two.
    function _dustBound(address token, address quote, uint160 sqrtOpen) internal pure returns (uint256) {
        return token < quote
            ? FullMath.mulDivRoundingUp(1, 1 << 96, sqrtOpen) + 2
            : FullMath.mulDivRoundingUp(sqrtOpen, 1, 1 << 96) + 2;
    }

    function _keyFor(address token, address quote, address hookAddress) internal pure returns (PoolKey memory) {
        (address c0, address c1) = token < quote ? (token, quote) : (quote, token);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 10_000,
            tickSpacing: 200,
            hooks: IHooks(hookAddress)
        });
    }

    function _range(address token) internal view returns (int24 tickLower, int24 tickUpper) {
        ISVLaunchpad.Launch memory l = launchpad.getLaunch(token);
        return l.tokenIsCurrency0 ? (l.openTick, MAX_USABLE_TICK) : (MIN_USABLE_TICK, l.openTick);
    }

    function _positionLiquidity(address token) internal view returns (uint128 liquidity) {
        (int24 tickLower, int24 tickUpper) = _range(token);
        (liquidity,,) = manager.getPositionInfo(
            launchpad.poolKeyOf(token).toId(), address(launchpad), tickLower, tickUpper, bytes32(0)
        );
    }

    function _activeLiquidity(address token) internal view returns (uint128) {
        return manager.getLiquidity(launchpad.poolKeyOf(token).toId());
    }

    function _slot0(address token) internal view returns (uint160 sqrtPriceX96, int24 tick) {
        (sqrtPriceX96, tick,,) = manager.getSlot0(launchpad.poolKeyOf(token).toId());
    }

    /// @dev The first `Launched` event among `logs`.
    function _launchedFrom(Vm.Log[] memory logs)
        internal
        view
        returns (address token, ISVLaunchpad.LaunchedData memory d)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(launchpad) || logs[i].topics[0] != ISVLaunchpad.Launched.selector) continue;
            token = address(uint160(uint256(logs[i].topics[1])));
            d = abi.decode(logs[i].data, (ISVLaunchpad.LaunchedData));
            return (token, d);
        }
        revert("no Launched event in the recorded logs");
    }

    /// @dev How many ERC20 `Transfer` events of `token` among `logs` went to `to`.
    function _transfersTo(Vm.Log[] memory logs, address token, address to) internal pure returns (uint256 count) {
        bytes32 transferTopic = keccak256("Transfer(address,address,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != token || logs[i].topics.length != 3 || logs[i].topics[0] != transferTopic) continue;
            if (address(uint160(uint256(logs[i].topics[2]))) == to) count++;
        }
    }

    /// @dev Permit2 is never asked to pull for the rest of the test.
    function _expectNoPermitPull() internal {
        vm.expectCall(permit2, abi.encodePacked(PERMIT_PULL), 0);
    }

    /// @dev Permit2 is asked to pull exactly once for the rest of the test.
    function _expectOnePermitPull() internal {
        vm.expectCall(permit2, abi.encodePacked(PERMIT_PULL), 1);
    }

    /// @dev One exact-input trade through v4-core's PoolSwapTest, paid by this test contract: a buy spends
    ///      `amountIn` of the quote, a sell `amountIn` of the token. The price limit is the far end, so the whole
    ///      input is used wherever there is liquidity. Returns what this contract received.
    function _swap(address token, bool buy, uint256 amountIn) internal returns (uint256 amountOut) {
        ISVLaunchpad.Launch memory l = launchpad.getLaunch(token);
        address tokenIn = buy ? l.quote : token;
        address tokenOut = buy ? token : l.quote;
        bool zeroForOne = buy ? !l.tokenIsCurrency0 : l.tokenIsCurrency0;
        IERC20(tokenIn).approve(address(swapRouter), amountIn);
        uint256 before = IERC20(tokenOut).balanceOf(address(this));
        swapRouter.swap(
            launchpad.poolKeyOf(token),
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                // Test amounts are far below 2^255.
                // forge-lint: disable-next-line(unsafe-typecast)
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - before;
    }

    /// @dev The first `FeesCollected` event among `logs`.
    function _feesCollectedFrom(Vm.Log[] memory logs)
        internal
        view
        returns (uint256 tokenFees, uint256 quoteFees, uint256 tokenToPayout, uint256 quoteToPayout)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(launchpad) || logs[i].topics[0] != ISVLaunchpad.FeesCollected.selector) {
                continue;
            }
            return abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
        }
        revert("no FeesCollected event in the recorded logs");
    }
}

/// @notice The constructor, the owner settings with every bound of spec section 4.3, ownership, the launcher gate
///         of section 4.7, the hook rule of section 4.9, and the pure opening maths of section 3.2.
contract SVLaunchpadSettingsTest is SVLaunchpadTestBase {
    /// @dev Two addresses in a known order for the pure opening maths: LOW is below HIGH.
    address internal constant LOW = address(0x1000);
    address internal constant HIGH = address(0x2000);

    // -------------------------------------------------------------------------------------------------------
    // Constructor (spec section 4.3)
    // -------------------------------------------------------------------------------------------------------

    function test_constructor_stores_the_initial_settings_and_emits_every_setting_event() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectEmit(true, true, true, true, predicted);
        emit ISVLaunchpad.FeeWalletChanged(feeWallet);
        vm.expectEmit(true, true, true, true, predicted);
        emit ISVLaunchpad.RouterFeeChanged(50);
        vm.expectEmit(true, true, true, true, predicted);
        emit ISVLaunchpad.CreatorShareChanged(7_000);
        vm.expectEmit(true, true, true, true, predicted);
        emit ISVLaunchpad.FirstBuyCapChanged(2_000);
        vm.expectEmit(true, true, true, true, predicted);
        emit ISVLaunchpad.DailyLaunchLimitChanged(5);
        vm.expectEmit(true, true, true, true, predicted);
        emit ISVLaunchpad.LauncherGateChanged(address(gate));
        vm.expectEmit(true, true, true, true, predicted);
        emit ISVLaunchpad.HookChanged(address(0));
        SVLaunchpad fresh = new SVLaunchpad(manager, ISignatureTransfer(permit2), owner, feeWallet, address(gate));
        assertEq(address(fresh), predicted, "deployed where the events were expected");
        assertEq(address(fresh.POOL_MANAGER()), address(manager), "pool manager");
        assertEq(address(fresh.PERMIT2()), permit2, "permit2");
        assertEq(fresh.owner(), owner, "owner");
        assertEq(fresh.feeWallet(), feeWallet, "fee wallet");
        assertEq(fresh.routerFeeBps(), 50, "router fee 50 bps");
        assertEq(fresh.creatorShareBps(), 7_000, "creator share 70 %");
        assertEq(fresh.firstBuyCapBps(), 2_000, "first-buy cap 20 %");
        assertEq(fresh.dailyLaunchLimit(), 5, "five launches a day");
        assertEq(fresh.launcherGate(), address(gate), "the gate from the constructor");
        assertEq(fresh.hook(), address(0), "no hook");
        assertEq(fresh.launchCount(), 0, "no launch yet");
        assertEq(fresh.currency(address(usdg)).maxValuation, 0, "no currency until the deploy script adds it");
    }

    function test_the_constructor_emits_each_setting_event_exactly_once_and_no_CurrencyChanged() public {
        vm.recordLogs();
        SVLaunchpad fresh = new SVLaunchpad(manager, ISignatureTransfer(permit2), owner, feeWallet, address(gate));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32[7] memory topics = [
            ISVLaunchpad.FeeWalletChanged.selector,
            ISVLaunchpad.RouterFeeChanged.selector,
            ISVLaunchpad.CreatorShareChanged.selector,
            ISVLaunchpad.FirstBuyCapChanged.selector,
            ISVLaunchpad.DailyLaunchLimitChanged.selector,
            ISVLaunchpad.LauncherGateChanged.selector,
            ISVLaunchpad.HookChanged.selector
        ];
        for (uint256 t = 0; t < topics.length; t++) {
            uint256 seen;
            for (uint256 i = 0; i < logs.length; i++) {
                if (logs[i].emitter == address(fresh) && logs[i].topics[0] == topics[t]) seen++;
            }
            assertEq(seen, 1, "each setting event exactly once");
        }
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != ISVLaunchpad.CurrencyChanged.selector, "no CurrencyChanged at deploy");
        }
    }

    function test_constructor_reverts_ZeroAddress_for_each_required_address() public {
        vm.expectRevert(ISVLaunchpad.ZeroAddress.selector);
        new SVLaunchpad(IPoolManager(address(0)), ISignatureTransfer(permit2), owner, feeWallet, address(gate));
        vm.expectRevert(ISVLaunchpad.ZeroAddress.selector);
        new SVLaunchpad(manager, ISignatureTransfer(address(0)), owner, feeWallet, address(gate));
        vm.expectRevert(ISVLaunchpad.ZeroAddress.selector);
        new SVLaunchpad(manager, ISignatureTransfer(permit2), address(0), feeWallet, address(gate));
        vm.expectRevert(ISVLaunchpad.ZeroAddress.selector);
        new SVLaunchpad(manager, ISignatureTransfer(permit2), owner, address(0), address(gate));
    }

    function test_a_zero_launcher_gate_at_deploy_lets_anyone_launch() public {
        SVLaunchpad open = new SVLaunchpad(manager, ISignatureTransfer(permit2), owner, feeWallet, address(0));
        assertEq(open.launcherGate(), address(0), "no gate");
        assertTrue(open.isAllowedLauncher(stranger), "anyone may launch");
    }

    /// @dev The constants of spec 4.3 are internal (bytecode margin), so their values are proved by what they do:
    ///      the valuation constants bound `setCurrency` and `openingFor`, the router-fee cap bounds `setRouterFee`
    ///      (next section). `SUPPLY`, `POOL_FEE`, `TICK_SPACING`, the usable ticks and the text bounds are proved by
    ///      the launch suite of Task 3 through the minted supply, the pool key, the position range and the text
    ///      checks.
    function test_the_valuation_constants_bound_setCurrency_and_openingFor_exactly() public {
        vm.startPrank(owner);
        launchpad.setCurrency(address(usdg), 1e8, 1e36, 0);
        vm.expectRevert(ISVLaunchpad.BoundsOutOfRange.selector);
        launchpad.setCurrency(address(usdg), 1e8 - 1, 1e36, 0);
        vm.expectRevert(ISVLaunchpad.BoundsOutOfRange.selector);
        launchpad.setCurrency(address(usdg), 1e8, 1e36 + 1, 0);
        vm.stopPrank();
        (int24 low,,) = launchpad.openingFor(LOW, HIGH, 1e8);
        (int24 high,,) = launchpad.openingFor(LOW, HIGH, 1e36);
        assertGt(low, TickMath.minUsableTick(200), "the lowest valuation opens strictly inside the usable range");
        assertLt(high, TickMath.maxUsableTick(200), "and so does the highest");
        vm.expectRevert(abi.encodeWithSelector(ISVLaunchpad.ValuationOutOfRange.selector, 1e36 + 1, 1e8, 1e36));
        launchpad.openingFor(LOW, HIGH, 1e36 + 1);
    }

    function test_constructor_reverts_BadPayout_for_a_fee_wallet_that_is_the_pool_manager_or_the_launchpad() public {
        vm.expectRevert(ISVLaunchpad.BadPayout.selector);
        new SVLaunchpad(manager, ISignatureTransfer(permit2), owner, address(manager), address(gate));
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(ISVLaunchpad.BadPayout.selector);
        new SVLaunchpad(manager, ISignatureTransfer(permit2), owner, predicted, address(gate));
    }

    // -------------------------------------------------------------------------------------------------------
    // Settings (spec section 4.3 setter table)
    // -------------------------------------------------------------------------------------------------------

    function test_setFeeWallet_sets_emits_and_refuses_zero() public {
        address other = makeAddr("other wallet");
        vm.expectEmit(true, true, true, true, address(launchpad));
        emit ISVLaunchpad.FeeWalletChanged(other);
        vm.prank(owner);
        launchpad.setFeeWallet(other);
        assertEq(launchpad.feeWallet(), other, "fee wallet");
        vm.prank(owner);
        vm.expectRevert(ISVLaunchpad.ZeroAddress.selector);
        launchpad.setFeeWallet(address(0));
    }

    function test_setFeeWallet_reverts_BadPayout_for_the_launchpad_and_the_pool_manager() public {
        vm.startPrank(owner);
        vm.expectRevert(ISVLaunchpad.BadPayout.selector);
        launchpad.setFeeWallet(address(launchpad));
        vm.expectRevert(ISVLaunchpad.BadPayout.selector);
        launchpad.setFeeWallet(address(manager));
        vm.stopPrank();
        assertEq(launchpad.feeWallet(), feeWallet, "unchanged");
    }

    function test_setRouterFee_accepts_zero_to_50_and_reverts_FeeTooHigh_above() public {
        vm.expectEmit(true, true, true, true, address(launchpad));
        emit ISVLaunchpad.RouterFeeChanged(0);
        vm.prank(owner);
        launchpad.setRouterFee(0);
        assertEq(launchpad.routerFeeBps(), 0, "fee can be zero");
        vm.prank(owner);
        launchpad.setRouterFee(50);
        assertEq(launchpad.routerFeeBps(), 50, "fee back at the cap");
        vm.prank(owner);
        vm.expectRevert(ISVLaunchpad.FeeTooHigh.selector);
        launchpad.setRouterFee(51);
    }

    function test_setCreatorShare_accepts_up_to_10000_and_reverts_BpsTooHigh_above() public {
        vm.expectEmit(true, true, true, true, address(launchpad));
        emit ISVLaunchpad.CreatorShareChanged(10_000);
        vm.prank(owner);
        launchpad.setCreatorShare(10_000);
        assertEq(launchpad.creatorShareBps(), 10_000, "the whole share");
        vm.prank(owner);
        launchpad.setCreatorShare(0);
        assertEq(launchpad.creatorShareBps(), 0, "none");
        vm.prank(owner);
        vm.expectRevert(ISVLaunchpad.BpsTooHigh.selector);
        launchpad.setCreatorShare(10_001);
    }

    function test_setFirstBuyCap_accepts_up_to_10000_and_reverts_BpsTooHigh_above() public {
        vm.expectEmit(true, true, true, true, address(launchpad));
        emit ISVLaunchpad.FirstBuyCapChanged(0);
        vm.prank(owner);
        launchpad.setFirstBuyCap(0);
        assertEq(launchpad.firstBuyCapBps(), 0, "0 blocks any first buy");
        vm.prank(owner);
        launchpad.setFirstBuyCap(10_000);
        assertEq(launchpad.firstBuyCapBps(), 10_000, "no cap");
        vm.prank(owner);
        vm.expectRevert(ISVLaunchpad.BpsTooHigh.selector);
        launchpad.setFirstBuyCap(10_001);
    }

    function test_setDailyLaunchLimit_accepts_any_uint8_and_emits() public {
        vm.expectEmit(true, true, true, true, address(launchpad));
        emit ISVLaunchpad.DailyLaunchLimitChanged(0);
        vm.prank(owner);
        launchpad.setDailyLaunchLimit(0);
        assertEq(launchpad.dailyLaunchLimit(), 0, "0 is the pause");
        vm.prank(owner);
        launchpad.setDailyLaunchLimit(255);
        assertEq(launchpad.dailyLaunchLimit(), 255, "the uint8 maximum");
    }

    function test_setLauncherGate_accepts_any_address_including_zero_and_emits() public {
        address other = makeAddr("no code here");
        vm.expectEmit(true, true, true, true, address(launchpad));
        emit ISVLaunchpad.LauncherGateChanged(other);
        vm.prank(owner);
        launchpad.setLauncherGate(other);
        assertEq(launchpad.launcherGate(), other, "a codeless gate is accepted and refuses everyone");
        vm.prank(owner);
        launchpad.setLauncherGate(address(0));
        assertEq(launchpad.launcherGate(), address(0), "gate cleared");
    }

    function test_setHook_accepts_zero_and_a_valid_hook_with_code_and_emits() public {
        address valid = _hookAt(Hooks.AFTER_SWAP_FLAG);
        vm.expectEmit(true, true, true, true, address(launchpad));
        emit ISVLaunchpad.HookChanged(valid);
        vm.prank(owner);
        launchpad.setHook(valid);
        assertEq(launchpad.hook(), valid, "valid hook set");
        address antiSnipe = _hookAt(Hooks.BEFORE_SWAP_FLAG);
        vm.expectEmit(true, true, true, true, address(launchpad));
        emit ISVLaunchpad.HookChanged(antiSnipe);
        vm.prank(owner);
        launchpad.setHook(antiSnipe);
        assertEq(launchpad.hook(), antiSnipe, "a before-swap-only hook, the typical anti-snipe hook, is allowed");
        vm.prank(owner);
        launchpad.setHook(address(0));
        assertEq(launchpad.hook(), address(0), "back to hookless");
    }

    function test_setHook_reverts_HookNotAllowed_without_code_without_flags_and_for_each_refused_flag() public {
        address[5] memory refused = [
            // valid flags but no code
            address((uint160(uint256(keccak256("codeless hook"))) & ~Hooks.ALL_HOOK_MASK) | Hooks.AFTER_SWAP_FLAG),
            // code but no flag: not a valid hook for a static fee
            _hookAt(0),
            // a returns-delta flag without its action flag: invalid for v4 itself
            _hookAt(Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG),
            // valid for v4, refused by the launchpad: could change what the position pays at the mint
            _hookAt(Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG),
            // valid for v4, refused by the launchpad: could skim what the position collects
            _hookAt(Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG)
        ];
        for (uint256 i = 0; i < refused.length; i++) {
            vm.prank(owner);
            vm.expectRevert(ISVLaunchpad.HookNotAllowed.selector);
            launchpad.setHook(refused[i]);
        }
        assertEq(launchpad.hook(), address(0), "unchanged");
    }

    function test_setHook_reverts_HookNotAllowed_for_hooks_that_can_block_the_fee_poke_or_change_swap_amounts() public {
        address[4] memory refused = [
            // valid for v4, refused by the launchpad: the zero-delta fee poke runs the remove-liquidity hooks,
            // so either one could freeze collectFees for every launch made under the hook
            _hookAt(Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG),
            _hookAt(Hooks.AFTER_REMOVE_LIQUIDITY_FLAG),
            // valid for v4, refused by the launchpad: could change what a trade pays or receives
            _hookAt(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG),
            _hookAt(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG)
        ];
        for (uint256 i = 0; i < refused.length; i++) {
            assertTrue(Hooks.isValidHookAddress(IHooks(refused[i]), 10_000), "valid for v4 itself");
            vm.prank(owner);
            vm.expectRevert(ISVLaunchpad.HookNotAllowed.selector);
            launchpad.setHook(refused[i]);
        }
        assertEq(launchpad.hook(), address(0), "unchanged");
    }

    function test_setCurrency_allows_rebounds_and_disallows_with_a_zero_maximum() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        vm.expectEmit(true, true, true, true, address(launchpad));
        emit ISVLaunchpad.CurrencyChanged(address(other), 1e18, 5e18, 7);
        vm.prank(owner);
        launchpad.setCurrency(address(other), 1e18, 5e18, 7);
        ISVLaunchpad.CurrencyConfig memory c = launchpad.currency(address(other));
        assertEq(c.minValuation, 1e18, "min");
        assertEq(c.maxValuation, 5e18, "max");
        assertEq(c.creationFee, 7, "creation fee");
        vm.expectEmit(true, true, true, true, address(launchpad));
        emit ISVLaunchpad.CurrencyChanged(address(other), 0, 0, 0);
        vm.prank(owner);
        launchpad.setCurrency(address(other), 3, 0, 9);
        c = launchpad.currency(address(other));
        assertEq(c.minValuation + c.maxValuation + c.creationFee, 0, "a zero maximum clears the whole row");
    }

    function test_setCurrency_accepts_the_constant_edges_and_min_equal_to_max() public {
        vm.startPrank(owner);
        launchpad.setCurrency(address(usdg), MIN_VALUATION, MAX_VALUATION, 0);
        launchpad.setCurrency(address(usdg), USDG_MIN, USDG_MIN, 0);
        vm.stopPrank();
        assertEq(launchpad.currency(address(usdg)).maxValuation, USDG_MIN, "min == max is allowed");
    }

    function test_setCurrency_reverts_BoundsOutOfRange_and_ZeroAddress() public {
        vm.startPrank(owner);
        vm.expectRevert(ISVLaunchpad.BoundsOutOfRange.selector);
        launchpad.setCurrency(address(usdg), MIN_VALUATION - 1, USDG_MAX, 0);
        vm.expectRevert(ISVLaunchpad.BoundsOutOfRange.selector);
        launchpad.setCurrency(address(usdg), USDG_MAX + 1, USDG_MAX, 0);
        vm.expectRevert(ISVLaunchpad.BoundsOutOfRange.selector);
        launchpad.setCurrency(address(usdg), USDG_MIN, MAX_VALUATION + 1, 0);
        vm.expectRevert(ISVLaunchpad.ZeroAddress.selector);
        launchpad.setCurrency(address(0), USDG_MIN, USDG_MAX, 0);
        vm.stopPrank();
    }

    function test_every_setter_is_owner_only() public {
        bytes memory unauthorized = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger);
        vm.startPrank(stranger);
        vm.expectRevert(unauthorized);
        launchpad.setFeeWallet(stranger);
        vm.expectRevert(unauthorized);
        launchpad.setRouterFee(1);
        vm.expectRevert(unauthorized);
        launchpad.setCreatorShare(1);
        vm.expectRevert(unauthorized);
        launchpad.setFirstBuyCap(1);
        vm.expectRevert(unauthorized);
        launchpad.setDailyLaunchLimit(1);
        vm.expectRevert(unauthorized);
        launchpad.setLauncherGate(stranger);
        vm.expectRevert(unauthorized);
        launchpad.setHook(address(0));
        vm.expectRevert(unauthorized);
        launchpad.setCurrency(address(usdg), USDG_MIN, USDG_MAX, 0);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------------------------------------
    // Ownership
    // -------------------------------------------------------------------------------------------------------

    function test_ownership_moves_in_two_steps() public {
        address next = makeAddr("next owner");
        vm.prank(owner);
        launchpad.transferOwnership(next);
        assertEq(launchpad.owner(), owner, "still the old owner until accepted");
        assertEq(launchpad.pendingOwner(), next, "pending");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        launchpad.acceptOwnership();
        vm.prank(next);
        launchpad.acceptOwnership();
        assertEq(launchpad.owner(), next, "accepted");
    }

    function test_renounceOwnership_always_reverts() public {
        vm.prank(owner);
        vm.expectRevert(ISVLaunchpad.RenounceDisabled.selector);
        launchpad.renounceOwnership();
        assertEq(launchpad.owner(), owner, "owner unchanged");
    }

    // -------------------------------------------------------------------------------------------------------
    // The launcher gate (spec section 4.7): fail closed
    // -------------------------------------------------------------------------------------------------------

    function test_isAllowedLauncher_allows_a_holder_and_refuses_a_non_holder() public view {
        assertTrue(launchpad.isAllowedLauncher(creator), "the creator holds one");
        assertFalse(launchpad.isAllowedLauncher(stranger), "the stranger holds none");
    }

    function test_a_gate_that_reverts_replies_short_burns_its_gas_or_has_no_code_refuses_everyone() public {
        address[4] memory gates = [
            address(new MockRevertingGate()),
            address(new MockERC721ShortReply()),
            address(new MockGasBurningGate()),
            makeAddr("no code here")
        ];
        for (uint256 i = 0; i < gates.length; i++) {
            vm.prank(owner);
            launchpad.setLauncherGate(gates[i]);
            assertFalse(launchpad.isAllowedLauncher(creator), "a broken gate never lets anyone through");
        }
        vm.prank(owner);
        launchpad.setLauncherGate(address(0));
        assertTrue(launchpad.isAllowedLauncher(stranger), "a zero gate lets anyone launch");
    }

    // -------------------------------------------------------------------------------------------------------
    // predictToken (spec section 4.6)
    // -------------------------------------------------------------------------------------------------------

    function test_predictToken_is_CREATE2_over_the_callers_salt_and_the_token_init_code() public view {
        bytes32 salt = keccak256("app salt");
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(SVLaunchToken).creationCode, abi.encode("Launch Token", "LT", address(launchpad)))
        );
        address expected =
            vm.computeCreate2Address(keccak256(abi.encode(creator, salt)), initCodeHash, address(launchpad));
        assertEq(launchpad.predictToken(creator, salt, "Launch Token", "LT"), expected, "CREATE2 address");
        assertTrue(
            launchpad.predictToken(stranger, salt, "Launch Token", "LT") != expected,
            "the caller is mixed into the salt: nobody can take another creator's address"
        );
        assertTrue(launchpad.predictToken(creator, salt, "Other", "LT") != expected, "the name is in the init code");
    }

    // -------------------------------------------------------------------------------------------------------
    // openingFor (spec section 3.2)
    // -------------------------------------------------------------------------------------------------------

    /// @dev Both currency orders at one valuation: the tick flips sign, the price is exactly the tick's, and the
    ///      snapped valuation is the same, at or below the request and within one 200-tick step of it.
    function _assertOpening(uint256 valuation, int24 tokenFirstTick, uint256 snapped) internal view {
        (int24 tick0, uint160 price0, uint256 snapped0) = launchpad.openingFor(LOW, HIGH, valuation);
        (int24 tick1, uint160 price1, uint256 snapped1) = launchpad.openingFor(HIGH, LOW, valuation);
        assertEq(tick0, tokenFirstTick, "token first: the snapped tick");
        assertEq(tick1, -tokenFirstTick, "quote first: the same tick with the sign flipped");
        assertEq(price0, TickMath.getSqrtPriceAtTick(tick0), "token first: the price is exactly the tick's");
        assertEq(price1, TickMath.getSqrtPriceAtTick(tick1), "quote first: the price is exactly the tick's");
        assertEq(snapped0, snapped, "token first: the snapped valuation");
        assertEq(snapped1, snapped, "quote first: the same snapped valuation");
        assertLe(snapped, valuation, "never above the request");
        assertGe(snapped * 10_202, valuation * 10_000, "within one 200-tick step of the request");
    }

    /// @dev The worked values of spec section 3.2, computed with the pinned TickMath: USDG at 6 decimals and an
    ///      18-decimal stock at USD 100 and USD 1.
    function test_openingFor_matches_the_spec_worked_values_in_both_orders() public view {
        _assertOpening(5_000e6, -398_400, 4_995_430_232);
        _assertOpening(10_000e6, -391_600, 9_860_033_275);
        _assertOpening(1_000_000e6, -345_600, 980_693_092_270);
        _assertOpening(10_000_000e6, -322_400, 9_978_056_056_693);
        _assertOpening(50e18, -168_200, 49_605_751_312_209_836_038);
        _assertOpening(100_000e18, -92_200, 99_084_351_947_979_319_780_624);
        _assertOpening(10_000_000e18, -46_200, 9_855_072_168_218_428_952_838_236);
        _assertOpening(MIN_VALUATION, -437_600, 99_134_231);
    }

    /// @dev The snapping branches: a price exactly on a tick, a tick that is a multiple of 200 whose price sits
    ///      strictly below the quote-first request (the last line of the quote-first rule), and a positive tick
    ///      in the token-first order.
    function test_openingFor_takes_every_snapping_branch() public view {
        _assertOpening(1e27, 0, 1e27);
        _assertOpening(1e27 + 1e9, 0, 1e27);
        (int24 tick0,, uint256 snapped0) = launchpad.openingFor(LOW, HIGH, 1e27 - 1e9);
        (int24 tick1,, uint256 snapped1) = launchpad.openingFor(HIGH, LOW, 1e27 - 1e9);
        assertEq(tick0, -200, "token first: a tick of -1 rounds down to -200");
        assertEq(tick1, 200, "quote first: tick 0's price is below the request, so the next multiple of 200");
        assertEq(snapped0, 980_199_653_440_576_965_517_473_175, "token-first snapped valuation");
        assertEq(snapped1, 980_199_653_440_576_965_517_473_174, "quote-first snapped valuation, one unit lower");
        (tick0,, snapped0) = launchpad.openingFor(LOW, HIGH, MAX_VALUATION);
        (tick1,, snapped1) = launchpad.openingFor(HIGH, LOW, MAX_VALUATION);
        assertEq(tick0, 207_200, "token first at the maximum: a positive tick");
        assertEq(tick1, -207_200, "quote first at the maximum");
        assertEq(snapped0, 995_707_471_465_282_501_632_005_929_535_921_683, "token-first V' at the maximum");
        assertEq(snapped1, 995_707_471_465_282_501_632_005_239_339_536_368, "quote-first V' at the maximum");
    }

    function test_openingFor_reverts_ValuationOutOfRange_outside_the_constants() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ISVLaunchpad.ValuationOutOfRange.selector, MIN_VALUATION - 1, MIN_VALUATION, MAX_VALUATION
            )
        );
        launchpad.openingFor(LOW, HIGH, MIN_VALUATION - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISVLaunchpad.ValuationOutOfRange.selector, MAX_VALUATION + 1, MIN_VALUATION, MAX_VALUATION
            )
        );
        launchpad.openingFor(HIGH, LOW, MAX_VALUATION + 1);
    }
}
