// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

/// @title ISVLaunchpad
/// @notice The MaxLong Markets instant launchpad on Robinhood Chain: one transaction deploys a token, opens its
///         Uniswap v4 pool at the creator's snapped valuation, locks the whole supply in one position the launchpad
///         owns and can never decrease, and optionally buys the creator a first allocation. Trading fees are
///         collected by anyone and split between the launch's payout address and the fee wallet.
/// @dev Spec: docs/superpowers/specs/2026-09-28-instant-launchpad-design.md (frontend repo), section 4.2. Names,
///      types and parameter order follow that section; the frontend's ABI is transcribed from this file.
interface ISVLaunchpad {
    /// @notice What the creator submits to `launch`.
    struct LaunchParams {
        string name; // 1 to 32 bytes
        string symbol; // 1 to 11 bytes
        string metadataUri; // 0 to 128 bytes; the app passes ipfs://<metadata CID>
        address quote; // an allowed currency
        uint256 valuation; // requested opening valuation: raw quote units for the whole supply
        uint256 firstBuy; // gross quote for the creator's first buy, router fee included as in SVRouter; 0 = none
        uint256 minFirstBuyTokens; // floor on the first buy's tokens; the app sets it from its preview minus a tolerance
        address payout; // receives the creator's fee share; zero means msg.sender; never this contract or the PoolManager
        bytes32 salt; // picked by the app; CREATE2 salt is keccak256(abi.encode(msg.sender, salt))
        uint256 deadline; // unix seconds; reverts Expired after it
    }

    /// @notice One launch as stored, keyed by its token; five storage slots.
    struct Launch {
        address creator;
        uint64 launchedAt;
        uint16 creatorShareBps;
        bool tokenIsCurrency0;
        address payout;
        int24 openTick;
        address quote;
        address hook;
        uint128 liquidity;
    }

    /// @notice The launch bounds of one quote currency.
    struct CurrencyConfig {
        uint256 minValuation; // raw quote units for the whole supply; 0 together with max = 0 means not allowed
        uint256 maxValuation;
        uint256 creationFee; // raw quote units, pulled through Permit2; 0 today
    }

    /// @notice The `Launched` event's payload, one tuple to keep the legacy code generator within stack.
    struct LaunchedData {
        bytes32 poolId;
        address payout;
        address hook;
        bool tokenIsCurrency0;
        int24 openTick;
        uint256 openingValuation; // V', snapped
        uint128 liquidity;
        uint256 tokensInPool; // what the pool took; S minus the burned dust
        uint256 firstBuyIn; // net quote swapped into the pool: firstBuy minus routerFee; 0 without a first buy
        uint256 firstBuyTokens; // tokens the first buy received
        uint256 routerFee; // quote sent to the fee wallet out of the first buy; firstBuyIn + routerFee is the gross
        uint256 creationFee; // quote sent to the fee wallet as the creation fee
        uint16 creatorShareBps;
        string name;
        string symbol;
        string metadataUri;
    }

    /// @notice Fees accrued to a launch's position and not yet collected, in token and quote terms, not
    ///         currency0 and currency1, with the split a collection would make now.
    struct PendingFees {
        uint256 tokenFees;
        uint256 quoteFees;
        uint256 tokenToPayout;
        uint256 quoteToPayout;
        uint256 tokenToFeeWallet;
        uint256 quoteToFeeWallet;
    }

    // -------------------------------------------------------------------------------------------------------
    // Activity events, the three the reader indexes
    // -------------------------------------------------------------------------------------------------------

    /// @notice A token was launched: deployed, pool initialised, supply placed, first buy made if any.
    event Launched(address indexed token, address indexed creator, address indexed quote, LaunchedData data);
    /// @notice Fees were collected and split; the measured amounts, whether each share was delivered or credited.
    event FeesCollected(
        address indexed token,
        address indexed payout,
        uint256 tokenFees,
        uint256 quoteFees,
        uint256 tokenToPayout,
        uint256 quoteToPayout
    );
    /// @notice A launch's payout address moved from `previous` to `payout`.
    event PayoutChanged(address indexed token, address indexed previous, address indexed payout);

