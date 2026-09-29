// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
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
    function currency(address quote) external view returns (CurrencyConfig memory) {
        return _currencies[quote];
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
