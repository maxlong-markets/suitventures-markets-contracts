// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {ISVLaunchpad} from "./interfaces/ISVLaunchpad.sol";
import {SVLaunchToken} from "./SVLaunchToken.sol";

/// @title SVLaunchpad
/// @notice The MaxLong Markets instant launchpad. One transaction, signed by a creator the launcher gate allows,
///         deploys a one-billion-supply token by CREATE2, initialises its hookless 1 % Uniswap v4 pool at the
///         snapped opening valuation, places the whole supply in one one-sided position this contract owns and has
///         no code path to decrease, and optionally buys the creator a first allocation with their own money.
///         Anyone may collect the position's fees, which are split between the launch's payout address and the
///         fee wallet; a share whose delivery fails waits here for its owner to claim.
/// @dev Spec: docs/superpowers/specs/2026-09-28-instant-launchpad-design.md (frontend repo), sections 3 and 4. The
///      step numbers in the body comments are the spec's. Talks to the PoolManager directly; no PositionManager.
///      Fee-on-transfer and rebasing quotes fail closed at launch and are split on what arrived at collection.
contract SVLaunchpad is ISVLaunchpad, Ownable2Step, ReentrancyGuard {
    using Hooks for IHooks;
    using SafeERC20 for IERC20;
    using TransientSlot for *;
    using StateLibrary for IPoolManager;

    // -------------------------------------------------------------------------------------------------------
    // Constants (spec section 4.3)
    // -------------------------------------------------------------------------------------------------------

    /// @dev The supply of every launched token, all of it placed in the pool.
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    /// @dev The static LP fee of every launch pool: 1 %.
    uint24 internal constant POOL_FEE = 10_000;
    /// @dev The tick spacing of every launch pool; openings snap to multiples of it.
    int24 internal constant TICK_SPACING = 200;
    /// @dev `TickMath.minUsableTick(200)`, the far end of a quote-first position.
    int24 internal constant MIN_USABLE_TICK = -887_200;
    /// @dev `TickMath.maxUsableTick(200)`, the far end of a token-first position.
    int24 internal constant MAX_USABLE_TICK = 887_200;
    /// @dev The hard cap on `routerFeeBps`: 0.5 %, as SVRouter's.
    uint16 internal constant MAX_ROUTER_FEE_BPS = 50;
    /// @dev The lowest valuation any currency bound may take, in raw quote units (spec section 3.3).
    uint256 internal constant MIN_VALUATION = 1e8;
    /// @dev The highest valuation any currency bound may take, in raw quote units (spec section 3.3).
    uint256 internal constant MAX_VALUATION = 1e36;
    /// @dev Name length bound in bytes.
    uint256 internal constant MAX_NAME_BYTES = 32;
    /// @dev Symbol length bound in bytes.
    uint256 internal constant MAX_SYMBOL_BYTES = 11;
    /// @dev Metadata URI length bound in bytes.
    uint256 internal constant MAX_URI_BYTES = 128;

    /// @dev Basis points denominator: 10_000 bps is 100 %.
    uint256 private constant BPS = 10_000;
    /// @dev Gas allowance for reading the gate's `balanceOf`, as SVRouter's `HOLDER_CHECK_GAS`.
    uint256 private constant GATE_CHECK_GAS = 100_000;
    uint16 private constant INITIAL_CREATOR_SHARE_BPS = 7_000;
    uint16 private constant INITIAL_FIRST_BUY_CAP_BPS = 2_000;
    uint8 private constant INITIAL_DAILY_LAUNCH_LIMIT = 5;
    /// @dev The transient "unlock in flight" flag read by `unlockCallback` (spec section 4.4), at the ERC-7201
    ///      slot of the namespace "svlaunchpad.unlocking".
    bytes32 private constant UNLOCKING_SLOT =
        keccak256(abi.encode(uint256(keccak256("svlaunchpad.unlocking")) - 1)) & ~bytes32(uint256(0xff));

    // -------------------------------------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------------------------------------

    /// @inheritdoc ISVLaunchpad
    IPoolManager public immutable POOL_MANAGER;
    /// @inheritdoc ISVLaunchpad
    ISignatureTransfer public immutable PERMIT2;

    // -------------------------------------------------------------------------------------------------------
    // Storage, in the slot order of spec section 4.4 (slots 0 and 1 are Ownable's and Ownable2Step's)
    // -------------------------------------------------------------------------------------------------------

    /// @dev One launch count per wallet per UTC day, in one slot.
    struct DayCount {
        uint64 day;
        uint8 count;
    }

    /// @dev Which operation an unlock carries (spec section 4.2).
    enum Action {
        Launch,
        Collect
    }

    /// @dev The Action.Launch payload, exactly these fields (spec section 4.2).
    struct LaunchCallback {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        address token;
        address quote;
        bool tokenIsCurrency0;
        uint256 net; // firstBuy minus routerFee; 0 without a first buy
        address creator; // msg.sender of launch; receives the first-buy tokens
        uint256 minFirstBuyTokens;
    }

    /// @dev What the launch callback returns (spec section 4.2).
    struct LaunchResult {
        uint128 liquidity;
        uint256 owed;
        uint256 tokensOut;
    }

    /// @dev The working values of one launch, in memory so `launch` stays within the stack the legacy code
    ///      generator allows (via-IR is off by design, as in SVRouter).
    struct LaunchState {
        address token;
        address quote;
        address payout;
        bool tokenIsCurrency0;
        int24 openTick;
        uint160 sqrtPriceX96;
        uint256 openingValuation;
        uint256 routerFee;
        uint256 creationFee;
        uint256 net;
        PoolKey key;
        LaunchResult result;
    }

    /// @inheritdoc ISVLaunchpad
    address public feeWallet;
    /// @inheritdoc ISVLaunchpad
    uint16 public routerFeeBps;
    /// @inheritdoc ISVLaunchpad
    uint16 public creatorShareBps;
    /// @inheritdoc ISVLaunchpad
    uint16 public firstBuyCapBps;
    /// @inheritdoc ISVLaunchpad
    uint8 public dailyLaunchLimit;
    /// @inheritdoc ISVLaunchpad
    address public launcherGate;
    /// @inheritdoc ISVLaunchpad
    address public hook;
    /// @inheritdoc ISVLaunchpad
    uint256 public launchCount;
    mapping(address quote => CurrencyConfig) private _currencies;
    mapping(address token => Launch) private _launches;
    mapping(address account => DayCount) private _days;
    mapping(address account => mapping(address currency => uint256)) private _owed;

    // -------------------------------------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------------------------------------

    /// @param poolManager_ The Uniswap v4 PoolManager.
    /// @param permit2_ The canonical Permit2.
    /// @param owner_ The Ownable2Step owner; the deploy script passes its own broadcaster, then transfers.
    /// @param feeWallet_ Receives the router fee, the creation fee and the platform's fee share.
    /// @param launcherGate_ The Suits NFT at deploy; zero lets anyone launch.
    /// @dev The owner is checked inside the `Ownable` constructor argument because `Ownable`'s constructor runs
    ///      before this body and would otherwise revert with its own error instead of `ZeroAddress()`. Every
    ///      setting's event is emitted with its initial value so indexers see the deploy state; currencies are
    ///      added by the deploy script, so no `CurrencyChanged` here.
    constructor(
        IPoolManager poolManager_,
        ISignatureTransfer permit2_,
        address owner_,
        address feeWallet_,
        address launcherGate_
    ) Ownable(_nonZero(owner_)) {
        if (address(poolManager_) == address(0) || address(permit2_) == address(0) || feeWallet_ == address(0)) {
            revert ZeroAddress();
        }
        // The payout rule of spec section 4.5 step 6, applied to the fee wallet (amended 29 Sep 2026).
        if (feeWallet_ == address(this) || feeWallet_ == address(poolManager_)) revert BadPayout();
        POOL_MANAGER = poolManager_;
        PERMIT2 = permit2_;
        feeWallet = feeWallet_;
        routerFeeBps = MAX_ROUTER_FEE_BPS;
        creatorShareBps = INITIAL_CREATOR_SHARE_BPS;
        firstBuyCapBps = INITIAL_FIRST_BUY_CAP_BPS;
        dailyLaunchLimit = INITIAL_DAILY_LAUNCH_LIMIT;
        launcherGate = launcherGate_;
        emit FeeWalletChanged(feeWallet_);
        emit RouterFeeChanged(MAX_ROUTER_FEE_BPS);
        emit CreatorShareChanged(INITIAL_CREATOR_SHARE_BPS);
        emit FirstBuyCapChanged(INITIAL_FIRST_BUY_CAP_BPS);
        emit DailyLaunchLimitChanged(INITIAL_DAILY_LAUNCH_LIMIT);
        emit LauncherGateChanged(launcherGate_);
        emit HookChanged(address(0));
    }

    // -------------------------------------------------------------------------------------------------------
    // launch (spec section 4.5)
    // -------------------------------------------------------------------------------------------------------

    /// @inheritdoc ISVLaunchpad
    /// @dev Steps in the spec's order: every cheap check before any transfer, and the payment before the
    ///      deployment, so a failed permit wastes no deployment gas. No native path: every quote is an ERC-20 on
    ///      the owner's allowlist. The position is owned by this contract, and no function here can decrease its
    ///      liquidity: that is the lock.
    function launch(
        LaunchParams calldata p,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) external nonReentrant returns (address token) {
        // 1.
        if (block.timestamp > p.deadline) revert Expired();
        // 2.
        if (!isAllowedLauncher(msg.sender)) revert NotAllowedToLaunch();
        // 3.
        _countLaunch(msg.sender);
        // 4.
        _checkText(p);
        // 5.
        CurrencyConfig memory c = _currencies[p.quote];
        if (c.maxValuation == 0) revert CurrencyNotAllowed();
        if (p.valuation < c.minValuation || p.valuation > c.maxValuation) {
            revert ValuationOutOfRange(p.valuation, c.minValuation, c.maxValuation);
        }
        LaunchState memory s;
        s.quote = p.quote;
        // 6.
        s.payout = p.payout == address(0) ? msg.sender : p.payout;
        _checkPayout(s.payout);
        // 7. The router fee comes out of the first buy exactly as SVRouter takes it.
        s.routerFee = p.firstBuy * routerFeeBps / BPS;
        s.net = p.firstBuy - s.routerFee;
        s.creationFee = c.creationFee;
        _pull(p.quote, p.firstBuy + c.creationFee, permit, signature);
        // 8.
        s.token = address(new SVLaunchToken{salt: _salt(msg.sender, p.salt)}(p.name, p.symbol, address(this)));
        // 9.
        s.tokenIsCurrency0 = s.token < p.quote;
        (s.openTick, s.sqrtPriceX96, s.openingValuation) = _opening(s.token, p.quote, p.valuation);
        s.key = _key(s.token, p.quote, hook);
        // 10. A key someone initialised first reverts PoolAlreadyInitialized here (spec section 4.10).
        POOL_MANAGER.initialize(s.key, s.sqrtPriceX96);
        // 11.
        s.result = _unlockLaunch(s, p.minFirstBuyTokens);
        // 12. to 14.
        _finishLaunch(s, p);
        return s.token;
    }

    /// @inheritdoc ISVLaunchpad
    /// @dev Only the PoolManager may call this, and only while `_unlock` has a call in flight: the transient flag
    ///      is what stops an unlock started by someone else from reaching the position code. Not `nonReentrant`:
    ///      it runs inside the guarded `launch`.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        if (!UNLOCKING_SLOT.asBoolean().tload()) revert UnexpectedCallback();
        if (abi.decode(data[:32], (Action)) == Action.Launch) {
            (, LaunchCallback memory cb) = abi.decode(data, (Action, LaunchCallback));
            return _launchCallback(cb);
        }
        (, address token) = abi.decode(data, (Action, address));
        return _collectCallback(token);
    }

    /// @dev Step 3: `block.timestamp / 1 days` is the UTC day number; a new day restarts the count at zero.
    function _countLaunch(address account) private {
        // The day number fits 64 bits for billions of years.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 day = uint64(block.timestamp / 1 days);
        DayCount memory d = _days[account];
        uint8 count = d.day == day ? d.count : 0;
        if (count >= dailyLaunchLimit) revert DailyLimitReached();
        _days[account] = DayCount({day: day, count: count + 1});
    }

    /// @dev Step 4: lengths in bytes, not characters.
    function _checkText(LaunchParams calldata p) private pure {
        uint256 nameLength = bytes(p.name).length;
        if (nameLength == 0 || nameLength > MAX_NAME_BYTES) revert BadName();
        uint256 symbolLength = bytes(p.symbol).length;
        if (symbolLength == 0 || symbolLength > MAX_SYMBOL_BYTES) revert BadSymbol();
        if (bytes(p.metadataUri).length > MAX_URI_BYTES) revert UriTooLong();
    }

    /// @dev Step 7. Nothing is pulled for a free launch, so it needs no approval and no signature. Otherwise the
    ///      pull is measured: this contract can hold credited `owed` balances between transactions, so a
    ///      fee-on-transfer quote must never be able to pay part of a launch out of them.
    function _pull(
        address quote,
        uint256 total,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) private {
        if (total == 0) return;
        if (permit.permitted.token != quote || permit.permitted.amount < total) revert PermitMismatch();
        uint256 before = IERC20(quote).balanceOf(address(this));
        PERMIT2.permitTransferFrom(
            permit,
            ISignatureTransfer.SignatureTransferDetails({to: address(this), requestedAmount: total}),
            msg.sender,
            signature
        );
        if (IERC20(quote).balanceOf(address(this)) - before != total) revert PermitMismatch();
    }

    /// @dev Sets the in-flight flag around the PoolManager's `unlock`, which calls back into `unlockCallback`.
    function _unlock(bytes memory data) private returns (bytes memory result) {
        UNLOCKING_SLOT.asBoolean().tstore(true);
        result = POOL_MANAGER.unlock(data);
        UNLOCKING_SLOT.asBoolean().tstore(false);
    }

    /// @dev Step 11: the payload is built field by field, which keeps this frame within the stack.
    function _unlockLaunch(LaunchState memory s, uint256 minFirstBuyTokens) private returns (LaunchResult memory) {
        LaunchCallback memory cb;
        cb.key = s.key;
        (cb.tickLower, cb.tickUpper) = _range(s.tokenIsCurrency0, s.openTick);
        cb.token = s.token;
        cb.quote = s.quote;
        cb.tokenIsCurrency0 = s.tokenIsCurrency0;
        cb.net = s.net;
        cb.creator = msg.sender;
        cb.minFirstBuyTokens = minFirstBuyTokens;
        return abi.decode(_unlock(abi.encode(Action.Launch, cb)), (LaunchResult));
    }

    /// @dev Steps 11.2 to 11.7. The mint charges only the token: the pool sits exactly on the position's lower
    ///      edge when the token is currency0 and on its upper edge when it is currency1 (spec section 3.3). The
    ///      quote side of the mint is zero by that maths and is never settled, so were it not, the unlock would
    ///      revert `CurrencyNotSettled`; likewise the quote is settled with exactly `net`, so a partial fill
    ///      cannot pass silently.
    function _launchCallback(LaunchCallback memory cb) private returns (bytes memory) {
        LaunchResult memory r;
        // 2.
        r.liquidity = _liquidityFor(cb.tokenIsCurrency0, cb.tokenIsCurrency0 ? cb.tickLower : cb.tickUpper);
        (BalanceDelta delta,) = POOL_MANAGER.modifyLiquidity(
            cb.key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: cb.tickLower,
                tickUpper: cb.tickUpper,
                liquidityDelta: int256(uint256(r.liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
        // A fresh position's token delta is negative and far above type(int128).min, so its negation is a
        // positive int128 that fits uint128 and uint256 unchanged.
        // forge-lint: disable-next-line(unsafe-typecast)
        r.owed = uint256(uint128(-(cb.tokenIsCurrency0 ? delta.amount0() : delta.amount1())));
        // 3.
        if (cb.net > 0) r.tokensOut = _firstBuy(cb);
        uint256 cap = SUPPLY * firstBuyCapBps / BPS;
        if (r.tokensOut > cap) revert FirstBuyTooLarge(r.tokensOut, cap);
        if (r.tokensOut < cb.minFirstBuyTokens) revert FirstBuyTooSmall(r.tokensOut, cb.minFirstBuyTokens);
        // 4.
        _pay(cb.token, r.owed);
        // 5.
        if (cb.net > 0) _pay(cb.quote, cb.net);
        // 6. Inside the callback msg.sender is the PoolManager, so the payload carries the creator.
        if (r.tokensOut > 0) POOL_MANAGER.take(Currency.wrap(cb.token), cb.creator, r.tokensOut);
        // 7.
        return abi.encode(r);
    }

    /// @dev Step 11.3: exact input `net` of the quote for the token, with the price limit at the far end because
    ///      the position covers it. The pool's 1 % fee accrues to this launch's own position.
    function _firstBuy(LaunchCallback memory cb) private returns (uint256 tokensOut) {
        BalanceDelta delta = POOL_MANAGER.swap(
            cb.key,
            IPoolManager.SwapParams({
                zeroForOne: !cb.tokenIsCurrency0,
                // `net` was pulled from the creator, so it is far below 2^255.
                // forge-lint: disable-next-line(unsafe-typecast)
                amountSpecified: -int256(cb.net),
                sqrtPriceLimitX96: cb.tokenIsCurrency0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        // The token side of an exact-input buy is the non-negative output.
        // forge-lint: disable-next-line(unsafe-typecast)
        tokensOut = uint256(uint128(cb.tokenIsCurrency0 ? delta.amount0() : delta.amount1()));
    }

    /// @dev Pays exactly `amount` of `currency_` into the PoolManager: `sync`, transfer, `settle`.
    function _pay(address currency_, uint256 amount) private {
        POOL_MANAGER.sync(Currency.wrap(currency_));
        IERC20(currency_).safeTransfer(address(POOL_MANAGER), amount);
        POOL_MANAGER.settle();
    }

    /// @dev Steps 12 to 14, apart from `launch` to keep it within the stack. The fee transfer is part of the
    ///      launch, so a fee wallet that refuses it stops paid launches until the owner changes it; nothing
    ///      already launched is affected.
    function _finishLaunch(LaunchState memory s, LaunchParams calldata p) private {
        // 12.
        uint256 fees = s.routerFee + s.creationFee;
        if (fees > 0) IERC20(s.quote).safeTransfer(feeWallet, fees);
        // 13. What the pool did not take; afterwards this contract holds none of the token.
        uint256 dust = SUPPLY - s.result.owed;
        if (dust > 0) SVLaunchToken(s.token).burn(dust);
        // 14.
        Launch storage l = _launches[s.token];
        l.creator = msg.sender;
        // forge-lint: disable-next-line(unsafe-typecast)
        l.launchedAt = uint64(block.timestamp);
        l.creatorShareBps = creatorShareBps;
        l.tokenIsCurrency0 = s.tokenIsCurrency0;
        l.payout = s.payout;
        l.openTick = s.openTick;
        l.quote = s.quote;
        l.hook = address(s.key.hooks);
        l.liquidity = s.result.liquidity;
        launchCount += 1;
        _emitLaunched(s, p);
    }

    /// @dev The event payload is filled field by field: a sixteen-field struct literal exceeds the stack.
    function _emitLaunched(LaunchState memory s, LaunchParams calldata p) private {
        LaunchedData memory d;
        d.poolId = PoolId.unwrap(s.key.toId());
        d.payout = s.payout;
        d.hook = address(s.key.hooks);
        d.tokenIsCurrency0 = s.tokenIsCurrency0;
        d.openTick = s.openTick;
        d.openingValuation = s.openingValuation;
        d.liquidity = s.result.liquidity;
        d.tokensInPool = s.result.owed;
        d.firstBuyIn = s.net;
        d.firstBuyTokens = s.result.tokensOut;
        d.routerFee = s.routerFee;
        d.creationFee = s.creationFee;
        d.creatorShareBps = creatorShareBps;
        d.name = p.name;
        d.symbol = p.symbol;
        d.metadataUri = p.metadataUri;
        emit Launched(s.token, msg.sender, s.quote, d);
    }

    // -------------------------------------------------------------------------------------------------------
    // Fees, claims, payout (spec section 4.6)
    // -------------------------------------------------------------------------------------------------------

    /// @inheritdoc ISVLaunchpad
    /// @dev The only call that ever touches the position after launch, and it cannot change its liquidity. The
    ///      split uses the share fixed at launch and the fee wallet read now; the fee wallet takes the rounding
    ///      dust. Shares are delivered after the unlock has returned, each by a tolerant transfer, so no
    ///      recipient, and no owner setting, can freeze another recipient's share.
    function collectFees(address token) external nonReentrant {
        // 1.
        Launch memory l = _launchOf(token);
        // 2. and 3.
        (uint256 tokenFees, uint256 quoteFees) =
            abi.decode(_unlock(abi.encode(Action.Collect, token)), (uint256, uint256));
        // 4.
        uint256 tokenToPayout = tokenFees * l.creatorShareBps / BPS;
        uint256 quoteToPayout = quoteFees * l.creatorShareBps / BPS;
        address wallet = feeWallet;
        // 5.
        _deliver(token, l.payout, tokenToPayout);
        _deliver(token, wallet, tokenFees - tokenToPayout);
        _deliver(l.quote, l.payout, quoteToPayout);
        _deliver(l.quote, wallet, quoteFees - quoteToPayout);
        // 6.
        emit FeesCollected(token, l.payout, tokenFees, quoteFees, tokenToPayout, quoteToPayout);
    }

    /// @inheritdoc ISVLaunchpad
    /// @dev Paying to an address the claimant names is what rescues a recipient the currency refuses: a retry to
    ///      the same address would fail the same way. The collection already recorded the amount, so no event.
    function claim(address asset, address to) external nonReentrant {
        if (to == address(0)) revert BadPayout();
        _checkPayout(to);
        uint256 amount = _owed[msg.sender][asset];
        if (amount == 0) revert NothingOwed();
        _owed[msg.sender][asset] = 0;
        IERC20(asset).safeTransfer(to, amount);
    }

    /// @inheritdoc ISVLaunchpad
    /// @dev Only the current payout can move it, so the creator loses that right once they hand it on. One
    ///      storage word changes and nothing is called.
    function setPayout(address token, address payout) external {
        Launch storage l = _launches[token];
        if (l.creator == address(0)) revert UnknownLaunch();
        address previous = l.payout;
        if (msg.sender != previous) revert NotPayout();
        if (payout == address(0)) revert ZeroAddress();
        _checkPayout(payout);
        l.payout = payout;
        emit PayoutChanged(token, previous, payout);
    }

    /// @dev Steps 2 and 3, inside the unlock: v4's documented poke, `modifyLiquidity` with a zero delta, returns
    ///      exactly the fees owed since the last checkpoint, which the pool moves so they cannot be paid twice.
    function _collectCallback(address token) private returns (bytes memory) {
        Launch memory l = _launches[token];
        (int24 tickLower, int24 tickUpper) = _range(l.tokenIsCurrency0, l.openTick);
        (BalanceDelta delta,) = POOL_MANAGER.modifyLiquidity(
            _key(token, l.quote, l.hook),
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 0, salt: bytes32(0)
            }),
            ""
        );
        (int128 tokenDelta, int128 quoteDelta) =
            l.tokenIsCurrency0 ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        if (tokenDelta == 0 && quoteDelta == 0) revert NothingToCollect();
        return abi.encode(_takeMeasured(token, tokenDelta), _takeMeasured(l.quote, quoteDelta));
    }

    /// @dev Takes a positive fee delta into this contract and returns the measured increase: a fee-on-transfer
    ///      quote delivers less than asked, and splitting the asked amount would pay out balance that belongs to
    ///      earlier credited shares.
    function _takeMeasured(address asset, int128 delta) private returns (uint256) {
        if (delta == 0) return 0;
        uint256 before = IERC20(asset).balanceOf(address(this));
        // Fees are never negative, so the int128 fits uint128 and uint256 unchanged.
        // forge-lint: disable-next-line(unsafe-typecast)
        POOL_MANAGER.take(Currency.wrap(asset), address(this), uint256(uint128(delta)));
        return IERC20(asset).balanceOf(address(this)) - before;
    }

    /// @dev Step 5: a low-level `transfer` that counts as delivered on an empty reply or a reply whose first word
    ///      is 1, the same rule as v4's `CurrencyLibrary.transfer`. A revert, a `false` or any other reply credits
    ///      `owed` instead, taken later with `claim`. The call forwards all remaining gas; nothing else is bounded.
    function _deliver(address asset, address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok, bytes memory reply) = asset.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        // bytes32(reply) reads the reply's first word; the length check above it guarantees the word exists, and a
        // bytes32 always fits uint256, so the cast truncates nothing.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (ok && (reply.length == 0 || (reply.length >= 32 && uint256(bytes32(reply)) == 1))) return;
        _owed[to][asset] += amount;
    }

    // -------------------------------------------------------------------------------------------------------
    // Owner settings (Ownable2Step: a transfer takes effect only when the new owner accepts)
    // -------------------------------------------------------------------------------------------------------

    /// @inheritdoc ISVLaunchpad
    /// @dev The payout rule, applied to the fee wallet: zero, this contract and the PoolManager could never spend
    ///      what they receive.
    function setFeeWallet(address wallet) external onlyOwner {
        if (wallet == address(0)) revert ZeroAddress();
        _checkPayout(wallet);
        feeWallet = wallet;
        emit FeeWalletChanged(wallet);
    }

    /// @inheritdoc ISVLaunchpad
    /// @dev Any value within the cap, so the fee can be lowered and raised again but never above SVRouter's.
    function setRouterFee(uint16 bps) external onlyOwner {
        if (bps > MAX_ROUTER_FEE_BPS) revert FeeTooHigh();
        routerFeeBps = bps;
        emit RouterFeeChanged(bps);
    }

    /// @inheritdoc ISVLaunchpad
    /// @dev Existing launches keep the share they were made with.
    function setCreatorShare(uint16 bps) external onlyOwner {
        if (bps > BPS) revert BpsTooHigh();
        creatorShareBps = bps;
        emit CreatorShareChanged(bps);
    }

    /// @inheritdoc ISVLaunchpad
    function setFirstBuyCap(uint16 bps) external onlyOwner {
        if (bps > BPS) revert BpsTooHigh();
        firstBuyCapBps = bps;
        emit FirstBuyCapChanged(bps);
    }

    /// @inheritdoc ISVLaunchpad
    /// @dev Any value; 0 stops new launches and touches nothing already launched.
    function setDailyLaunchLimit(uint8 limit) external onlyOwner {
        dailyLaunchLimit = limit;
        emit DailyLaunchLimitChanged(limit);
    }

    /// @inheritdoc ISVLaunchpad
    /// @dev Any address: `isAllowedLauncher` fails closed, so a wrong gate stops launches and can do nothing else.
    function setLauncherGate(address gate) external onlyOwner {
        launcherGate = gate;
        emit LauncherGateChanged(gate);
    }

    /// @inheritdoc ISVLaunchpad
    /// @dev Spec section 4.9: zero, or an address with code that v4 accepts for a static-fee pool and that carries
    ///      neither returns-delta flag on liquidity, which would let a hook change what the position pays at the
    ///      mint or skim what it collects. Applies to later launches only: a launch's hook is in its pool key.
    function setHook(address newHook) external onlyOwner {
        if (newHook != address(0)) {
            IHooks h = IHooks(newHook);
            if (
                newHook.code.length == 0 || !h.isValidHookAddress(POOL_FEE)
                    || h.hasPermission(Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG)
                    || h.hasPermission(Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG)
            ) revert HookNotAllowed();
        }
        hook = newHook;
        emit HookChanged(newHook);
    }

    /// @inheritdoc ISVLaunchpad
    /// @dev Bounds inside `[MIN_VALUATION, MAX_VALUATION]` (1e8 to 1e36) guarantee that every allowed valuation gives a legal
    ///      price, a tick strictly inside the usable range and a liquidity under the per-tick cap in both currency
    ///      orders (spec section 3.3), so a launch can never fail on arithmetic. A zero maximum clears the row
    ///      and the event reports the cleared row. Existing launches are never affected.
    function setCurrency(address quote, uint256 minValuation, uint256 maxValuation, uint256 creationFee)
        external
        onlyOwner
    {
        if (quote == address(0)) revert ZeroAddress();
        if (maxValuation == 0) {
            delete _currencies[quote];
            emit CurrencyChanged(quote, 0, 0, 0);
            return;
        }
        if (minValuation < MIN_VALUATION || minValuation > maxValuation || maxValuation > MAX_VALUATION) {
            revert BoundsOutOfRange();
        }
        _currencies[quote] =
            CurrencyConfig({minValuation: minValuation, maxValuation: maxValuation, creationFee: creationFee});
        emit CurrencyChanged(quote, minValuation, maxValuation, creationFee);
    }

    /// @notice Disabled: a launchpad with no owner could never change its fee wallet, gate or currencies again.
    /// @dev Overrides OpenZeppelin's `renounceOwnership`, which would otherwise leave the contract ownerless.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // -------------------------------------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------------------------------------

    /// @inheritdoc ISVLaunchpad
    function getLaunch(address token) external view returns (Launch memory) {
        return _launches[token];
    }

    /// @inheritdoc ISVLaunchpad
    /// @dev The key is never stored: the order, the fee and spacing constants and the stored hook give it.
    function poolKeyOf(address token) external view returns (PoolKey memory) {
        Launch memory l = _launchOf(token);
        return _key(token, l.quote, l.hook);
    }

    /// @inheritdoc ISVLaunchpad
    /// @dev Mirrors `Position.update` over the PoolManager's storage, so a collection in the same block returns
    ///      the same numbers. `StateLibrary` reads the v4.0.0 layout; the fork suite proves the deployed manager
    ///      matches.
    function uncollectedFees(address token) external view returns (PendingFees memory f) {
        Launch memory l = _launchOf(token);
        (uint256 fees0, uint256 fees1) = _pendingFees(token, l);
        (f.tokenFees, f.quoteFees) = l.tokenIsCurrency0 ? (fees0, fees1) : (fees1, fees0);
        f.tokenToPayout = f.tokenFees * l.creatorShareBps / BPS;
        f.quoteToPayout = f.quoteFees * l.creatorShareBps / BPS;
        f.tokenToFeeWallet = f.tokenFees - f.tokenToPayout;
        f.quoteToFeeWallet = f.quoteFees - f.quoteToPayout;
    }

    /// @inheritdoc ISVLaunchpad
    /// @dev The same read as SVRouter's Suits check with the opposite failure rule: a raw static call with a gas
    ///      allowance, and the account counts only when the call succeeds, the reply is exactly one word and that
    ///      word is above zero. A codeless gate, a revert, a short reply or a gas-burning gate all mean not
    ///      allowed. A high-level call would not do: decoding a missing or short reply reverts outside try/catch.
    function isAllowedLauncher(address account) public view returns (bool) {
        address gate = launcherGate;
        if (gate == address(0)) return true;
        (bool ok, bytes memory reply) =
            gate.staticcall{gas: GATE_CHECK_GAS}(abi.encodeCall(IERC721.balanceOf, (account)));
        return ok && reply.length == 32 && abi.decode(reply, (uint256)) > 0;
    }

    /// @inheritdoc ISVLaunchpad
    function launchesToday(address account) external view returns (uint256) {
        DayCount memory d = _days[account];
        return d.day == block.timestamp / 1 days ? d.count : 0;
    }

    /// @inheritdoc ISVLaunchpad
    function currency(address quote) external view returns (CurrencyConfig memory) {
        return _currencies[quote];
    }

    /// @inheritdoc ISVLaunchpad
    function owed(address account, address asset) external view returns (uint256) {
        return _owed[account][asset];
    }

    /// @inheritdoc ISVLaunchpad
    /// @dev The form calls this to learn the currency order before the launch.
    function predictToken(address creator, bytes32 salt, string calldata name, string calldata symbol)
        external
        view
        returns (address)
    {
        bytes memory initCode =
            abi.encodePacked(type(SVLaunchToken).creationCode, abi.encode(name, symbol, address(this)));
        // A view off the launch path; plain keccak256 over the init code is clearer than assembly here.
        // forge-lint: disable-next-line(asm-keccak256)
        return Create2.computeAddress(_salt(creator, salt), keccak256(initCode));
    }

    /// @inheritdoc ISVLaunchpad
    /// @dev The same private function `launch` uses, so the form's preview is the launch's opening.
    function openingFor(address token, address quote, uint256 valuation)
        external
        pure
        returns (int24 openTick, uint160 sqrtPriceX96, uint256 snappedValuation)
    {
        return _opening(token, quote, valuation);
    }

    // -------------------------------------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------------------------------------

    /// @dev Spec section 3.2. The square root rounds toward the lower valuation in each order (down when the token
    ///      is currency0, up when it is currency1, where a higher price is a lower valuation), the tick snaps to a
    ///      multiple of 200 in the same direction, and the pool opens at exactly that tick's price, so the snapped
    ///      valuation is at or below the request, exactly, and within one step of 1.0001^200 of it.
    function _opening(address token, address quote, uint256 valuation)
        private
        pure
        returns (int24 openTick, uint160 sqrtPriceX96, uint256 snapped)
    {
        if (valuation < MIN_VALUATION || valuation > MAX_VALUATION) {
            revert ValuationOutOfRange(valuation, MIN_VALUATION, MAX_VALUATION);
        }
        bool tokenFirst = token < quote;
        // 1.
        uint256 sqrtP = tokenFirst
            ? Math.sqrt(FullMath.mulDiv(valuation, 1 << 192, SUPPLY))
            : Math.sqrt(FullMath.mulDivRoundingUp(SUPPLY, 1 << 192, valuation), Math.Rounding.Ceil);
        // 2. Between the two constants sqrtP lies strictly inside TickMath's price range (spec section 3.3), so
        //    it fits 160 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 t = TickMath.getTickAtSqrtPrice(uint160(sqrtP));
        // 3. Solidity's `/` truncates toward zero; negative ticks are handled explicitly.
        // forge-lint: disable-next-line(divide-before-multiply)
        openTick = (t / TICK_SPACING) * TICK_SPACING;
        if (tokenFirst) {
            if (t < 0 && t % TICK_SPACING != 0) openTick -= TICK_SPACING;
        } else {
            if (t > 0 && t % TICK_SPACING != 0) openTick += TICK_SPACING;
            if (TickMath.getSqrtPriceAtTick(openTick) < sqrtP) openTick += TICK_SPACING;
        }
        // 4.
        sqrtPriceX96 = TickMath.getSqrtPriceAtTick(openTick);
        // 5. Rounded down in both orders.
        snapped = tokenFirst
            ? FullMath.mulDiv(FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64), SUPPLY, 1 << 128)
            : FullMath.mulDiv(FullMath.mulDiv(SUPPLY, 1 << 96, sqrtPriceX96), 1 << 96, sqrtPriceX96);
    }

    /// @dev Spec section 3.3, rounded down: liquidity for the whole supply from the opening price to the far end.
    function _liquidityFor(bool tokenIsCurrency0, int24 openTick) private pure returns (uint128) {
        uint160 sqrtOpen = TickMath.getSqrtPriceAtTick(openTick);
        return tokenIsCurrency0
            ? LiquidityAmounts.getLiquidityForAmount0(sqrtOpen, TickMath.getSqrtPriceAtTick(MAX_USABLE_TICK), SUPPLY)
            : LiquidityAmounts.getLiquidityForAmount1(TickMath.getSqrtPriceAtTick(MIN_USABLE_TICK), sqrtOpen, SUPPLY);
    }

    /// @dev The lower address is currency0; fee and spacing are constants; the hook is the launch's.
    function _key(address token, address quote, address hook_) private pure returns (PoolKey memory) {
        (address c0, address c1) = token < quote ? (token, quote) : (quote, token);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook_)
        });
    }

    /// @dev Spec section 3.3: from the opening tick to the top when the token is currency0, from the bottom to
    ///      the opening tick when it is currency1.
    function _range(bool tokenIsCurrency0, int24 openTick) private pure returns (int24 tickLower, int24 tickUpper) {
        return tokenIsCurrency0 ? (openTick, MAX_USABLE_TICK) : (MIN_USABLE_TICK, openTick);
    }

    /// @dev A launch exists when its creator is non-zero (spec section 4.4).
    function _launchOf(address token) private view returns (Launch memory l) {
        l = _launches[token];
        if (l.creator == address(0)) revert UnknownLaunch();
    }

    /// @dev The fees `Position.update` would credit now, in currency order.
    function _pendingFees(address token, Launch memory l) private view returns (uint256 fees0, uint256 fees1) {
        (int24 tickLower, int24 tickUpper) = _range(l.tokenIsCurrency0, l.openTick);
        PoolId id = _key(token, l.quote, l.hook).toId();
        (uint128 liquidity, uint256 last0, uint256 last1) =
            POOL_MANAGER.getPositionInfo(id, address(this), tickLower, tickUpper, bytes32(0));
        (uint256 inside0, uint256 inside1) = POOL_MANAGER.getFeeGrowthInside(id, tickLower, tickUpper);
        unchecked {
            // Wrap-around is expected, as in Position.update.
            fees0 = FullMath.mulDiv(inside0 - last0, liquidity, FixedPoint128.Q128);
            fees1 = FullMath.mulDiv(inside1 - last1, liquidity, FixedPoint128.Q128);
        }
    }

    /// @dev Fees sent to this contract or to the PoolManager could never be spent (spec section 4.5 step 6).
    function _checkPayout(address account) private view {
        if (account == address(this) || account == address(POOL_MANAGER)) revert BadPayout();
    }

    /// @dev Spec section 4.1: the caller is mixed into the CREATE2 salt, so nobody can land a token at another
    ///      creator's predicted address.
    function _salt(address creator, bytes32 salt) private pure returns (bytes32) {
        // Two words once per launch; the assembly form would save a few gas and cost readability.
        // forge-lint: disable-next-line(asm-keccak256)
        return keccak256(abi.encode(creator, salt));
    }

    /// @dev Reverts with `ZeroAddress()` for the zero address, otherwise returns the input unchanged. Used in the
    ///      constructor's `Ownable` argument, which is evaluated before any base constructor runs.
    function _nonZero(address account) private pure returns (address) {
        if (account == address(0)) revert ZeroAddress();
        return account;
    }
}