    // -------------------------------------------------------------------------------------------------------
    // Setting events: every setter emits one, the constructor emits each once (no CurrencyChanged)
    // -------------------------------------------------------------------------------------------------------

    /// @notice The fee wallet was set.
    event FeeWalletChanged(address indexed wallet);
    /// @notice The router fee on first buys was set, in basis points.
    event RouterFeeChanged(uint16 bps);
    /// @notice The payout's share of collected fees for later launches was set, in basis points.
    event CreatorShareChanged(uint16 bps);
    /// @notice The first-buy cap was set, in basis points of the supply.
    event FirstBuyCapChanged(uint16 bps);
    /// @notice The launches allowed per wallet per UTC day were set; 0 stops launches.
    event DailyLaunchLimitChanged(uint8 limit);
    /// @notice The ERC-721 whose holders may launch was set; zero means anyone.
    event LauncherGateChanged(address indexed gate);
    /// @notice The hook of later launches' pools was set; zero means hookless.
    event HookChanged(address indexed hook);
    /// @notice A quote currency was allowed, re-bounded or disallowed (all zeros).
    event CurrencyChanged(address indexed quote, uint256 minValuation, uint256 maxValuation, uint256 creationFee);

    // -------------------------------------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------------------------------------

    /// @notice An address that must be non-zero is zero.
    error ZeroAddress();
    /// @notice `renounceOwnership` is disabled: the launchpad must always have an owner.
    error RenounceDisabled();
    /// @notice The launch's deadline has passed.
    error Expired();
    /// @notice A launcher gate is set and the caller holds none of it, or the gate could not be read.
    error NotAllowedToLaunch();
    /// @notice The caller has used today's launches, or launches are stopped.
    error DailyLimitReached();
    /// @notice The name is empty or longer than 32 bytes.
    error BadName();
    /// @notice The symbol is empty or longer than 11 bytes.
    error BadSymbol();
    /// @notice The metadata URI is longer than 128 bytes.
    error UriTooLong();
    /// @notice The quote currency is not allowed.
    error CurrencyNotAllowed();
    /// @notice The requested valuation is outside `[min, max]`.
    error ValuationOutOfRange(uint256 valuation, uint256 min, uint256 max);
    /// @notice The Permit2 message is for another token or too small, or the pull delivered another amount.
    error PermitMismatch();
    /// @notice The first buy would take more than the cap.
    error FirstBuyTooLarge(uint256 tokensOut, uint256 cap);
    /// @notice The first buy would take fewer tokens than the creator's floor.
    error FirstBuyTooSmall(uint256 tokensOut, uint256 min);
    /// @notice The payout or claim recipient can never spend what it would receive.
    error BadPayout();
    /// @notice The router fee is above `MAX_ROUTER_FEE_BPS`.
    error FeeTooHigh();
    /// @notice A share or a cap is above 10,000 basis points.
    error BpsTooHigh();
    /// @notice Currency bounds outside `MIN_VALUATION <= min <= max <= MAX_VALUATION`.
    error BoundsOutOfRange();
    /// @notice The hook has no code, is not a valid static-fee hook, or carries a refused flag.
    error HookNotAllowed();
    /// @notice No launch exists for this token.
    error UnknownLaunch();
    /// @notice The caller is not the launch's current payout address.
    error NotPayout();
    /// @notice The position has accrued nothing since the last collection.
    error NothingToCollect();
    /// @notice The caller has no owed balance in this currency.
    error NothingOwed();
    /// @notice `unlockCallback` was called by someone other than the PoolManager.
    error NotPoolManager();
    /// @notice `unlockCallback` arrived while the launchpad had no unlock in flight.
    error UnexpectedCallback();

    // -------------------------------------------------------------------------------------------------------
    // Anyone
    // -------------------------------------------------------------------------------------------------------

    /// @notice Launch a token: deploy it, open its pool at the snapped valuation, place the whole supply, and buy
    ///         the creator a first allocation when `p.firstBuy > 0`. The permit and signature are ignored when
    ///         `p.firstBuy` plus the creation fee is zero.
    /// @return token The new token.
    function launch(
        LaunchParams calldata p,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) external returns (address token);

    /// @notice The PoolManager only, during the launchpad's own unlock. Returns abi.encode(LaunchResult) for
    ///         Action.Launch and abi.encode(uint256 tokenFees, uint256 quoteFees) for Action.Collect.
    function unlockCallback(bytes calldata data) external returns (bytes memory);

    // -------------------------------------------------------------------------------------------------------
    // Owner only
    // -------------------------------------------------------------------------------------------------------

    /// @notice Owner only. The wallet that receives the router fee, the creation fee and the platform's share of
    ///         collected fees; non-zero, never this contract or the PoolManager. Read at every collection, so a
    ///         change applies to every launch.
    function setFeeWallet(address wallet) external;

    /// @notice Owner only. The router fee taken out of the first buy, in basis points; at most 50.
    function setRouterFee(uint16 bps) external;

    /// @notice Owner only. The payout's share of collected fees, fixed into each launch at launch time.
    function setCreatorShare(uint16 bps) external;

    /// @notice Owner only. The first buy's cap in basis points of the supply; 0 blocks any first buy.
    function setFirstBuyCap(uint16 bps) external;

    /// @notice Owner only. Launches per wallet per UTC day; 0 stops new launches and is the only pause.
    function setDailyLaunchLimit(uint8 limit) external;

    /// @notice Owner only. The ERC-721 whose holders may launch; zero means anyone.
    function setLauncherGate(address gate) external;

    /// @notice Owner only. The hook of later launches' pools: zero, or a hook as spec section 4.9 requires.
    function setHook(address hook) external;

    /// @notice Owner only. Allow a quote currency with valuation bounds and a creation fee; `maxValuation == 0`
    ///         disallows it and clears the row.
    function setCurrency(address quote, uint256 minValuation, uint256 maxValuation, uint256 creationFee) external;

    // -------------------------------------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------------------------------------

    /// @notice One launch as stored; an empty struct (zero `creator`) when the token was not launched here.
    function getLaunch(address token) external view returns (Launch memory);

    /// @notice The pool key of a launch; reverts `UnknownLaunch` for a token not launched here.
    function poolKeyOf(address token) external view returns (PoolKey memory);

    /// @notice The token address a launch by `creator` with this salt, name and symbol would deploy.
    function predictToken(address creator, bytes32 salt, string calldata name, string calldata symbol)
        external
        view
        returns (address);

    /// @notice The snapped opening of spec section 3.2 for a token and quote pair at a requested valuation.
    function openingFor(address token, address quote, uint256 valuation)
        external
        pure
        returns (int24 openTick, uint160 sqrtPriceX96, uint256 snappedValuation);

    /// @notice Whether `account` may launch under the current gate, by the fail-closed rule of section 4.7.
    function isAllowedLauncher(address account) external view returns (bool);

    /// @notice Launches `account` made on the current UTC day.
    function launchesToday(address account) external view returns (uint256);

    /// @notice The bounds and creation fee of a quote currency; all zeros when not allowed.
    function currency(address quote) external view returns (CurrencyConfig memory);

    /// @notice How many launches have been made.
    function launchCount() external view returns (uint256);

    /// @notice The wallet that receives the router fee, the creation fee and the platform's fee share.
    function feeWallet() external view returns (address);

    /// @notice The router fee on first buys, in basis points.
    function routerFeeBps() external view returns (uint16);

    /// @notice The payout's share of collected fees for launches made from now on, in basis points.
    function creatorShareBps() external view returns (uint16);

    /// @notice The first buy's cap in basis points of the supply.
    function firstBuyCapBps() external view returns (uint16);

    /// @notice Launches per wallet per UTC day.
    function dailyLaunchLimit() external view returns (uint8);

    /// @notice The ERC-721 whose holders may launch; zero means anyone.
    function launcherGate() external view returns (address);

    /// @notice The hook later launches' pools get; zero means hookless.
    function hook() external view returns (address);

    /// @notice The Uniswap v4 PoolManager.
    // The name is fixed by the spec (section 4.2).
    // forge-lint: disable-next-line(mixed-case-function)
    function POOL_MANAGER() external view returns (IPoolManager);

    /// @notice Permit2, which pulls the first buy and the creation fee against the creator's signature.
    // The name is fixed by the spec (section 4.2).
    // forge-lint: disable-next-line(mixed-case-function)
    function PERMIT2() external view returns (ISignatureTransfer);
}
