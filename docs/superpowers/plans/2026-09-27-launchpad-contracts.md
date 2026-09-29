# Launchpad Contracts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `SVLaunchToken` and `SVLaunchpad` in `SuitVenturesMarket-contracts` per spec section 4: a fixed-price raise in an admin-enabled quote asset that, on success, deploys the token, seeds a locked full-range Uniswap v4 pool at the presale price in one transaction, and on failure refunds every contributor in full; with unit, fuzz, invariant and fork suites and a deploy script.

**Architecture:** One singleton `src/SVLaunchpad.sol` (OpenZeppelin v5 `Ownable2Step` + `ReentrancyGuard`, Permit2 `ISignatureTransfer`, v4-core `IPoolManager`/`IUnlockCallback`) holds every raise, deploys `src/SVLaunchToken.sol` (OZ `ERC20` + `ERC20Burnable`) by CREATE2 at launch, initialises the pool and mints one full-range position it owns and never decreases. `src/libraries/LaunchMath.sol` holds the presale-price formula shared by the contract and the deploy script. Unit tests run offline on a `PoolManager` deployed from v4-core's `Deployers` with the real Permit2 etched; fork tests run against Robinhood Chain when `ROBINHOOD_RPC_URL` is set.

**Tech Stack:** Foundry (forge 1.4.0-nightly on the build machine), Solidity 0.8.26 on Cancun, OpenZeppelin Contracts v5.7.0, Uniswap v4-core v4.0.0, v4-periphery `3231810e` (only `LiquidityAmounts` and interfaces), permit2 `cc56ad0f`, forge-std v1.9.7; the existing `SVRouter` and its fork harness for the fork swap.

**Spec:** `/Users/kobs/Desktop/SuitVenturesMarket/SuitVenturesMarket-frontend/docs/superpowers/specs/2026-09-27-launchpad-design.md` (binding; this plan covers its section 4, items 4.1 to 4.5. Sections 5 to 8 belong to the frontend plan; the only thing shared with it is the event and error ABI of section 4.2, reproduced exactly in Task 1).

## Global Constraints

- Repo: `/Users/kobs/Desktop/SuitVenturesMarket/SuitVenturesMarket-contracts` (own git repository, branch `main`, no remote). Every path below is relative to it. Work on a branch `feat/launchpad` created from `main`.
- Spec section 4 conventions, verbatim: "**Conventions**, all taken from the router: solc 0.8.26, `cancun`, optimizer as in `foundry.toml`, no `via_ir`; OpenZeppelin v5 `Ownable2Step` with `renounceOwnership` reverting `RenounceDisabled`, `ReentrancyGuard`, `SafeERC20`; errors and events declared in the interface `ISVLaunchpad`; setter events named `<Thing>Changed` and emitted at construction as well; fees in bps over 10,000; the single-token Permit2 `permitTransferFrom` overload; the gate check as a `staticcall` with a 100,000 gas stipend like the router's Suits check. Dependencies used: v4-core v4.0.0 (`IPoolManager`, `IUnlockCallback`, `PoolKey`, `PoolId`, `Currency`, `BalanceDelta`, `TickMath`, `FullMath`, `StateLibrary`), v4-periphery's `LiquidityAmounts` (compiles against the pinned core), OpenZeppelin `ERC20`, `ERC20Burnable`, `Math`. `PositionManager` is not used and does not compile against the pinned core. One build change: the remapping `solmate/=lib/v4-core/lib/solmate/` so tests can deploy a local `PoolManager`."
- Spec section 4.2, "**Events**, every one emitted by the launchpad, declared in `ISVLaunchpad`" and "**Errors**, in the interface": every event and error lives in `src/interfaces/ISVLaunchpad.sol` and nowhere else; the contract declares none of its own.
- Spec section 4.2 constants, verbatim:

  | Name | Value |
  |---|---|
  | `SUPPLY` | 1,000,000,000 × 10^18 |
  | `SALE_BPS` / `POOL_BPS` / `CREATOR_BPS` | 4500 / 4500 / 1000 |
  | `CREATOR_VESTING` | 90 days |
  | `WALLET_CAP_BPS` | 1000 (10 % of target) |
  | `MIN_FLOOR_BPS` | 5000 |
  | `MIN_DURATION` / `MAX_DURATION` | 1 hour / 30 days |
  | `MAX_START_DELAY` | 14 days |
  | `STALL_GRACE` | 7 days |
  | `MAX_FEE_BPS` | 500 |
  | `POOL_LP_FEE` | 10000 (1 %) |
  | `TICK_SPACING` | 200 |
  | `TICK_LOWER` / `TICK_UPPER` | −887200 / 887200, the full range at spacing 200 |

- Spec section 4.2 **Function signatures** block (added 27 Sep): the names, parameters and return types of every external function are fixed there, "declared in `ISVLaunchpad`, the single source for both the contracts and the frontend ABI". They are used verbatim in every task; in particular the views are `getRaise(uint256) returns (Raise memory)`, `contributed(uint256 id, address wallet)`, `claimed(uint256 id, address wallet)`, `nextId()`, `feeBps()`, `feeWallet()`, `launcherGate()`, `creatorFeeShareBps()`, `creationOpen()`, `quoteLimits(address asset) returns (uint256 minTarget, uint256 maxTarget)`, `poolKey(uint256) returns (PoolKey memory)`, `poolManager() returns (IPoolManager)`, `permit2() returns (ISignatureTransfer)`, and `CreateParams` is `{name, symbol, image, website, x, telegram, quote, target, floor, start (uint64), duration (uint64)}` in that order. Spec 4.2 `create` step 2 (amended 27 Sep): "`start == 0` means `block.timestamp`, otherwise `start` in `[now, now + 14 days]`".
- Spec section 4.3 (amended 27 Sep): "Because the token's side of the pair is unknown until its address exists at launch, `create` computes the price in both currency orders and rejects the raise (`TargetOutOfRange`) if either would overflow or fall outside the bounds, so a raise can never be created that cannot launch."
- Spec section 4.4 naming rules, verbatim: "Unit, in the router's style (`test_<snake_case_sentence>`, `testFuzz_`, plain-English assertion messages), on a `PoolManager` deployed inside the test with the v4-core `Deployers` helpers, real Permit2 etched as the router tests do, mock ERC-20 quotes at 18 and 6 decimals, and the launch token landing on both sides of the quote address so both currency orders are covered". Fork tests: "through the existing fork harness (`ROBINHOOD_RPC_URL`, skipped when unset, pinned block)".
- Repo conventions from the router (research notes section 2): named imports, one symbol set per line, OZ first, then v4-core, v4-periphery, permit2, then local; `/// @inheritdoc` plus a `/// @dev` that says why; `// ----` section banners; constants and immutables `UPPER_SNAKE`, storage `camelCase`, private helpers `_camelCase`, constructor parameters with a trailing underscore; lint suppressions justified one line above (`// forge-lint: disable-next-line(...)`); `abi.encodeCall` for selectors in `src/`; a zero amount is never transferred (some tokens revert on zero-value transfers); no real key, RPC key or wallet address in the repo, `vm.addr` keys in tests, `.env.example` placeholders only.
- Size fact (measured 27 Sep 2026 in a scratch build with this repo's `lib/` and profile): `SVLaunchpad` compiles to 26,459 runtime bytes at `optimizer_runs = 1_000_000` because it embeds `SVLaunchToken`'s init code for its CREATE2 deployment, over the EIP-170 limit of 24,576; at 200 runs it is 20,522 bytes. Task 2 therefore adds a per-file compiler restriction (`compilation_restrictions`, forge 1.4) that compiles `src/SVLaunch*.sol` at 200 runs and leaves every other file, `SVRouter` included, at 1,000,000: the router's runtime size is unchanged (7,647 bytes) while its metadata hash changes, because the remapping list is part of solc's metadata; the deployed router's exact verification input is preserved in the untracked `docs/verify/SVRouter.standard-input.json`. Spec 4.2 "Contract size" requires exactly this restriction; the README records it.
- `fs_permissions = []` stays: nothing reads or writes files. The deploy script takes `QUOTES_JSON` as the JSON text itself, not a path.
- Coverage bar: `forge coverage --report summary` reports 100 % lines, statements, branches and functions for `src/SVLaunchpad.sol`, `src/SVLaunchToken.sol` and `src/libraries/LaunchMath.sol` from the unit suite alone (no RPC). Fork tests are skipped, not failed, without `ROBINHOOD_RPC_URL`. forge's test EVM does not enforce EIP-170 (verified), so the unoptimised coverage build deploys.
- `forge fmt` is canonical: after writing or editing any `.sol` file, run `forge fmt` on it before `forge fmt --check`; the plan's code is written to its 120-column limit, and where the formatter's line-breaking differs from the plan's, the formatter wins.
- Gates after every task: `forge fmt --check`, `forge build --sizes` (SVLaunchpad under 24,576 bytes), `forge lint` (no findings in `src/` and `script/`), `forge test` (unit; the fork files report skipped), `forge coverage --report summary` from Task 2 on, and `ROBINHOOD_RPC_URL=<url> forge test --match-path 'test/fork/*' -vv` when the task touches fork tests.
- Commit after every task with the trailer:
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_016tofArVnM9erCZUwPku467
  ```
- Model routing (`~/.claude/rules/subagent-models.md`): execution and test writing by Sonnet, review and drift checks by Opus.

## File structure

| Path | Responsibility |
|---|---|
| `remappings.txt` | + `solmate/=lib/v4-core/lib/solmate/` (Task 1) |
| `foundry.toml` | + the per-file optimizer restriction for `src/SVLaunch*.sol` (Task 2); `[fuzz]` and `[invariant]` sections (Task 7) |
| `src/interfaces/ISVLaunchpad.sol` | `CreateParams`, `Raise`, `Quote`, every event and error (Task 1), the external functions (Tasks 2 to 6) |
| `src/SVLaunchToken.sol` | OZ `ERC20` + `ERC20Burnable`, whole supply minted to the launchpad (Task 1) |
| `src/libraries/LaunchMath.sol` | `sqrtPriceX96For(amount0, amount1)`: the spec 4.3 formula with the overflow and lower-bound checks, shared by contract and script (Task 2) |
| `src/SVLaunchpad.sol` | the singleton: settings and `create` (Task 2), `contribute` (Task 3), launch (Task 4), claims and refunds (Task 5), fee collection (Task 6) |
| `test/mocks/RevertingPoolManager.sol` | a PoolManager whose every call reverts, for the stall valve (Task 5) |
| `test/utils/LaunchMathHarness.sol` | exposes the library as an external call so tests can `expectRevert` (Task 2) |
| `test/utils/SVLaunchpadHarness.sol` | `SVLaunchpad` plus `exposed_setRaised`, for states the contract never produces (Task 3) |
| `test/unit/SVLaunchToken.t.sol` | token, interface ABI hashes, the remapping proof (Task 1) |
| `test/unit/LaunchMath.t.sol` | the formula in both orders, the research's worked values, the bounds (Task 2) |
| `test/unit/SVLaunchpad.t.sol` | the shared fixture `SVLaunchpadTestBase` + `SVLaunchpadTest`: constructor, settings, ownership, `create` (Task 2); fixture helpers grow in Tasks 3, 4, 6 |
| `test/unit/SVLaunchpad.contribute.t.sol` | caps, trimming, window, permit checks (Task 3) |
| `test/unit/SVLaunchpad.launch.t.sol` | both currency orders, both quote decimals, floor path, burn and dust accounting, callback guards, launch gas (Task 4) |
| `test/unit/SVLaunchpad.claims.t.sol` | claims, creator vesting, refunds, stall valve, `setPayout` (Task 5) |
| `test/unit/SVLaunchpad.fees.t.sol` | swaps through the core's test router, the poke, the split (Task 6) |
| `test/unit/SVLaunchpad.fuzz.t.sol`, `test/unit/SVLaunchpad.invariant.t.sol` | spec 4.4 fuzz and invariant suites (Task 7) |
| `test/fork/SVLaunchpadFork.t.sol` | real PoolManager, Permit2, USDG and NVDA, swap through a fresh `SVRouter` (Task 8) |
| `script/DeployLaunchpad.s.sol`, `test/unit/DeployLaunchpad.t.sol` | deploy from env vars and `QUOTES_JSON`; the parsing and checks unit-tested (Task 9) |
| `README.md`, `.env.example`, `.gas-snapshot`, `docs/verify/` (untracked) | docs, env names, gas snapshot, verification artefacts (Task 9) |

---

### Task 1: The `solmate` remapping, `ISVLaunchpad` (structs, events, errors) and `SVLaunchToken`

**Files:**
- Modify: `remappings.txt` (append one line)
- Create: `src/interfaces/ISVLaunchpad.sol`
- Create: `src/SVLaunchToken.sol`
- Test: `test/unit/SVLaunchToken.t.sol`

**Interfaces:**
- Consumes: OZ `ERC20(string name_, string symbol_)`, `ERC20Burnable.burn(uint256)`; v4-core `PoolManager(address initialOwner)` (needs `solmate/src/auth/Owned.sol`, hence the remapping); Permit2 `ISignatureTransfer.PermitTransferFrom`.
- Produces: `interface ISVLaunchpad` with `struct CreateParams {string name; string symbol; string image; string website; string x; string telegram; address quote; uint256 target; uint256 floor; uint64 start; uint64 duration;}`, `struct Raise {...18 fields as spec 4.2...}`, `struct Quote {uint256 minTarget; uint256 maxTarget;}`, the 16 events and 26 errors of spec 4.2 (no functions yet; Tasks 2 to 6 add them); `contract SVLaunchToken is ERC20, ERC20Burnable` with `constructor(string memory name_, string memory symbol_, uint256 supply, address recipient)`.

- [ ] **Step 1: Add the remapping**

Append to `remappings.txt` so it reads:

```
forge-std/=lib/forge-std/src/
@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/
@uniswap/v4-core/=lib/v4-core/
@uniswap/v4-periphery/=lib/v4-periphery/
@uniswap/universal-router/=lib/universal-router/
permit2/=lib/permit2/
solmate/=lib/v4-core/lib/solmate/
```

- [ ] **Step 2: Write the failing tests**

`test/unit/SVLaunchToken.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SVLaunchToken} from "../../src/SVLaunchToken.sol";
import {ISVLaunchpad} from "../../src/interfaces/ISVLaunchpad.sol";

/// @notice The fixed-supply launch token (spec section 4.1), the interface's event ABI (spec section 4.2), and
///         the `solmate/` remapping that lets the unit suite deploy a local PoolManager.
contract SVLaunchTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    address internal recipient;

    function setUp() public {
        recipient = makeAddr("launchpad");
    }

    function test_constructor_mints_the_whole_supply_to_the_recipient() public {
        SVLaunchToken token = new SVLaunchToken("Launch Token", "LT", SUPPLY, recipient);
        assertEq(token.name(), "Launch Token", "name");
        assertEq(token.symbol(), "LT", "symbol");
        assertEq(token.decimals(), 18, "18 decimals");
        assertEq(token.totalSupply(), SUPPLY, "the whole supply exists");
        assertEq(token.balanceOf(recipient), SUPPLY, "and the recipient holds all of it");
    }

    function test_burn_reduces_the_supply_and_the_holder_balance() public {
        SVLaunchToken token = new SVLaunchToken("Launch Token", "LT", SUPPLY, recipient);
        vm.prank(recipient);
        token.burn(1e18);
        assertEq(token.totalSupply(), SUPPLY - 1e18, "supply after burn");
        assertEq(token.balanceOf(recipient), SUPPLY - 1e18, "balance after burn");
    }

    /// @dev No owner, no mint, no pause: a call to any such selector finds no function and no fallback.
    function test_the_token_has_no_mint_owner_or_pause_entry_point() public {
        SVLaunchToken token = new SVLaunchToken("Launch Token", "LT", SUPPLY, recipient);
        bytes4[4] memory forbidden = [
            bytes4(keccak256("mint(address,uint256)")),
            bytes4(keccak256("owner()")),
            bytes4(keccak256("pause()")),
            bytes4(keccak256("transferOwnership(address)"))
        ];
        for (uint256 i = 0; i < forbidden.length; i++) {
            (bool ok,) = address(token).call(abi.encodePacked(forbidden[i], abi.encode(recipient, uint256(1))));
            assertFalse(ok, "the token answered a selector it must not have");
        }
    }

    /// @dev The remapping added in this task: without `solmate/`, `PoolManager.sol` cannot resolve `Owned.sol`.
    function test_a_local_pool_manager_deploys_with_the_solmate_remapping() public {
        IPoolManager manager = new PoolManager(address(this));
        assertGt(address(manager).code.length, 0, "the PoolManager compiled and deployed");
    }

    /// @dev The event ABI the frontend indexes: topic hashes computed with `cast keccak` from the spec's
    ///      signatures. A wrong type, order or name in the interface changes the hash and fails here.
    function test_the_event_abi_matches_the_spec() public pure {
        assertEq(
            ISVLaunchpad.RaiseCreated.selector,
            0x79b981548b1db736b4b2e3aef35dc57e03c9063a5daca282726dc98d3a736582,
            "RaiseCreated(uint256,address,address,uint256,uint256,uint64,uint64,uint256)"
        );
        assertEq(
            ISVLaunchpad.RaiseMetadata.selector,
            0x46d93641bdfdca019a0fceecc748f99e642f411fbba37ef2672344d6a1f23028,
            "RaiseMetadata(uint256,string,string,string,string,string,string)"
        );
        assertEq(
            ISVLaunchpad.Contributed.selector,
            0xdcfa71ee125a676f843733d9d39dce2c918ecf9e92f96db4f24bdb5244ed68a0,
            "Contributed(uint256,address,uint256,uint256)"
        );
        assertEq(
            ISVLaunchpad.Finalized.selector,
            0x327d74ab0e32448306a572330cdafb7a8e1c0531c06e64f8a690a97640c3c949,
            "Finalized(uint256,address,bytes32,uint160,uint256,uint256,uint256,uint256,uint256,uint128)"
        );
        assertEq(
            ISVLaunchpad.Closed.selector,
            0xbb1c869dafbabf53b7b5a50e7864066365b4c5d1bcfa0220f75cc2a2acfb44f6,
            "Closed(uint256,uint256)"
        );
        assertEq(
            ISVLaunchpad.FeesCollected.selector,
            0x60335fc6da5dde7dc66197a635e02eb0dafc452a299f77200b64358c94cdb616,
            "FeesCollected(uint256,uint256,uint256,uint256,uint256)"
        );
        assertEq(
            ISVLaunchpad.QuoteChanged.selector,
            0x9565c66050fce9a1053f16b3a63a0d008b3596e8f18793f2d303792661f99047,
            "QuoteChanged(address,uint256,uint256)"
        );
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `forge test --match-path test/unit/SVLaunchToken.t.sol`
Expected: compilation fails with `Source "../../src/SVLaunchToken.sol" not found` (the files do not exist yet).

- [ ] **Step 4: Write the interface**

`src/interfaces/ISVLaunchpad.sol` (the functions are added by Tasks 2 to 6; this file ends after the errors for now):

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

/// @title ISVLaunchpad
/// @notice The LongMarkets token launchpad on Robinhood Chain: a fixed-price raise in an admin-enabled quote
///         asset that, on success, deploys the token, seeds a locked full-range Uniswap v4 pool at the presale
///         price in one transaction, and on failure refunds every contributor in full.
/// @dev Spec: docs/superpowers/specs/2026-09-27-launchpad-design.md (frontend repo), section 4.2. Every event
///      and error the launchpad emits is declared here. The contract also implements v4-core's
///      `IUnlockCallback`, which is not repeated here.
interface ISVLaunchpad {
    /// @notice What the creator submits to `create`.
    struct CreateParams {
        string name; // token name, 1 to 32 bytes
        string symbol; // token symbol, 1 to 11 bytes
        string image; // an https URL or empty, at most 256 bytes; kept off-chain from the event only
        string website; // at most 256 bytes
        string x; // at most 256 bytes
        string telegram; // at most 256 bytes
        address quote; // the asset raised in; must be enabled by `setQuote`
        uint256 target; // raw quote units, within the quote's [minTarget, maxTarget]
        uint256 floor; // raw quote units, between target * 5000 / 10000 and target
        uint64 start; // unix seconds, in [now, now + 14 days]; 0 means now
        uint64 duration; // seconds, in [1 hour, 30 days]
    }

    /// @notice One raise as stored; `token`, `sqrtPriceX96`, `liquidity` and `launchedAt` are zero until launch.
    struct Raise {
        address creator;
        address payout; // receives creator tokens and the creator's fee share; creator may change it
        address quote;
        address token; // zero until launch
        uint256 target;
        uint256 floor;
        uint64 start;
        uint64 deadline;
        uint256 raised;
        uint256 saleTokens; // SUPPLY * 4500 / 10000, fixed at creation
        uint256 creatorClaimed;
        uint160 sqrtPriceX96; // set at launch
        uint128 liquidity; // set at launch
        uint64 launchedAt;
        uint16 creatorFeeShareBps;
        uint8 status; // 1 Open, 2 Launched, 3 Closed
        string name;
        string symbol;
    }

    /// @notice The raise bounds of one quote asset; `maxTarget == 0` means the asset is not enabled.
    struct Quote {
        uint256 minTarget;
        uint256 maxTarget;
    }

    // -------------------------------------------------------------------------------------------------------
    // Events (spec section 4.2, verbatim)
    // -------------------------------------------------------------------------------------------------------

    /// @notice A raise was created; `RaiseMetadata` follows in the same transaction with the text fields.
    event RaiseCreated(
        uint256 indexed id,
        address indexed creator,
        address indexed quote,
        uint256 target,
        uint256 floor,
        uint64 start,
        uint64 deadline,
        uint256 saleTokens
    );
    /// @notice The text fields of a raise, emitted once at creation.
    event RaiseMetadata(
        uint256 indexed id, string name, string symbol, string image, string website, string x, string telegram
    );
    /// @notice `wallet` contributed `amount` (after trimming) and the raise now holds `raised`.
    event Contributed(uint256 indexed id, address indexed wallet, uint256 amount, uint256 raised);
    /// @notice The raise launched: token deployed, pool initialised at `sqrtPriceX96`, position minted.
    event Finalized(
        uint256 indexed id,
        address indexed token,
        bytes32 indexed poolId,
        uint160 sqrtPriceX96,
        uint256 raised,
        uint256 fee,
        uint256 quoteToPool,
        uint256 tokensToPool,
        uint256 tokensBurned,
        uint128 liquidity
    );
    /// @notice The raise closed without launching; refunds are open.
    event Closed(uint256 indexed id, uint256 raised);
    /// @notice `wallet` took its contribution back.
    event Refunded(uint256 indexed id, address indexed wallet, uint256 amount);
    /// @notice `wallet` claimed its tokens after launch.
    event Claimed(uint256 indexed id, address indexed wallet, uint256 amount);
    /// @notice The creator's vested tokens were sent to `payout`.
    event CreatorClaimed(uint256 indexed id, address indexed payout, uint256 amount);
    /// @notice Accrued pool fees were collected and split, in pool currency order (0, 1).
    event FeesCollected(uint256 indexed id, uint256 creator0, uint256 creator1, uint256 platform0, uint256 platform1);
    /// @notice The creator changed the raise's payout address.
    event PayoutChanged(uint256 indexed id, address payout);
    /// @notice The launch fee was set (also emitted once at deploy with the initial value).
    event FeeChanged(uint16 bps);
    /// @notice The fee wallet was set (also emitted once at deploy with the initial value).
    event FeeWalletChanged(address wallet);
    /// @notice A quote asset was enabled, re-bounded or disabled (`maxTarget == 0`).
    event QuoteChanged(address indexed asset, uint256 minTarget, uint256 maxTarget);
    /// @notice The launcher gate was set; zero means anyone may create (also emitted once at deploy).
    event LauncherGateChanged(address nft);
    /// @notice The creator's share of collected pool fees, for raises created after this (also emitted at deploy).
    event CreatorFeeShareChanged(uint16 bps);
    /// @notice Whether `create` is open (also emitted once at deploy with `true`).
    event CreationOpenChanged(bool open);

    // -------------------------------------------------------------------------------------------------------
    // Errors (spec section 4.2)
    // -------------------------------------------------------------------------------------------------------

    /// @notice An address that must be non-zero is zero.
    error ZeroAddress();
    /// @notice `amount` is zero.
    error ZeroAmount();
    /// @notice A fee above its cap: `feeBps > MAX_FEE_BPS`, or a creator fee share above 10,000.
    error FeeTooHigh();
    /// @notice `renounceOwnership` is disabled: the launchpad must always have an owner.
    error RenounceDisabled();
    /// @notice `create` is paused by the owner.
    error CreationClosed();
    /// @notice A launcher gate is set and the caller holds none of its tokens.
    error NotAllowedToLaunch();
    /// @notice The quote asset is not enabled.
    error QuoteNotEnabled();
    /// @notice The target is outside the quote's bounds, or its presale price cannot be represented in one of
    ///         the two currency orders (spec section 4.3); also a `setQuote` call with `0 < min <= max` violated.
    error TargetOutOfRange();
    /// @notice The floor is below 50 % of the target or above it.
    error FloorOutOfRange();
    /// @notice The start is in the past or more than 14 days ahead.
    error StartOutOfRange();
    /// @notice The duration is under 1 hour or over 30 days.
    error DurationOutOfRange();
    /// @notice A text field is outside its length bounds: name 1 to 32 bytes, symbol 1 to 11, links at most 256.
    error TextTooLong();
    /// @notice The raise is not in status Open (or does not exist).
    error NotOpen();
    /// @notice The raise has not started yet.
    error NotStarted();
    /// @notice The raise's deadline has passed.
    error Ended();
    /// @notice Nothing is left to take: the raise is at its target.
    error RaiseFull();
    /// @notice The caller is at the 10 % per-wallet cap.
    error WalletCapReached();
    /// @notice The Permit2 message is for another token or for less than `amount`.
    error PermitMismatch();
    /// @notice The raise is neither at its target nor past its deadline at or above its floor.
    error NotLaunchable();
    /// @notice The raise has not launched.
    error NotLaunched();
    /// @notice Nothing to claim or refund for this caller.
    error NothingToClaim();
    /// @notice The caller already claimed.
    error AlreadyClaimed();
    /// @notice The raise is not refundable: not Closed, and neither under its floor past the deadline nor stalled.
    error NotRefundable();
    /// @notice The caller is not the raise's creator.
    error NotCreator();
    /// @notice `unlockCallback` was called by someone other than the PoolManager.
    error NotPoolManager();
    /// @notice `unlockCallback` arrived while the launchpad had no unlock in flight.
    error UnexpectedCallback();
}
```

- [ ] **Step 5: Write the token**

`src/SVLaunchToken.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @title SVLaunchToken
/// @notice The token a LongMarkets raise launches: a plain OpenZeppelin ERC20 with `burn`, 18 decimals, the
///         whole supply minted once to `recipient` (always the launchpad). No owner, no mint, no pause, no
///         blocklist, no transfer fee.
/// @dev Spec: docs/superpowers/specs/2026-09-27-launchpad-design.md (frontend repo), section 4.1. Deployed by the
///      launchpad with CREATE2 inside the launch transaction; the launchpad burns the part of the supply the pool
///      and the sale did not use.
contract SVLaunchToken is ERC20, ERC20Burnable {
    /// @param name_ Token name, as the creator submitted it.
    /// @param symbol_ Token symbol.
    /// @param supply The whole supply, minted here and never again.
    /// @param recipient Receives the supply: the launchpad.
    constructor(string memory name_, string memory symbol_, uint256 supply, address recipient) ERC20(name_, symbol_) {
        _mint(recipient, supply);
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `forge test --match-path test/unit/SVLaunchToken.t.sol -vv`
Expected: `5 passed, 0 failed`. Then the gates: `forge fmt --check`, `forge build --sizes`, `forge lint`, `forge test` (the router suites still pass: 59 passed, 1 skipped, plus these 5).

- [ ] **Step 7: Commit**

```bash
git checkout -b feat/launchpad
git add remappings.txt src/interfaces/ISVLaunchpad.sol src/SVLaunchToken.sol test/unit/SVLaunchToken.t.sol
git commit -m "Add ISVLaunchpad events and errors, SVLaunchToken, and the solmate remapping for a local PoolManager

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016tofArVnM9erCZUwPku467"
```

### Task 2: Launchpad skeleton: constructor, settings, `create`; `LaunchMath`; the shared fixture

**Files:**
- Modify: `foundry.toml` (the per-file optimizer restriction, after `auto_detect_remappings = false`)
- Create: `src/libraries/LaunchMath.sol`
- Create: `test/utils/LaunchMathHarness.sol`
- Create: `src/SVLaunchpad.sol` (constructor, constants, storage, settings, `renounceOwnership`, `create`, `getRaise`)
- Modify: `src/interfaces/ISVLaunchpad.sol` (append the function declarations of this task)
- Test: `test/unit/LaunchMath.t.sol`, `test/unit/SVLaunchpad.t.sol` (fixture `SVLaunchpadTestBase` + suite `SVLaunchpadTest`)

**Interfaces:**
- Consumes: `ISVLaunchpad` structs, events and errors (Task 1); OZ `Ownable(address)`, `Ownable2Step`, `ReentrancyGuard`, `Math.sqrt(uint256)`; v4-core `FullMath.mulDiv(uint256,uint256,uint256)`, `TickMath.MIN_SQRT_PRICE`; `IERC721.balanceOf`; test-side `Deployers.deployFreshManagerAndRouters()` (gives `manager`, `swapRouter`, `MIN_PRICE_LIMIT`, `MAX_PRICE_LIMIT`), `DeployPermit2().deployPermit2()`, `MockERC20(name, symbol, decimals)` with `mint`, `MockERC721` with `mint(to, id)`, `MockERC721ShortReply`.
- Produces: `library LaunchMath { uint160 internal constant MIN_LAUNCH_SQRT_PRICE = 4310618292; function sqrtPriceX96For(uint256 amount0, uint256 amount1) internal pure returns (uint160); }` (reverts `ISVLaunchpad.TargetOutOfRange` on overflow or below the position's lower edge); `contract LaunchMathHarness { function sqrtPriceX96For(uint256, uint256) external pure returns (uint160); }`; `contract SVLaunchpad is ISVLaunchpad, Ownable2Step, ReentrancyGuard` with `constructor(IPoolManager poolManager_, ISignatureTransfer permit2_, address owner_, address feeWallet_, uint16 feeBps_, uint16 creatorFeeShareBps_)`, public constants `SUPPLY, SALE_BPS, POOL_BPS, CREATOR_BPS, CREATOR_VESTING, WALLET_CAP_BPS, MIN_FLOOR_BPS, MIN_DURATION, MAX_DURATION, MAX_START_DELAY, STALL_GRACE, MAX_FEE_BPS, POOL_LP_FEE, TICK_SPACING, TICK_LOWER, TICK_UPPER`, private immutables `POOL_MANAGER`, `PERMIT2` behind the views `poolManager()`, `permit2()`, public storage `feeWallet, feeBps, creatorFeeShareBps, creationOpen, launcherGate, quoteLimits(address), contributed(uint256,address), claimed(uint256,address), nextId`, `internal` mapping `raises`, functions `create(CreateParams calldata) returns (uint256 id)`, `setFee(uint16)`, `setFeeWallet(address)`, `setQuote(address,uint256,uint256)`, `setLauncherGate(address)`, `setCreatorFeeShare(uint16)`, `setCreationOpen(bool)`, `renounceOwnership()` (reverts), `getRaise(uint256) returns (Raise memory)`; the fixture `abstract contract SVLaunchpadTestBase is Deployers` with the constants and helpers listed in Step 6 (`_fund`, `_contributorKey`, `_contributor`, `_now`, `_params`, `_create`, `_createWithFloor`), which Tasks 3 to 7 extend.

- [ ] **Step 1: Add the compiler restriction**

In `foundry.toml`, directly after the line `auto_detect_remappings = false`, add:

```toml
# SVLaunchpad embeds SVLaunchToken's init code (its CREATE2 deployment), which puts it over the EIP-170 size
# limit at 1_000_000 optimizer runs (26,459 runtime bytes measured on 27 Sep 2026); the two launchpad files
# are compiled at 200 runs instead (20,522 bytes). Every other file, SVRouter included, keeps the setting
# above; SVRouter's runtime size is unchanged (only its metadata hash moves with the remapping list).
# Launched tokens therefore verify with `--optimizer-runs 200`.
additional_compiler_profiles = [{ name = "launchpad", optimizer_runs = 200 }]
compilation_restrictions = [{ paths = "src/SVLaunch*.sol", optimizer_runs = 200 }]
```

Check: `forge config --json | grep -A3 compilation_restrictions` shows `"paths": "src/SVLaunch*.sol"` and `"optimizer_runs": 200`.

- [ ] **Step 2: Write the failing `LaunchMath` tests**

`test/utils/LaunchMathHarness.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchMath} from "../../src/libraries/LaunchMath.sol";

/// @notice Exposes the internal library function as an external call so tests can `expectRevert` on it.
contract LaunchMathHarness {
    function sqrtPriceX96For(uint256 amount0, uint256 amount1) external pure returns (uint160) {
        return LaunchMath.sqrtPriceX96For(amount0, amount1);
    }
}
```

`test/unit/LaunchMath.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ISVLaunchpad} from "../../src/interfaces/ISVLaunchpad.sol";
import {LaunchMath} from "../../src/libraries/LaunchMath.sol";
import {LaunchMathHarness} from "../utils/LaunchMathHarness.sol";

/// @notice The presale price formula of spec section 4.3 in both currency orders, the worked values of the
///         v4-mechanics research notes (computed off-chain with an exact-integer replication of TickMath), and
///         the bounds that make `TargetOutOfRange` fire, including the position's lower edge.
contract LaunchMathTest is Test {
    uint256 internal constant SALE_TOKENS = 450_000_000e18;
    LaunchMathHarness internal math;

    function setUp() public {
        math = new LaunchMathHarness();
    }

    function test_the_formula_is_sqrt_of_amount1_times_2_pow_192_over_amount0() public view {
        uint256 target = 5_000e6;
        uint160 tokenFirst = math.sqrtPriceX96For(SALE_TOKENS, target);
        uint160 quoteFirst = math.sqrtPriceX96For(target, SALE_TOKENS);
        assertEq(
            tokenFirst,
            uint160(Math.sqrt(FullMath.mulDiv(target, uint256(1) << 192, SALE_TOKENS))),
            "token as currency0: sqrt(mulDiv(target, 2^192, saleTokens))"
        );
        assertEq(
            quoteFirst,
            uint160(Math.sqrt(FullMath.mulDiv(SALE_TOKENS, uint256(1) << 192, target))),
            "quote as currency0: sqrt(mulDiv(saleTokens, 2^192, target))"
        );
        assertGe(tokenFirst, LaunchMath.MIN_LAUNCH_SQRT_PRICE, "token-first price above the launch minimum");
        assertLt(quoteFirst, TickMath.MAX_SQRT_PRICE, "quote-first price below the v4 maximum");
    }

    function test_the_worked_values_of_the_research_notes() public view {
        assertEq(math.sqrtPriceX96For(1e18, 1_000), 2505414483750479311864, "token 18d first, 0.001 of a 6d quote");
        assertEq(math.sqrtPriceX96For(1_000, 1e18), 2505414483750479311864138015696063230, "quote 6d first");
        assertEq(
            math.sqrtPriceX96For(1e18, 1e14), 792281625142643375935439503, "token 18d first, 0.0001 of an 18d quote"
        );
        assertEq(math.sqrtPriceX96For(1e14, 1e18), 7922816251426433759354395033600, "quote 18d first");
        assertEq(math.sqrtPriceX96For(1, 2 ** 64 - 1), 340282366920938463454151235394913435647, "the last exact ratio");
    }

    function test_reverts_TargetOutOfRange_when_the_ratio_reaches_2_pow_64() public {
        vm.expectRevert(ISVLaunchpad.TargetOutOfRange.selector);
        math.sqrtPriceX96For(1, 2 ** 64);
    }

    function test_reverts_TargetOutOfRange_far_below_the_lower_edge() public {
        // ratio 1e-40: sqrt(1e-40) * 2^96 is 792281625, far under the edge and under v4's own minimum.
        vm.expectRevert(ISVLaunchpad.TargetOutOfRange.selector);
        math.sqrtPriceX96For(1e40, 1);
    }

    /// @dev The bound is the full-range position's lower edge, not v4's `MIN_SQRT_PRICE`: a price in the sliver
    ///      between the two would initialise the pool and then mint a single-sided position. `(1e41, 296)` lands
    ///      in that sliver (4310478063); `(1e41, 297)` lands just above the edge (4317753137).
    function test_the_lower_bound_is_the_positions_lower_edge_not_the_v4_minimum() public {
        assertEq(LaunchMath.MIN_LAUNCH_SQRT_PRICE, TickMath.getSqrtPriceAtTick(-887200), "the edge is sqrtAt(-887200)");
        assertGt(LaunchMath.MIN_LAUNCH_SQRT_PRICE, TickMath.MIN_SQRT_PRICE, "and above v4's minimum");
        vm.expectRevert(ISVLaunchpad.TargetOutOfRange.selector);
        math.sqrtPriceX96For(1e41, 296);
        assertEq(math.sqrtPriceX96For(1e41, 297), 4317753137, "just above the edge is accepted");
    }

    /// @dev A target that is fine in one currency order and impossible in the other, both ways round: the
    ///      reason `create` must check both (spec section 4.3, amended 27 Sep).
    function test_a_target_can_pass_in_one_order_and_fail_in_the_other() public {
        // 2e7 raw units: the token as currency0 is fine; the quote as currency0 needs a ratio of 2.25e19 >= 2^64.
        assertGt(math.sqrtPriceX96For(SALE_TOKENS, 20_000_000), 0, "small target, token first: representable");
        vm.expectRevert(ISVLaunchpad.TargetOutOfRange.selector);
        math.sqrtPriceX96For(20_000_000, SALE_TOKENS);
        // 1e46 raw units: the quote as currency0 is fine; the token as currency0 needs a ratio of 2.2e19 >= 2^64.
        assertGt(math.sqrtPriceX96For(1e46, SALE_TOKENS), 0, "huge target, quote first: representable");
        vm.expectRevert(ISVLaunchpad.TargetOutOfRange.selector);
        math.sqrtPriceX96For(SALE_TOKENS, 1e46);
    }

    function testFuzz_the_result_squared_brackets_the_ratio(uint256 rawTarget) public view {
        // Both orders representable for every target in this range (see the test above for the edges).
        uint256 target = bound(rawTarget, 1e8, 1e40);
        uint256 tokenFirst = math.sqrtPriceX96For(SALE_TOKENS, target);
        uint256 ratioX192 = FullMath.mulDiv(target, uint256(1) << 192, SALE_TOKENS);
        assertLe(tokenFirst * tokenFirst, ratioX192, "floor of the square root: result^2 <= ratio");
        assertGt((tokenFirst + 1) * (tokenFirst + 1), ratioX192, "and (result + 1)^2 > ratio");
        uint256 quoteFirst = math.sqrtPriceX96For(target, SALE_TOKENS);
        assertGe(quoteFirst, LaunchMath.MIN_LAUNCH_SQRT_PRICE, "quote first above the launch minimum");
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `forge test --match-path test/unit/LaunchMath.t.sol`
Expected: compilation fails, `Source "../../src/libraries/LaunchMath.sol" not found`.

- [ ] **Step 4: Write the library**

`src/libraries/LaunchMath.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {ISVLaunchpad} from "../interfaces/ISVLaunchpad.sol";

/// @title LaunchMath
/// @notice The presale price as a Uniswap v4 `sqrtPriceX96` (spec section 4.3), shared by `SVLaunchpad` and the
///         deploy script so both check the same bounds.
library LaunchMath {
    /// @notice The lowest price a launch may open at: `TickMath.getSqrtPriceAtTick(-887200)`, the lower edge of
    ///         the full-range position at spacing 200. Written out because the library call is not a compile-time
    ///         constant; `test/unit/LaunchMath.t.sol` asserts the equality.
    /// @dev Above `TickMath.MIN_SQRT_PRICE` (4295128739) on purpose: a price in the sliver between the two would
    ///      pass `initialize` and then mint a single-sided position, sending the whole net raise to the fee
    ///      wallet. Reachable only for a quote-first target above 1.5e65 raw units, but `setQuote` accepts any
    ///      bound, so the edge is the bound.
    uint160 internal constant MIN_LAUNCH_SQRT_PRICE = 4310618292;

    /// @notice `sqrtPriceX96 = sqrt(amount1 * 2^192 / amount0)` for raw amounts of `currency0` and `currency1`
    ///         that stand in the presale ratio.
    /// @dev Reverts `TargetOutOfRange` when the 512-bit product would not fit a 256-bit result, that is when
    ///      `amount1 / amount0 >= 2^64` (the `FullMath.mulDiv` overflow condition, checked here so the revert
    ///      carries a named error instead of `mulDiv`'s bare `require`), or when the result is below
    ///      `MIN_LAUNCH_SQRT_PRICE`. No upper check is needed: any result that fits 256 bits has a square root
    ///      below 2^128, which is below `TickMath.MAX_SQRT_PRICE` (about 2^160.5).
    function sqrtPriceX96For(uint256 amount0, uint256 amount1) internal pure returns (uint160) {
        if ((amount1 >> 64) >= amount0) revert ISVLaunchpad.TargetOutOfRange();
        uint256 sqrtPrice = Math.sqrt(FullMath.mulDiv(amount1, uint256(1) << 192, amount0));
        if (sqrtPrice < MIN_LAUNCH_SQRT_PRICE) revert ISVLaunchpad.TargetOutOfRange();
        // The bound above is what makes this cast safe: sqrtPrice < 2^128.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(sqrtPrice);
    }
}
```

- [ ] **Step 5: Run the `LaunchMath` tests to verify they pass**

Run: `forge test --match-path test/unit/LaunchMath.t.sol -vv`
Expected: `7 passed, 0 failed` (the fuzz test at 256 runs).

- [ ] **Step 6: Write the failing fixture and the constructor, settings and `create` suite**

`test/unit/SVLaunchpad.t.sol` (the fixture is shared by every later unit file; Tasks 3, 4 and 6 append helpers to it):

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SVLaunchpad} from "../../src/SVLaunchpad.sol";
import {ISVLaunchpad} from "../../src/interfaces/ISVLaunchpad.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC721} from "../mocks/MockERC721.sol";
import {MockERC721ShortReply} from "../mocks/MockERC721ShortReply.sol";
import {LaunchMathHarness} from "../utils/LaunchMathHarness.sol";

/// @dev A gate whose `balanceOf` reverts. `create` must read it as "not allowed", never as an exception.
contract RevertingGate {
    error GateIsUnwell();

    function balanceOf(address) external pure returns (uint256) {
        revert GateIsUnwell();
    }
}

/// @dev A gate whose `balanceOf` never returns: it hashes until the call's gas allowance is gone.
contract GasBurningGate {
    function balanceOf(address) external view returns (uint256 total) {
        total = uint256(blockhash(block.number - 1));
        while (gasleft() > 0) {
            total = uint256(keccak256(abi.encode(total)));
        }
    }
}

/// @notice Shared fixture for the launchpad unit suites: a local PoolManager and its test routers from v4-core's
///         `Deployers`, the real Permit2 etched at its canonical address, two mock quotes (6 and 18 decimals)
///         enabled at USD-like bounds, ten funded contributor keys (the 10 % cap needs ten wallets to fill a
///         raise), a creator and a stranger, and an SVLaunchpad at the spec's defaults (2 % fee, 70 % share).
/// @dev Every account is a `vm.addr` key so the tests can sign real Permit2 messages; no real wallet or key
///      appears anywhere. The clock starts at a fixed timestamp and block so the tests read the same everywhere.
abstract contract SVLaunchpadTestBase is Deployers {
    uint256 internal constant CREATOR_KEY = 0xC4EA;
    uint256 internal constant STRANGER_KEY = 0xB0BB1E;
    uint256 internal constant CONTRIBUTOR_KEY_BASE = 0xC0000;
    uint256 internal constant CONTRIBUTORS = 10;
    uint16 internal constant FEE_BPS = 200;
    uint16 internal constant CREATOR_FEE_SHARE_BPS = 7000;
    uint256 internal constant USDG_MIN = 1_000e6;
    uint256 internal constant USDG_MAX = 250_000e6;
    uint256 internal constant STK_MIN = 10e18;
    uint256 internal constant STK_MAX = 2_500e18;
    uint256 internal constant USDG_TARGET = 5_000e6;
    uint256 internal constant STK_TARGET = 50e18;
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    uint256 internal constant SALE_TOKENS = 450_000_000e18;
    uint256 internal constant POOL_TOKENS = 450_000_000e18;
    uint256 internal constant CREATOR_TOKENS = 100_000_000e18;
    uint256 internal constant USDG_MINT = 1_000_000e6;
    uint256 internal constant STK_MINT = 1_000_000e18;
    uint256 internal constant NOW = 1_790_000_000;
    int24 internal constant TICK_LOWER = -887_200;
    int24 internal constant TICK_UPPER = 887_200;

    address internal creator;
    address internal stranger;
    address internal owner;
    address internal feeWallet;
    address internal permit2;
    MockERC20 internal usdg;
    MockERC20 internal stk;
    SVLaunchpad internal launchpad;
    /// @dev Permit2 nonces are unordered per owner; every signature the suites make takes the next one.
    uint256 internal nextNonce;

    function setUp() public virtual {
        deployFreshManagerAndRouters();
        creator = vm.addr(CREATOR_KEY);
        stranger = vm.addr(STRANGER_KEY);
        owner = makeAddr("owner");
        feeWallet = makeAddr("feeWallet");
        vm.label(creator, "creator");
        vm.label(stranger, "stranger");
        // The real Permit2, etched at its canonical address from the bytecode shipped in its repository.
        permit2 = new DeployPermit2().deployPermit2();
        usdg = new MockERC20("USD Global", "USDG", 6);
        stk = new MockERC20("Stock", "STK", 18);
        launchpad =
            new SVLaunchpad(manager, ISignatureTransfer(permit2), owner, feeWallet, FEE_BPS, CREATOR_FEE_SHARE_BPS);
        vm.startPrank(owner);
        launchpad.setQuote(address(usdg), USDG_MIN, USDG_MAX);
        launchpad.setQuote(address(stk), STK_MIN, STK_MAX);
        vm.stopPrank();
        for (uint256 i = 0; i < CONTRIBUTORS; i++) {
            _fund(_contributor(i));
        }
        _fund(creator);
        _fund(stranger);
        vm.warp(NOW);
        vm.roll(1_000);
    }

    // -------------------------------------------------------------------------------------------------------
    // Fixture helpers
    // -------------------------------------------------------------------------------------------------------

    function _fund(address wallet) internal {
        usdg.mint(wallet, USDG_MINT);
        stk.mint(wallet, STK_MINT);
        vm.startPrank(wallet);
        usdg.approve(permit2, type(uint256).max);
        stk.approve(permit2, type(uint256).max);
        vm.stopPrank();
    }

    function _contributorKey(uint256 i) internal pure returns (uint256) {
        return CONTRIBUTOR_KEY_BASE + i;
    }

    function _contributor(uint256 i) internal pure returns (address) {
        return vm.addr(_contributorKey(i));
    }

    /// @dev `block.timestamp` as the `uint64` the interface uses; a test clock never nears 2^64.
    function _now() internal view returns (uint64) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(block.timestamp);
    }

    /// @dev A valid raise: all-or-nothing floor, starting now, one day long.
    function _params(address quote, uint256 target) internal view returns (ISVLaunchpad.CreateParams memory) {
        return ISVLaunchpad.CreateParams({
            name: "Launch Token",
            symbol: "LT",
            image: "https://example.com/lt.png",
            website: "https://example.com",
            x: "https://x.com/lt",
            telegram: "https://t.me/lt",
            quote: quote,
            target: target,
            floor: target,
            start: _now(),
            duration: 1 days
        });
    }

    function _create(address quote, uint256 target) internal returns (uint256 id) {
        vm.prank(creator);
        return launchpad.create(_params(quote, target));
    }

    function _createWithFloor(address quote, uint256 target, uint256 floor) internal returns (uint256 id) {
        ISVLaunchpad.CreateParams memory p = _params(quote, target);
        p.floor = floor;
        vm.prank(creator);
        return launchpad.create(p);
    }
}

/// @notice The constructor, the owner settings, ownership, and `create` with every bound of spec section 4.2.
contract SVLaunchpadTest is SVLaunchpadTestBase {
    // -------------------------------------------------------------------------------------------------------
    // Constructor (spec section 4.2)
    // -------------------------------------------------------------------------------------------------------

    function test_constructor_stores_the_deploy_values_and_emits_every_setter_event() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectEmit(true, true, true, true, predicted);
        emit ISVLaunchpad.FeeChanged(FEE_BPS);
        vm.expectEmit(true, true, true, true, predicted);
        emit ISVLaunchpad.FeeWalletChanged(feeWallet);
        vm.expectEmit(true, true, true, true, predicted);
        emit ISVLaunchpad.CreatorFeeShareChanged(CREATOR_FEE_SHARE_BPS);
        vm.expectEmit(true, true, true, true, predicted);
        emit ISVLaunchpad.LauncherGateChanged(address(0));
        vm.expectEmit(true, true, true, true, predicted);
        emit ISVLaunchpad.CreationOpenChanged(true);
        SVLaunchpad fresh =
            new SVLaunchpad(manager, ISignatureTransfer(permit2), owner, feeWallet, FEE_BPS, CREATOR_FEE_SHARE_BPS);
        assertEq(address(fresh), predicted, "deployed where the events were expected");
        assertEq(address(fresh.poolManager()), address(manager), "pool manager");
        assertEq(address(fresh.permit2()), permit2, "permit2");
        assertEq(fresh.owner(), owner, "owner");
        assertEq(fresh.feeWallet(), feeWallet, "fee wallet");
        assertEq(fresh.feeBps(), FEE_BPS, "fee bps");
        assertEq(fresh.creatorFeeShareBps(), CREATOR_FEE_SHARE_BPS, "creator fee share");
        assertEq(fresh.launcherGate(), address(0), "no gate");
        assertTrue(fresh.creationOpen(), "creation open");
        assertEq(fresh.nextId(), 1, "ids start at 1");
    }

    function test_constructor_reverts_ZeroAddress_for_each_zero_argument() public {
        vm.expectRevert(ISVLaunchpad.ZeroAddress.selector);
        new SVLaunchpad(IPoolManager(address(0)), ISignatureTransfer(permit2), owner, feeWallet, FEE_BPS, 7000);
        vm.expectRevert(ISVLaunchpad.ZeroAddress.selector);
        new SVLaunchpad(manager, ISignatureTransfer(address(0)), owner, feeWallet, FEE_BPS, 7000);
        vm.expectRevert(ISVLaunchpad.ZeroAddress.selector);
        new SVLaunchpad(manager, ISignatureTransfer(permit2), address(0), feeWallet, FEE_BPS, 7000);
        vm.expectRevert(ISVLaunchpad.ZeroAddress.selector);
        new SVLaunchpad(manager, ISignatureTransfer(permit2), owner, address(0), FEE_BPS, 7000);
    }

    function test_constructor_reverts_FeeTooHigh_above_either_cap() public {
        vm.expectRevert(ISVLaunchpad.FeeTooHigh.selector);
        new SVLaunchpad(manager, ISignatureTransfer(permit2), owner, feeWallet, 501, 7000);
        vm.expectRevert(ISVLaunchpad.FeeTooHigh.selector);
        new SVLaunchpad(manager, ISignatureTransfer(permit2), owner, feeWallet, FEE_BPS, 10_001);
    }

    function test_the_constants_are_the_spec_values() public view {
        assertEq(launchpad.SUPPLY(), 1_000_000_000e18, "SUPPLY");
        assertEq(launchpad.SALE_BPS(), 4500, "SALE_BPS");
        assertEq(launchpad.POOL_BPS(), 4500, "POOL_BPS");
        assertEq(launchpad.CREATOR_BPS(), 1000, "CREATOR_BPS");
        assertEq(launchpad.CREATOR_VESTING(), 90 days, "CREATOR_VESTING");
        assertEq(launchpad.WALLET_CAP_BPS(), 1000, "WALLET_CAP_BPS");
        assertEq(launchpad.MIN_FLOOR_BPS(), 5000, "MIN_FLOOR_BPS");
        assertEq(launchpad.MIN_DURATION(), 1 hours, "MIN_DURATION");
        assertEq(launchpad.MAX_DURATION(), 30 days, "MAX_DURATION");
        assertEq(launchpad.MAX_START_DELAY(), 14 days, "MAX_START_DELAY");
        assertEq(launchpad.STALL_GRACE(), 7 days, "STALL_GRACE");
        assertEq(launchpad.MAX_FEE_BPS(), 500, "MAX_FEE_BPS");
        assertEq(launchpad.POOL_LP_FEE(), 10_000, "POOL_LP_FEE");
        assertEq(launchpad.TICK_SPACING(), 200, "TICK_SPACING");
        assertEq(launchpad.TICK_LOWER(), -887_200, "TICK_LOWER");
        assertEq(launchpad.TICK_UPPER(), 887_200, "TICK_UPPER");
    }

    // -------------------------------------------------------------------------------------------------------
    // Settings (spec section 4.2 setter table)
    // -------------------------------------------------------------------------------------------------------

    function test_setFee_accepts_the_cap_and_emits() public {
        vm.expectEmit(true, true, true, true, address(launchpad));
        emit ISVLaunchpad.FeeChanged(500);
        vm.prank(owner);
        launchpad.setFee(500);
        assertEq(launchpad.feeBps(), 500, "fee at the cap");
        vm.prank(owner);
        launchpad.setFee(0);
        assertEq(launchpad.feeBps(), 0, "fee can be zero");
    }

    function test_setFee_reverts_FeeTooHigh_above_500() public {
        vm.prank(owner);
        vm.expectRevert(ISVLaunchpad.FeeTooHigh.selector);
        launchpad.setFee(501);
    }

    function test_setFeeWallet_sets_and_emits_and_refuses_zero() public {
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

    function test_setQuote_enables_rebounds_and_disables_with_a_zero_maximum() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        vm.expectEmit(true, true, true, true, address(launchpad));
        emit ISVLaunchpad.QuoteChanged(address(other), 1e18, 5e18);
        vm.prank(owner);
        launchpad.setQuote(address(other), 1e18, 5e18);
        (uint256 minTarget, uint256 maxTarget) = launchpad.quoteLimits(address(other));
        assertEq(minTarget, 1e18, "min");
        assertEq(maxTarget, 5e18, "max");
        vm.prank(owner);
        launchpad.setQuote(address(other), 7, 0);
        (, maxTarget) = launchpad.quoteLimits(address(other));
        assertEq(maxTarget, 0, "disabled");
        vm.prank(creator);
        vm.expectRevert(ISVLaunchpad.QuoteNotEnabled.selector);
        launchpad.create(_params(address(other), 1e18));
    }

    function test_setQuote_reverts_TargetOutOfRange_unless_0_below_min_at_most_max() public {
        vm.startPrank(owner);
        vm.expectRevert(ISVLaunchpad.TargetOutOfRange.selector);
        launchpad.setQuote(address(usdg), 0, 5e6);
        vm.expectRevert(ISVLaunchpad.TargetOutOfRange.selector);
        launchpad.setQuote(address(usdg), 6e6, 5e6);
        launchpad.setQuote(address(usdg), 5e6, 5e6); // min == max is allowed
        vm.stopPrank();
    }

    function test_setQuote_reverts_ZeroAddress_for_the_zero_asset() public {
        vm.prank(owner);
        vm.expectRevert(ISVLaunchpad.ZeroAddress.selector);
        launchpad.setQuote(address(0), 1, 2);
    }

    function test_setLauncherGate_sets_any_address_including_zero_and_emits() public {
        MockERC721 gate = new MockERC721();
        vm.expectEmit(true, true, true, true, address(launchpad));
        emit ISVLaunchpad.LauncherGateChanged(address(gate));
        vm.prank(owner);
        launchpad.setLauncherGate(address(gate));
        assertEq(launchpad.launcherGate(), address(gate), "gate set");
        vm.prank(owner);
        launchpad.setLauncherGate(address(0));
        assertEq(launchpad.launcherGate(), address(0), "gate cleared");
    }

    function test_setCreatorFeeShare_accepts_up_to_10000_and_applies_to_later_raises_only() public {
        uint256 before = _create(address(usdg), USDG_TARGET);
        vm.expectEmit(true, true, true, true, address(launchpad));
        emit ISVLaunchpad.CreatorFeeShareChanged(10_000);
        vm.prank(owner);
        launchpad.setCreatorFeeShare(10_000);
        uint256 after_ = _create(address(usdg), USDG_TARGET);
        assertEq(launchpad.getRaise(before).creatorFeeShareBps, CREATOR_FEE_SHARE_BPS, "the earlier raise keeps 70 %");
        assertEq(launchpad.getRaise(after_).creatorFeeShareBps, 10_000, "the later raise takes the new share");
        vm.prank(owner);
        vm.expectRevert(ISVLaunchpad.FeeTooHigh.selector);
        launchpad.setCreatorFeeShare(10_001);
    }

    function test_setCreationOpen_false_blocks_create_and_true_reopens_it() public {
        vm.expectEmit(true, true, true, true, address(launchpad));
        emit ISVLaunchpad.CreationOpenChanged(false);
        vm.prank(owner);
        launchpad.setCreationOpen(false);
        vm.prank(creator);
        vm.expectRevert(ISVLaunchpad.CreationClosed.selector);
        launchpad.create(_params(address(usdg), USDG_TARGET));
        vm.prank(owner);
        launchpad.setCreationOpen(true);
        assertEq(_create(address(usdg), USDG_TARGET), 1, "create works again");
    }

    function test_every_setter_is_owner_only() public {
        bytes memory unauthorized = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger);
        vm.startPrank(stranger);
        vm.expectRevert(unauthorized);
        launchpad.setFee(1);
        vm.expectRevert(unauthorized);
        launchpad.setFeeWallet(stranger);
        vm.expectRevert(unauthorized);
        launchpad.setQuote(address(usdg), 1, 2);
        vm.expectRevert(unauthorized);
        launchpad.setLauncherGate(stranger);
        vm.expectRevert(unauthorized);
        launchpad.setCreatorFeeShare(1);
        vm.expectRevert(unauthorized);
        launchpad.setCreationOpen(false);
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
    // create (spec section 4.2, steps 1 to 3)
    // -------------------------------------------------------------------------------------------------------

    function test_create_stores_the_raise_and_emits_RaiseCreated_and_RaiseMetadata() public {
        ISVLaunchpad.CreateParams memory p = _params(address(usdg), USDG_TARGET);
        vm.expectEmit(true, true, true, true, address(launchpad));
        emit ISVLaunchpad.RaiseCreated(
            1, creator, address(usdg), USDG_TARGET, USDG_TARGET, _now(), _now() + 1 days, SALE_TOKENS
        );
        vm.expectEmit(true, true, true, true, address(launchpad));
        emit ISVLaunchpad.RaiseMetadata(1, p.name, p.symbol, p.image, p.website, p.x, p.telegram);
        vm.prank(creator);
        uint256 id = launchpad.create(p);
        assertEq(id, 1, "first id is 1");
        ISVLaunchpad.Raise memory r = launchpad.getRaise(id);
        assertEq(r.creator, creator, "creator");
        assertEq(r.payout, creator, "payout defaults to the creator");
        assertEq(r.quote, address(usdg), "quote");
        assertEq(r.token, address(0), "no token before launch");
        assertEq(r.target, USDG_TARGET, "target");
        assertEq(r.floor, USDG_TARGET, "floor");
        assertEq(r.start, _now(), "start");
        assertEq(r.deadline, _now() + 1 days, "deadline = start + duration");
        assertEq(r.raised, 0, "nothing raised");
        assertEq(r.saleTokens, SALE_TOKENS, "saleTokens = 45 % of the supply");
        assertEq(r.creatorFeeShareBps, CREATOR_FEE_SHARE_BPS, "share fixed at creation");
        assertEq(r.status, 1, "status Open");
        assertEq(r.name, "Launch Token", "name");
        assertEq(r.symbol, "LT", "symbol");
        assertEq(launchpad.nextId(), 2, "next id");
        assertEq(_create(address(stk), STK_TARGET), 2, "ids are sequential");
    }

    function test_create_with_a_gate_allows_holders_and_refuses_everyone_else() public {
        MockERC721 gate = new MockERC721();
        gate.mint(creator, 1);
        vm.prank(owner);
        launchpad.setLauncherGate(address(gate));
        assertEq(_create(address(usdg), USDG_TARGET), 1, "a holder creates");
        vm.prank(stranger);
        vm.expectRevert(ISVLaunchpad.NotAllowedToLaunch.selector);
        launchpad.create(_params(address(usdg), USDG_TARGET));
        vm.prank(owner);
        launchpad.setLauncherGate(address(0));
        vm.prank(stranger);
        assertEq(launchpad.create(_params(address(usdg), USDG_TARGET)), 2, "gate cleared: anyone creates");
    }

    function test_a_gate_that_reverts_replies_short_burns_its_gas_or_has_no_code_refuses_everyone() public {
        address[4] memory gates = [
            address(new RevertingGate()),
            address(new MockERC721ShortReply()),
            address(new GasBurningGate()),
            makeAddr("no code here")
        ];
        for (uint256 i = 0; i < gates.length; i++) {
            vm.prank(owner);
            launchpad.setLauncherGate(gates[i]);
            vm.prank(creator);
            vm.expectRevert(ISVLaunchpad.NotAllowedToLaunch.selector);
            launchpad.create(_params(address(usdg), USDG_TARGET));
        }
    }

    function test_create_reverts_QuoteNotEnabled_for_an_unknown_asset() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        vm.prank(creator);
        vm.expectRevert(ISVLaunchpad.QuoteNotEnabled.selector);
        launchpad.create(_params(address(other), 1e18));
    }

    function test_create_reverts_TargetOutOfRange_outside_the_quote_bounds_and_accepts_the_bounds() public {
        vm.startPrank(creator);
        vm.expectRevert(ISVLaunchpad.TargetOutOfRange.selector);
        launchpad.create(_params(address(usdg), USDG_MIN - 1));
        vm.expectRevert(ISVLaunchpad.TargetOutOfRange.selector);
        launchpad.create(_params(address(usdg), USDG_MAX + 1));
        launchpad.create(_params(address(usdg), USDG_MIN));
        launchpad.create(_params(address(usdg), USDG_MAX));
        vm.stopPrank();
    }

    /// @dev Spec section 4.3 (amended 27 Sep): the token's side of the pair is unknown until launch, so a target
    ///      whose price is representable in one order but not the other must be refused. Both directions.
    function test_create_reverts_TargetOutOfRange_when_only_one_currency_order_is_representable() public {
        LaunchMathHarness math = new LaunchMathHarness();
        vm.prank(owner);
        launchpad.setQuote(address(usdg), 1, type(uint256).max);
        // 2e7: fine with the token as currency0, an overflow with the quote as currency0.
        assertGt(math.sqrtPriceX96For(SALE_TOKENS, 20_000_000), 0, "token-first order is representable");
        vm.expectRevert(ISVLaunchpad.TargetOutOfRange.selector);
        math.sqrtPriceX96For(20_000_000, SALE_TOKENS);
        vm.prank(creator);
        vm.expectRevert(ISVLaunchpad.TargetOutOfRange.selector);
        launchpad.create(_params(address(usdg), 20_000_000));
        // 1e46: fine with the quote as currency0, an overflow with the token as currency0.
        assertGt(math.sqrtPriceX96For(1e46, SALE_TOKENS), 0, "quote-first order is representable");
        vm.expectRevert(ISVLaunchpad.TargetOutOfRange.selector);
        math.sqrtPriceX96For(SALE_TOKENS, 1e46);
        vm.prank(creator);
        vm.expectRevert(ISVLaunchpad.TargetOutOfRange.selector);
        launchpad.create(_params(address(usdg), 1e46));
        // A target inside both orders' range is accepted under the same permissive bounds.
        assertEq(_create(address(usdg), USDG_TARGET), 1, "a representable target creates");
    }

    function test_create_reverts_FloorOutOfRange_below_half_or_above_the_target_and_accepts_both_edges() public {
        ISVLaunchpad.CreateParams memory p = _params(address(usdg), USDG_TARGET);
        vm.startPrank(creator);
        p.floor = USDG_TARGET / 2 - 1;
        vm.expectRevert(ISVLaunchpad.FloorOutOfRange.selector);
        launchpad.create(p);
        p.floor = USDG_TARGET + 1;
        vm.expectRevert(ISVLaunchpad.FloorOutOfRange.selector);
        launchpad.create(p);
        p.floor = USDG_TARGET / 2;
        launchpad.create(p);
        p.floor = USDG_TARGET;
        launchpad.create(p);
        vm.stopPrank();
    }

    function test_create_reverts_StartOutOfRange_in_the_past_or_beyond_14_days_and_accepts_both_edges() public {
        ISVLaunchpad.CreateParams memory p = _params(address(usdg), USDG_TARGET);
        vm.startPrank(creator);
        p.start = _now() - 1;
        vm.expectRevert(ISVLaunchpad.StartOutOfRange.selector);
        launchpad.create(p);
        p.start = _now() + 14 days + 1;
        vm.expectRevert(ISVLaunchpad.StartOutOfRange.selector);
        launchpad.create(p);
        p.start = _now();
        launchpad.create(p);
        p.start = _now() + 14 days;
        launchpad.create(p);
        vm.stopPrank();
    }

    /// @dev Spec section 4.2 (amended 27 Sep): a zero start means "now".
    function test_create_with_start_zero_starts_now() public {
        ISVLaunchpad.CreateParams memory p = _params(address(usdg), USDG_TARGET);
        p.start = 0;
        vm.expectEmit(true, true, true, true, address(launchpad));
        emit ISVLaunchpad.RaiseCreated(
            1, creator, address(usdg), USDG_TARGET, USDG_TARGET, _now(), _now() + 1 days, SALE_TOKENS
        );
        vm.prank(creator);
        uint256 id = launchpad.create(p);
        ISVLaunchpad.Raise memory r = launchpad.getRaise(id);
        assertEq(r.start, _now(), "start zero means now");
        assertEq(r.deadline, _now() + 1 days, "the deadline counts from now");
    }

    function test_create_reverts_DurationOutOfRange_under_1_hour_or_over_30_days_and_accepts_both_edges() public {
        ISVLaunchpad.CreateParams memory p = _params(address(usdg), USDG_TARGET);
        vm.startPrank(creator);
        p.duration = 1 hours - 1;
        vm.expectRevert(ISVLaunchpad.DurationOutOfRange.selector);
        launchpad.create(p);
        p.duration = 30 days + 1;
        vm.expectRevert(ISVLaunchpad.DurationOutOfRange.selector);
        launchpad.create(p);
        p.duration = 1 hours;
        launchpad.create(p);
        p.duration = 30 days;
        launchpad.create(p);
        vm.stopPrank();
    }

    function test_create_reverts_TextTooLong_for_each_text_bound_and_accepts_the_maximum_lengths() public {
        string memory bytes32Text = "abcdefghijklmnopqrstuvwxyz012345"; // 32 bytes
        string memory bytes256Text = string(new bytes(256));
        ISVLaunchpad.CreateParams memory p = _params(address(usdg), USDG_TARGET);
        vm.startPrank(creator);
        p.name = "";
        vm.expectRevert(ISVLaunchpad.TextTooLong.selector);
        launchpad.create(p);
        p.name = string.concat(bytes32Text, "!");
        vm.expectRevert(ISVLaunchpad.TextTooLong.selector);
        launchpad.create(p);
        p = _params(address(usdg), USDG_TARGET);
        p.symbol = "";
        vm.expectRevert(ISVLaunchpad.TextTooLong.selector);
        launchpad.create(p);
        p.symbol = "ABCDEFGHIJKL"; // 12 bytes
        vm.expectRevert(ISVLaunchpad.TextTooLong.selector);
        launchpad.create(p);
        p = _params(address(usdg), USDG_TARGET);
        p.image = string.concat(bytes256Text, "!");
        vm.expectRevert(ISVLaunchpad.TextTooLong.selector);
        launchpad.create(p);
        p = _params(address(usdg), USDG_TARGET);
        p.website = string.concat(bytes256Text, "!");
        vm.expectRevert(ISVLaunchpad.TextTooLong.selector);
        launchpad.create(p);
        p = _params(address(usdg), USDG_TARGET);
        p.x = string.concat(bytes256Text, "!");
        vm.expectRevert(ISVLaunchpad.TextTooLong.selector);
        launchpad.create(p);
        p = _params(address(usdg), USDG_TARGET);
        p.telegram = string.concat(bytes256Text, "!");
        vm.expectRevert(ISVLaunchpad.TextTooLong.selector);
        launchpad.create(p);
        // The maximum lengths are accepted, empty links too.
        p = _params(address(usdg), USDG_TARGET);
        p.name = bytes32Text;
        p.symbol = "ABCDEFGHIJK"; // 11 bytes
        p.image = bytes256Text;
        p.website = bytes256Text;
        p.x = "";
        p.telegram = "";
        assertEq(launchpad.create(p), 1, "the longest allowed texts create");
        vm.stopPrank();
    }
}
```

- [ ] **Step 7: Run the suite to verify it fails**

Run: `forge test --match-path test/unit/SVLaunchpad.t.sol`
Expected: compilation fails, `Source "../../src/SVLaunchpad.sol" not found`.

- [ ] **Step 8: Declare this task's functions in the interface**

In `src/interfaces/ISVLaunchpad.sol`, add `import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";` as the first import, then append inside `interface ISVLaunchpad { ... }`, after the errors (names, types and order as the spec's "Function signatures" block):

```solidity
    // -------------------------------------------------------------------------------------------------------
    // Functions
    // -------------------------------------------------------------------------------------------------------

    /// @notice Create a raise. Emits `RaiseCreated` and `RaiseMetadata`.
    /// @return id The raise id, sequential from 1.
    function create(CreateParams calldata p) external returns (uint256 id);

    /// @notice Owner only. The launch fee in basis points; at most `MAX_FEE_BPS`.
    function setFee(uint16 bps) external;

    /// @notice Owner only. The wallet that receives the launch fee, unused quote dust and the platform's fee
    ///         share; non-zero.
    function setFeeWallet(address wallet) external;

    /// @notice Owner only. Enable a quote asset with raise bounds, or disable it with `maxTarget == 0`.
    function setQuote(address asset, uint256 minTarget, uint256 maxTarget) external;

    /// @notice Owner only. The NFT whose holders may create raises; zero means anyone.
    function setLauncherGate(address nft) external;

    /// @notice Owner only. The creator's share of collected pool fees in basis points, for raises created after.
    function setCreatorFeeShare(uint16 bps) external;

    /// @notice Owner only. Pause or resume `create`; nothing else is ever paused.
    function setCreationOpen(bool open) external;

    /// @notice One raise as stored.
    function getRaise(uint256 id) external view returns (Raise memory);

    /// @notice What `wallet` has contributed to raise `id` and not refunded.
    function contributed(uint256 id, address wallet) external view returns (uint256);

    /// @notice Whether `wallet` has claimed its tokens of raise `id`.
    function claimed(uint256 id, address wallet) external view returns (bool);

    /// @notice The id the next `create` will use; 1 at deploy.
    function nextId() external view returns (uint256);

    /// @notice The launch fee in basis points.
    function feeBps() external view returns (uint16);

    /// @notice The wallet that receives the launch fee and the platform's fee share.
    function feeWallet() external view returns (address);

    /// @notice The launcher gate NFT; zero means anyone may create.
    function launcherGate() external view returns (address);

    /// @notice The creator's share of collected pool fees, in basis points, for raises created from now on.
    function creatorFeeShareBps() external view returns (uint16);

    /// @notice Whether `create` is open.
    function creationOpen() external view returns (bool);

    /// @notice The raise bounds of a quote asset; `maxTarget == 0` means not enabled.
    function quoteLimits(address asset) external view returns (uint256 minTarget, uint256 maxTarget);

    /// @notice The Uniswap v4 PoolManager the launch pools live in.
    function poolManager() external view returns (IPoolManager);

    /// @notice Permit2, which pulls the quote asset from contributors against their signatures.
    function permit2() external view returns (ISignatureTransfer);
```

(The views follow the order of the spec's block; Task 4 inserts `poolKey` between `quoteLimits` and `poolManager`.)

- [ ] **Step 9: Write the launchpad as of this task**

`src/SVLaunchpad.sol` (Tasks 3 to 6 add imports and functions to this file; the section banners below are where they go):

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {ISVLaunchpad} from "./interfaces/ISVLaunchpad.sol";
import {LaunchMath} from "./libraries/LaunchMath.sol";

/// @title SVLaunchpad
/// @notice The LongMarkets launchpad singleton: every raise lives here. A creator opens a fixed-price raise in an
///         enabled quote asset; contributors pay through Permit2 under a 10 % per-wallet cap; when the target is
///         reached, or the deadline passes at or above the floor, the launch deploys the token, initialises a
///         hookless 1 % Uniswap v4 pool at the presale price and mints a full-range position the launchpad owns
///         and can never decrease. A raise that misses its floor refunds everyone in full.
/// @dev Spec: docs/superpowers/specs/2026-09-27-launchpad-design.md (frontend repo), sections 3 and 4. The step
///      numbers in the body comments are the spec's.
contract SVLaunchpad is ISVLaunchpad, Ownable2Step, ReentrancyGuard {
    // -------------------------------------------------------------------------------------------------------
    // Constants (spec section 4.2)
    // -------------------------------------------------------------------------------------------------------

    uint256 public constant SUPPLY = 1_000_000_000e18;
    uint16 public constant SALE_BPS = 4500;
    uint16 public constant POOL_BPS = 4500;
    uint16 public constant CREATOR_BPS = 1000;
    uint64 public constant CREATOR_VESTING = 90 days;
    uint16 public constant WALLET_CAP_BPS = 1000;
    uint16 public constant MIN_FLOOR_BPS = 5000;
    uint64 public constant MIN_DURATION = 1 hours;
    uint64 public constant MAX_DURATION = 30 days;
    uint64 public constant MAX_START_DELAY = 14 days;
    uint64 public constant STALL_GRACE = 7 days;
    uint16 public constant MAX_FEE_BPS = 500;
    uint24 public constant POOL_LP_FEE = 10_000;
    int24 public constant TICK_SPACING = 200;
    int24 public constant TICK_LOWER = -887_200;
    int24 public constant TICK_UPPER = 887_200;

    /// @dev Basis points denominator: 10_000 bps is 100 %.
    uint256 private constant BPS = 10_000;
    /// @dev Gas allowance for reading the gate NFT's balance, as the router's Suits check.
    uint256 private constant GATE_CHECK_GAS = 100_000;
    uint256 private constant SALE_TOKENS = SUPPLY * SALE_BPS / BPS;
    uint256 private constant POOL_TOKENS = SUPPLY * POOL_BPS / BPS;
    uint256 private constant CREATOR_TOKENS = SUPPLY * CREATOR_BPS / BPS;
    uint256 private constant NAME_MAX_BYTES = 32;
    uint256 private constant SYMBOL_MAX_BYTES = 11;
    uint256 private constant LINK_MAX_BYTES = 256;
    uint8 private constant STATUS_OPEN = 1;
    uint8 private constant STATUS_LAUNCHED = 2;
    uint8 private constant STATUS_CLOSED = 3;

    // -------------------------------------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------------------------------------

    /// @dev The Uniswap v4 PoolManager the launch pools live in; read through `poolManager()`, the name the
    ///      spec's ABI fixes, while the immutable keeps the repo's UPPER_SNAKE convention.
    IPoolManager private immutable POOL_MANAGER;

    /// @dev Permit2, which pulls the quote asset from contributors against their signatures; see `permit2()`.
    ISignatureTransfer private immutable PERMIT2;

    // -------------------------------------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------------------------------------

    /// @inheritdoc ISVLaunchpad
    address public feeWallet;
    /// @inheritdoc ISVLaunchpad
    uint16 public feeBps;
    /// @inheritdoc ISVLaunchpad
    uint16 public creatorFeeShareBps;
    /// @inheritdoc ISVLaunchpad
    bool public creationOpen;
    /// @inheritdoc ISVLaunchpad
    address public launcherGate;
    /// @inheritdoc ISVLaunchpad
    mapping(address asset => Quote) public quoteLimits;
    /// @dev Internal, not private, so a test harness can reach states the contract itself never produces.
    mapping(uint256 id => Raise) internal raises;
    /// @inheritdoc ISVLaunchpad
    mapping(uint256 id => mapping(address wallet => uint256)) public contributed;
    /// @inheritdoc ISVLaunchpad
    mapping(uint256 id => mapping(address wallet => bool)) public claimed;
    /// @inheritdoc ISVLaunchpad
    uint256 public nextId;

    // -------------------------------------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------------------------------------

    /// @param poolManager_ The Uniswap v4 PoolManager.
    /// @param permit2_ The canonical Permit2.
    /// @param owner_ The Ownable2Step owner: Kobe's EOA at deploy, MAXLONG's at handover.
    /// @param feeWallet_ Receives the launch fee, unused quote dust and the platform's fee share.
    /// @param feeBps_ The launch fee; at most `MAX_FEE_BPS`.
    /// @param creatorFeeShareBps_ The creator's share of collected pool fees; at most 10,000.
    /// @dev The owner is checked inside the `Ownable` constructor argument because `Ownable`'s constructor runs
    ///      before this body and would otherwise revert with its own error instead of `ZeroAddress()`. Every
    ///      setter's event is emitted with its initial value so indexers see the deploy state.
    constructor(
        IPoolManager poolManager_,
        ISignatureTransfer permit2_,
        address owner_,
        address feeWallet_,
        uint16 feeBps_,
        uint16 creatorFeeShareBps_
    ) Ownable(_nonZero(owner_)) {
        if (address(poolManager_) == address(0) || address(permit2_) == address(0) || feeWallet_ == address(0)) {
            revert ZeroAddress();
        }
        if (feeBps_ > MAX_FEE_BPS || creatorFeeShareBps_ > BPS) revert FeeTooHigh();
        POOL_MANAGER = poolManager_;
        PERMIT2 = permit2_;
        feeWallet = feeWallet_;
        feeBps = feeBps_;
        creatorFeeShareBps = creatorFeeShareBps_;
        creationOpen = true;
        nextId = 1;
        emit FeeChanged(feeBps_);
        emit FeeWalletChanged(feeWallet_);
        emit CreatorFeeShareChanged(creatorFeeShareBps_);
        emit LauncherGateChanged(address(0));
        emit CreationOpenChanged(true);
    }

    // -------------------------------------------------------------------------------------------------------
    // create (spec section 4.2)
    // -------------------------------------------------------------------------------------------------------

    /// @inheritdoc ISVLaunchpad
    /// @dev Spec steps: 1. creation open and the gate; 2. every bound, including the presale price in both
    ///      currency orders (section 4.3), because the token's side of the pair is unknown until launch;
    ///      3. store and emit.
    function create(CreateParams calldata p) external nonReentrant returns (uint256 id) {
        // 1.
        if (!creationOpen) revert CreationClosed();
        if (!_mayLaunch(msg.sender)) revert NotAllowedToLaunch();

        // 2.
        Quote memory q = quoteLimits[p.quote];
        if (q.maxTarget == 0) revert QuoteNotEnabled();
        if (p.target < q.minTarget || p.target > q.maxTarget) revert TargetOutOfRange();
        LaunchMath.sqrtPriceX96For(SALE_TOKENS, p.target); // the token as currency0
        LaunchMath.sqrtPriceX96For(p.target, SALE_TOKENS); // the quote as currency0
        if (p.floor < p.target * MIN_FLOOR_BPS / BPS || p.floor > p.target) revert FloorOutOfRange();
        // A zero start means now (spec section 4.2); the cast cannot truncate before the year 292 billion.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 start = p.start == 0 ? uint64(block.timestamp) : p.start;
        if (start < block.timestamp || start > block.timestamp + MAX_START_DELAY) revert StartOutOfRange();
        if (p.duration < MIN_DURATION || p.duration > MAX_DURATION) revert DurationOutOfRange();
        _checkText(p);

        // 3.
        id = nextId++;
        Raise storage r = raises[id];
        r.creator = msg.sender;
        r.payout = msg.sender;
        r.quote = p.quote;
        r.target = p.target;
        r.floor = p.floor;
        r.start = start;
        r.deadline = start + p.duration;
        r.saleTokens = SALE_TOKENS;
        r.creatorFeeShareBps = creatorFeeShareBps;
        r.status = STATUS_OPEN;
        r.name = p.name;
        r.symbol = p.symbol;
        emit RaiseCreated(id, msg.sender, p.quote, p.target, p.floor, start, r.deadline, SALE_TOKENS);
        _emitMetadata(id, p);
    }

    /// @dev Takes the params in memory on purpose: a calldata string is two stack slots and the ABI encoder for
    ///      six of them runs out of stack under the legacy code generator; a memory string is one slot. The copy
    ///      costs a little gas once per raise.
    function _emitMetadata(uint256 id, CreateParams memory p) private {
        emit RaiseMetadata(id, p.name, p.symbol, p.image, p.website, p.x, p.telegram);
    }

    // -------------------------------------------------------------------------------------------------------
    // contribute (spec section 4.2): Task 3
    // -------------------------------------------------------------------------------------------------------

    // -------------------------------------------------------------------------------------------------------
    // finalize and the launch (spec section 4.2, steps 1 to 6 of `_finalize`): Task 4
    // -------------------------------------------------------------------------------------------------------

    // -------------------------------------------------------------------------------------------------------
    // The PoolManager callback: mint at launch, poke at fee collection: Tasks 4 and 6
    // -------------------------------------------------------------------------------------------------------

    // -------------------------------------------------------------------------------------------------------
    // After launch: claims, creator vesting, fee collection, payout: Tasks 5 and 6
    // -------------------------------------------------------------------------------------------------------

    // -------------------------------------------------------------------------------------------------------
    // refund (spec section 4.2): Task 5
    // -------------------------------------------------------------------------------------------------------

    // -------------------------------------------------------------------------------------------------------
    // Owner settings (Ownable2Step: a transfer takes effect only when the new owner accepts)
    // -------------------------------------------------------------------------------------------------------

    /// @inheritdoc ISVLaunchpad
    function setFee(uint16 bps) external onlyOwner nonReentrant {
        if (bps > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = bps;
        emit FeeChanged(bps);
    }

    /// @inheritdoc ISVLaunchpad
    /// @dev Zero is refused so fees can never be burned by mistake.
    function setFeeWallet(address wallet) external onlyOwner nonReentrant {
        if (wallet == address(0)) revert ZeroAddress();
        feeWallet = wallet;
        emit FeeWalletChanged(wallet);
    }

    /// @inheritdoc ISVLaunchpad
    /// @dev `maxTarget == 0` disables the asset; otherwise `0 < minTarget <= maxTarget`. Only enabled assets
    ///      can reach the maths, so no fee-on-transfer or rebasing token ever does.
    function setQuote(address asset, uint256 minTarget, uint256 maxTarget) external onlyOwner nonReentrant {
        if (asset == address(0)) revert ZeroAddress();
        if (maxTarget != 0 && (minTarget == 0 || minTarget > maxTarget)) revert TargetOutOfRange();
        quoteLimits[asset] = Quote({minTarget: minTarget, maxTarget: maxTarget});
        emit QuoteChanged(asset, minTarget, maxTarget);
    }

    /// @inheritdoc ISVLaunchpad
    /// @dev Any address is accepted: `create` reads its `balanceOf` with a capped static call and counts a
    ///      holder only on a successful one-word reply above zero, so a wrong address closes creation to
    ///      everyone until it is corrected, and can do nothing else.
    function setLauncherGate(address nft) external onlyOwner nonReentrant {
        launcherGate = nft;
        emit LauncherGateChanged(nft);
    }

    /// @inheritdoc ISVLaunchpad
    /// @dev Applies to raises created after this call; a raise keeps the share it was created with.
    function setCreatorFeeShare(uint16 bps) external onlyOwner nonReentrant {
        if (bps > BPS) revert FeeTooHigh();
        creatorFeeShareBps = bps;
        emit CreatorFeeShareChanged(bps);
    }

    /// @inheritdoc ISVLaunchpad
    function setCreationOpen(bool open) external onlyOwner nonReentrant {
        creationOpen = open;
        emit CreationOpenChanged(open);
    }

    /// @notice Disabled: a launchpad with no owner could never change its fee wallet or its quotes again.
    /// @dev Overrides OpenZeppelin's `renounceOwnership`, which would otherwise leave the contract ownerless.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // -------------------------------------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------------------------------------

    /// @inheritdoc ISVLaunchpad
    function getRaise(uint256 id) external view returns (Raise memory) {
        return raises[id];
    }

    /// @inheritdoc ISVLaunchpad
    function poolManager() external view returns (IPoolManager) {
        return POOL_MANAGER;
    }

    /// @inheritdoc ISVLaunchpad
    function permit2() external view returns (ISignatureTransfer) {
        return PERMIT2;
    }

    // -------------------------------------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------------------------------------

    /// @dev The gate check, as the router's Suits check: a raw static call with a gas allowance; the caller
    ///      counts as allowed only when the call succeeds, the reply is exactly one word and that word is above
    ///      zero. A high-level call would not do: decoding a missing or short reply reverts outside try/catch.
    function _mayLaunch(address account) private view returns (bool) {
        address gate = launcherGate;
        if (gate == address(0)) return true;
        (bool ok, bytes memory reply) =
            gate.staticcall{gas: GATE_CHECK_GAS}(abi.encodeCall(IERC721.balanceOf, (account)));
        return ok && reply.length == 32 && abi.decode(reply, (uint256)) > 0;
    }

    /// @dev Name 1 to 32 bytes, symbol 1 to 11, each link at most 256; one error for every bound.
    function _checkText(CreateParams calldata p) private pure {
        uint256 nameLength = bytes(p.name).length;
        uint256 symbolLength = bytes(p.symbol).length;
        if (nameLength == 0 || nameLength > NAME_MAX_BYTES) revert TextTooLong();
        if (symbolLength == 0 || symbolLength > SYMBOL_MAX_BYTES) revert TextTooLong();
        if (bytes(p.image).length > LINK_MAX_BYTES || bytes(p.website).length > LINK_MAX_BYTES) revert TextTooLong();
        if (bytes(p.x).length > LINK_MAX_BYTES || bytes(p.telegram).length > LINK_MAX_BYTES) revert TextTooLong();
    }

    /// @dev Reverts with `ZeroAddress()` for the zero address, otherwise returns the input unchanged. Used in the
    ///      constructor's `Ownable` argument, which is evaluated before any base constructor runs.
    function _nonZero(address account) private pure returns (address) {
        if (account == address(0)) revert ZeroAddress();
        return account;
    }
}
```

Note: `POOL_TOKENS`, `CREATOR_TOKENS`, `STATUS_LAUNCHED` and `STATUS_CLOSED` are unused until Tasks 4 and 5; the compiler does not warn on unused constants. The `: Task N` suffixes on the five empty banners are placeholders: each named task drops the suffix when it fills the section, so none ships in `src/SVLaunchpad.sol`.

- [ ] **Step 10: Run the suite to verify it passes**

Run: `forge test --match-path 'test/unit/SVLaunchpad.t.sol' -vv`
Expected: `27 passed, 0 failed`. Then `forge build --sizes` (SVLaunchpad well under 24,576 bytes; the exact figure grows through Task 6, to about 20,500; the table also lists `PoolManager` at 19,766 bytes, pulled in by the tests since Task 1, and from Task 8 on a second `SVRouter.launchpad` row, the 200-run variant compiled for the fork test that imports both contracts, while the router's own row stays 7,647 bytes), `forge fmt --check`, `forge lint`, `forge test`, `forge coverage --report summary` (`src/SVLaunchpad.sol` and `src/libraries/LaunchMath.sol` at 100 % on the four columns; `src/SVLaunchToken.sol` at 100 %).

- [ ] **Step 11: Commit**

```bash
git add foundry.toml src/libraries/LaunchMath.sol src/SVLaunchpad.sol src/interfaces/ISVLaunchpad.sol test/utils/LaunchMathHarness.sol test/unit/LaunchMath.t.sol test/unit/SVLaunchpad.t.sol
git commit -m "Add SVLaunchpad settings and create, LaunchMath with both currency orders, the unit fixture

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016tofArVnM9erCZUwPku467"
```

### Task 3: `contribute` through Permit2: the window, the caps, the trimming

**Files:**
- Modify: `src/SVLaunchpad.sol` (the `contribute` section)
- Modify: `src/interfaces/ISVLaunchpad.sol` (declare `contribute`)
- Create: `test/utils/SVLaunchpadHarness.sol`
- Modify: `test/unit/SVLaunchpad.t.sol` (fixture: add `_contribute` and `_fill`)
- Test: `test/unit/SVLaunchpad.contribute.t.sol`

**Interfaces:**
- Consumes: fixture `SVLaunchpadTestBase` (`launchpad`, `usdg`, `stk`, `creator`, `stranger`, `permit2`, `nextNonce`, `_contributorKey(i)`, `_contributor(i)`, `_create(quote, target)`, `_params(quote, target)`, `USDG_TARGET`, `USDG_MINT`); `Permit2Signer.sign(uint256 privateKey, address permit2, ISignatureTransfer.PermitTransferFrom memory permit, address spender) returns (bytes memory)`; Permit2's single-token `permitTransferFrom(PermitTransferFrom, SignatureTransferDetails, address owner, bytes signature)`.
- Produces: `function contribute(uint256 id, uint256 amount, ISignatureTransfer.PermitTransferFrom calldata permit, bytes calldata signature) external` (spec steps 1 to 4; step 5, the auto-launch, is appended by Task 4); fixture helpers `_contribute(uint256 privateKey, uint256 id, uint256 amount)` and `_fill(uint256 id)` (ten wallets at the cap, in key order 0 to 9); `contract SVLaunchpadHarness is SVLaunchpad` with `exposed_setRaised(uint256 id, uint256 raised)`.

- [ ] **Step 1: Write the harness and the fixture helpers**

`test/utils/SVLaunchpadHarness.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {SVLaunchpad} from "../../src/SVLaunchpad.sol";

/// @notice `SVLaunchpad` with one back door: it can set a raise's `raised` directly, to reach states the
///         contract never produces on its own (a raise at its target that did not launch), so the guards the
///         spec keeps for that state are still exercised. Unit tests only.
contract SVLaunchpadHarness is SVLaunchpad {
    constructor(
        IPoolManager poolManager_,
        ISignatureTransfer permit2_,
        address owner_,
        address feeWallet_,
        uint16 feeBps_,
        uint16 creatorFeeShareBps_
    ) SVLaunchpad(poolManager_, permit2_, owner_, feeWallet_, feeBps_, creatorFeeShareBps_) {}

    function exposed_setRaised(uint256 id, uint256 raised) external {
        raises[id].raised = raised;
    }
}
```

Append to the fixture helpers of `abstract contract SVLaunchpadTestBase` in `test/unit/SVLaunchpad.t.sol` (after `_createWithFloor`), and add `import {Permit2Signer} from "../utils/Permit2Signer.sol";` to that file's imports:

```solidity
    /// @dev One contribution as `privateKey`'s wallet: a Permit2 message for exactly `amount` of the raise's quote
    ///      at the next nonce, signed with this launchpad as the spender. Signed before the prank on purpose:
    ///      signing reads Permit2's `DOMAIN_SEPARATOR()`, an external call, which would otherwise consume the
    ///      pending prank.
    function _contribute(uint256 privateKey, uint256 id, uint256 amount) internal {
        address wallet = vm.addr(privateKey);
        ISVLaunchpad.Raise memory r = launchpad.getRaise(id);
        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: r.quote, amount: amount}),
            nonce: nextNonce++,
            deadline: block.timestamp + 1 hours
        });
        bytes memory signature = Permit2Signer.sign(privateKey, permit2, permit, address(launchpad));
        vm.prank(wallet);
        launchpad.contribute(id, amount, permit, signature);
    }

    /// @dev Ten wallets at the 10 % cap fill the raise; from Task 4 on, the tenth contribution launches it.
    function _fill(uint256 id) internal {
        uint256 target = launchpad.getRaise(id).target;
        for (uint256 i = 0; i < CONTRIBUTORS; i++) {
            _contribute(_contributorKey(i), id, target / CONTRIBUTORS);
        }
    }
```

- [ ] **Step 2: Write the failing tests**

`test/unit/SVLaunchpad.contribute.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {SVLaunchpadHarness} from "../utils/SVLaunchpadHarness.sol";
import {ISVLaunchpad} from "../../src/interfaces/ISVLaunchpad.sol";
import {Permit2Signer} from "../utils/Permit2Signer.sol";
import {SVLaunchpadTestBase} from "./SVLaunchpad.t.sol";

/// @notice `contribute` (spec section 4.2): the window, the 10 % cap, trimming of the last contribution, the
///         Permit2 pull of exactly the trimmed amount, and every revert.
contract SVLaunchpadContributeTest is SVLaunchpadTestBase {
    /// @dev The selector of the single-transfer `permitTransferFrom`, written out because the name is
    ///      overloaded in Permit2, which makes `.selector` on it ambiguous.
    bytes4 internal constant PERMIT_PULL =
        bytes4(keccak256("permitTransferFrom(((address,uint256),uint256,uint256),(address,uint256),address,bytes)"));

    uint256 internal id;
    uint256 internal cap;

    function setUp() public override {
        super.setUp();
        id = _create(address(usdg), USDG_TARGET);
        cap = USDG_TARGET / 10;
    }

    function test_contribute_pulls_the_amount_accounts_it_and_emits() public {
        vm.expectEmit(true, true, true, true, address(launchpad));
        emit ISVLaunchpad.Contributed(id, _contributor(0), 100e6, 100e6);
        _contribute(_contributorKey(0), id, 100e6);
        assertEq(usdg.balanceOf(_contributor(0)), USDG_MINT - 100e6, "the wallet paid");
        assertEq(usdg.balanceOf(address(launchpad)), 100e6, "the launchpad holds it");
        assertEq(launchpad.contributed(id, _contributor(0)), 100e6, "contributed");
        assertEq(launchpad.getRaise(id).raised, 100e6, "raised");
        _contribute(_contributorKey(0), id, 50e6);
        assertEq(launchpad.contributed(id, _contributor(0)), 150e6, "a second contribution adds up");
        assertEq(launchpad.getRaise(id).raised, 150e6, "raised adds up");
    }

    function test_contribute_trims_to_the_wallet_cap_and_pulls_only_the_trimmed_amount() public {
        vm.expectEmit(true, true, true, true, address(launchpad));
        emit ISVLaunchpad.Contributed(id, _contributor(0), cap, cap);
        _contribute(_contributorKey(0), id, cap + 1e6);
        assertEq(launchpad.contributed(id, _contributor(0)), cap, "trimmed to 10 % of the target");
        assertEq(usdg.balanceOf(_contributor(0)), USDG_MINT - cap, "only the trimmed amount left the wallet");
    }

    function test_contribute_reverts_WalletCapReached_once_the_wallet_is_at_its_cap() public {
        _contribute(_contributorKey(0), id, cap);
        vm.expectCall(permit2, abi.encodePacked(PERMIT_PULL), 0);
        ISignatureTransfer.PermitTransferFrom memory permit = _permit(address(usdg), 1);
        bytes memory signature = Permit2Signer.sign(_contributorKey(0), permit2, permit, address(launchpad));
        vm.prank(_contributor(0));
        vm.expectRevert(ISVLaunchpad.WalletCapReached.selector);
        launchpad.contribute(id, 1, permit, signature);
    }

    function test_contribute_trims_the_last_contribution_to_what_is_left_in_the_raise() public {
        // Half a cap from the creator and nine wallets at the cap leave half a cap of room; the tenth wallet
        // offers a whole cap, which its own cap would allow, and is trimmed by the raise instead.
        _contribute(CREATOR_KEY, id, cap / 2);
        for (uint256 i = 0; i < 9; i++) {
            _contribute(_contributorKey(i), id, cap);
        }
        vm.expectEmit(true, true, true, true, address(launchpad));
        emit ISVLaunchpad.Contributed(id, _contributor(9), cap / 2, USDG_TARGET);
        _contribute(_contributorKey(9), id, cap);
        assertEq(launchpad.getRaise(id).raised, USDG_TARGET, "the raise is at its target");
        assertEq(launchpad.contributed(id, _contributor(9)), cap / 2, "the tenth wallet was trimmed to the room");
        assertEq(usdg.balanceOf(_contributor(9)), USDG_MINT - cap / 2, "and paid only that");
    }

    function test_contribute_reverts_RaiseFull_when_nothing_is_left_to_take() public {
        // Unreachable by construction from Task 4 on (a filled raise launches in the same transaction), kept as
        // belt-and-braces by the spec; reached through the harness.
        SVLaunchpadHarness harness = new SVLaunchpadHarness(
            manager, ISignatureTransfer(permit2), owner, feeWallet, FEE_BPS, CREATOR_FEE_SHARE_BPS
        );
        vm.prank(owner);
        harness.setQuote(address(usdg), USDG_MIN, USDG_MAX);
        vm.prank(creator);
        uint256 full = harness.create(_params(address(usdg), USDG_TARGET));
        harness.exposed_setRaised(full, USDG_TARGET);
        ISignatureTransfer.PermitTransferFrom memory permit = _permit(address(usdg), 1);
        bytes memory signature = Permit2Signer.sign(_contributorKey(0), permit2, permit, address(harness));
        vm.prank(_contributor(0));
        vm.expectRevert(ISVLaunchpad.RaiseFull.selector);
        harness.contribute(full, 1, permit, signature);
    }

    function test_contribute_reverts_NotOpen_for_an_unknown_raise() public {
        ISignatureTransfer.PermitTransferFrom memory permit = _permit(address(usdg), 1e6);
        bytes memory signature = Permit2Signer.sign(_contributorKey(0), permit2, permit, address(launchpad));
        vm.prank(_contributor(0));
        vm.expectRevert(ISVLaunchpad.NotOpen.selector);
        launchpad.contribute(999, 1e6, permit, signature);
    }

    function test_contribute_reverts_NotStarted_before_the_start() public {
        ISVLaunchpad.CreateParams memory p = _params(address(usdg), USDG_TARGET);
        p.start = _now() + 1 hours;
        vm.prank(creator);
        uint256 later = launchpad.create(p);
        ISignatureTransfer.PermitTransferFrom memory permit = _permit(address(usdg), 1e6);
        bytes memory signature = Permit2Signer.sign(_contributorKey(0), permit2, permit, address(launchpad));
        vm.prank(_contributor(0));
        vm.expectRevert(ISVLaunchpad.NotStarted.selector);
        launchpad.contribute(later, 1e6, permit, signature);
        vm.warp(block.timestamp + 1 hours);
        _contribute(_contributorKey(0), later, 1e6);
        assertEq(launchpad.getRaise(later).raised, 1e6, "contributes once started");
    }

    function test_contribute_reverts_Ended_at_and_after_the_deadline() public {
        vm.warp(block.timestamp + 1 days);
        ISignatureTransfer.PermitTransferFrom memory permit = _permit(address(usdg), 1e6);
        bytes memory signature = Permit2Signer.sign(_contributorKey(0), permit2, permit, address(launchpad));
        vm.prank(_contributor(0));
        vm.expectRevert(ISVLaunchpad.Ended.selector);
        launchpad.contribute(id, 1e6, permit, signature);
    }

    function test_contribute_reverts_ZeroAmount() public {
        ISignatureTransfer.PermitTransferFrom memory permit = _permit(address(usdg), 1e6);
        bytes memory signature = Permit2Signer.sign(_contributorKey(0), permit2, permit, address(launchpad));
        vm.prank(_contributor(0));
        vm.expectRevert(ISVLaunchpad.ZeroAmount.selector);
        launchpad.contribute(id, 0, permit, signature);
    }

    function test_contribute_reverts_PermitMismatch_for_another_token_or_a_short_permit() public {
        vm.expectCall(permit2, abi.encodePacked(PERMIT_PULL), 0);
        ISignatureTransfer.PermitTransferFrom memory wrongToken = _permit(address(stk), 1e6);
        bytes memory signature = Permit2Signer.sign(_contributorKey(0), permit2, wrongToken, address(launchpad));
        vm.prank(_contributor(0));
        vm.expectRevert(ISVLaunchpad.PermitMismatch.selector);
        launchpad.contribute(id, 1e6, wrongToken, signature);
        ISignatureTransfer.PermitTransferFrom memory tooSmall = _permit(address(usdg), 1e6 - 1);
        signature = Permit2Signer.sign(_contributorKey(0), permit2, tooSmall, address(launchpad));
        vm.prank(_contributor(0));
        vm.expectRevert(ISVLaunchpad.PermitMismatch.selector);
        launchpad.contribute(id, 1e6, tooSmall, signature);
    }

    function test_a_permit_signed_for_more_than_the_amount_is_accepted_and_only_the_amount_is_pulled() public {
        ISignatureTransfer.PermitTransferFrom memory permit = _permit(address(usdg), 10e6);
        bytes memory signature = Permit2Signer.sign(_contributorKey(0), permit2, permit, address(launchpad));
        vm.prank(_contributor(0));
        launchpad.contribute(id, 1e6, permit, signature);
        assertEq(usdg.balanceOf(_contributor(0)), USDG_MINT - 1e6, "only the amount was pulled");
    }

    function test_permit2_rejects_a_reused_nonce_and_a_signature_by_someone_else() public {
        ISignatureTransfer.PermitTransferFrom memory permit = _permit(address(usdg), 1e6);
        bytes memory signature = Permit2Signer.sign(_contributorKey(0), permit2, permit, address(launchpad));
        vm.prank(_contributor(0));
        launchpad.contribute(id, 1e6, permit, signature);
        vm.prank(_contributor(0));
        vm.expectRevert(abi.encodeWithSignature("InvalidNonce()"));
        launchpad.contribute(id, 1e6, permit, signature);
        ISignatureTransfer.PermitTransferFrom memory other = _permit(address(usdg), 1e6);
        bytes memory strangerSignature = Permit2Signer.sign(STRANGER_KEY, permit2, other, address(launchpad));
        vm.prank(_contributor(0));
        vm.expectRevert(abi.encodeWithSignature("InvalidSigner()"));
        launchpad.contribute(id, 1e6, other, strangerSignature);
    }

    function test_the_creator_contributes_like_anyone_under_the_same_cap() public {
        _contribute(CREATOR_KEY, id, cap + 1);
        assertEq(launchpad.contributed(id, creator), cap, "the creator is capped too");
    }

    function _permit(address token, uint256 amount)
        internal
        returns (ISignatureTransfer.PermitTransferFrom memory)
    {
        return ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: token, amount: amount}),
            nonce: nextNonce++,
            deadline: block.timestamp + 1 hours
        });
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `forge test --match-path test/unit/SVLaunchpad.contribute.t.sol`
Expected: compilation fails, `Member "contribute" not found or not visible after argument-dependent lookup in contract SVLaunchpad`.

- [ ] **Step 4: Declare `contribute` in the interface**

In `src/interfaces/ISVLaunchpad.sol`, directly after the `create` declaration:

```solidity
    /// @notice Contribute up to `amount` of the raise's quote asset, trimmed to what fits in the raise and under
    ///         the caller's 10 % cap; the trimmed amount is pulled through Permit2. Fills the raise and launches
    ///         it in the same transaction when the target is reached.
    /// @param permit The Permit2 message the caller signed: `permitted.token` must be the raise's quote and
    ///               `permitted.amount` at least `amount`; the spender is this launchpad.
    function contribute(
        uint256 id,
        uint256 amount,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) external;
```

- [ ] **Step 5: Implement `contribute`**

In `src/SVLaunchpad.sol`, under the `contribute` banner (drop the banner's `: Task 3` suffix while filling the section):

```solidity
    /// @inheritdoc ISVLaunchpad
    /// @dev Spec steps: 1. status, window, amount and the permit's token; 2. trim to what fits in the raise and
    ///      under the caller's cap, reverting when nothing fits; 3. pull exactly the trimmed amount through
    ///      Permit2 (the signed amount may exceed it); 4. account and emit; 5. launch when the target is reached,
    ///      so a filled raise is never left waiting for someone to launch it.
    function contribute(
        uint256 id,
        uint256 amount,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) external nonReentrant {
        Raise storage r = raises[id];
        // 1.
        if (r.status != STATUS_OPEN) revert NotOpen();
        if (block.timestamp < r.start) revert NotStarted();
        if (block.timestamp >= r.deadline) revert Ended();
        if (amount == 0) revert ZeroAmount();
        if (permit.permitted.token != r.quote || permit.permitted.amount < amount) revert PermitMismatch();

        // 2.
        uint256 roomInRaise = r.target - r.raised;
        if (roomInRaise == 0) revert RaiseFull();
        uint256 roomInWallet = r.target * WALLET_CAP_BPS / BPS - contributed[id][msg.sender];
        if (roomInWallet == 0) revert WalletCapReached();
        uint256 take = amount;
        if (take > roomInRaise) take = roomInRaise;
        if (take > roomInWallet) take = roomInWallet;

        // 3.
        PERMIT2.permitTransferFrom(
            permit,
            ISignatureTransfer.SignatureTransferDetails({to: address(this), requestedAmount: take}),
            msg.sender,
            signature
        );

        // 4.
        r.raised += take;
        contributed[id][msg.sender] += take;
        emit Contributed(id, msg.sender, take, r.raised);
    }
```

(Step 5 of the spec, `if (r.raised == r.target) _finalize(id);`, is appended by Task 4 once `_finalize` exists.)

- [ ] **Step 6: Run the tests to verify they pass**

Run: `forge test --match-path 'test/unit/SVLaunchpad*.t.sol' -vv`
Expected: `SVLaunchpadContributeTest`: `13 passed`; `SVLaunchpadTest` unchanged. Gates: `forge fmt --check`, `forge lint`, `forge test`, `forge coverage --report summary` (`src/SVLaunchpad.sol` still 100 % on the four columns).

- [ ] **Step 7: Commit**

```bash
git add src/SVLaunchpad.sol src/interfaces/ISVLaunchpad.sol test/utils/SVLaunchpadHarness.sol test/unit/SVLaunchpad.t.sol test/unit/SVLaunchpad.contribute.t.sol
git commit -m "SVLaunchpad: contribute through Permit2 with the wallet cap and last-contribution trimming

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016tofArVnM9erCZUwPku467"
```

### Task 4: The launch: CREATE2 token, price, `initialize`, the position through `unlock`, burn, `Finalized`

**Files:**
- Modify: `src/SVLaunchpad.sol` (imports, `IUnlockCallback`, the launch and callback sections, `poolKey`, `_poolKey`, the auto-launch line in `contribute`)
- Modify: `src/interfaces/ISVLaunchpad.sol` (declare `finalize`, `poolKey`)
- Modify: `test/unit/SVLaunchpad.t.sol` (fixture: launch helpers)
- Test: `test/unit/SVLaunchpad.launch.t.sol`

**Interfaces:**
- Consumes: `LaunchMath.sqrtPriceX96For`; `SVLaunchToken` constructor and `burn`; v4-core `IPoolManager.initialize(PoolKey, uint160)`, `unlock(bytes) returns (bytes)`, `modifyLiquidity(PoolKey, ModifyLiquidityParams{tickLower, tickUpper, liquidityDelta, salt}, bytes) returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)`, `sync(Currency)`, `settle() returns (uint256)`; `IUnlockCallback.unlockCallback(bytes) returns (bytes)`; `TickMath.getSqrtPriceAtTick(int24)`; `FullMath.mulDiv`; v4-periphery `LiquidityAmounts.getLiquidityForAmounts(uint160 sqrtPriceX96, uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount0, uint256 amount1) returns (uint128)`; OZ `TransientSlot` (`bytes32.asBoolean().tload()/tstore(bool)`), `SafeERC20.safeTransfer`; test-side `StateLibrary.getSlot0(IPoolManager, PoolId)`, `StateLibrary.getPositionInfo(IPoolManager, PoolId, address owner, int24, int24, bytes32)`, `vm.computeCreate2Address(bytes32 salt, bytes32 initCodeHash, address deployer)`, `vm.recordLogs()/getRecordedLogs()`.
- Produces: `function finalize(uint256 id) external`; `function poolKey(uint256 id) external view returns (PoolKey memory)`; `function unlockCallback(bytes calldata data) external returns (bytes memory)` (from `IUnlockCallback`); private `_finalize(uint256)`, `_deployToken(uint256, string memory, string memory) returns (address)`, `_emitFinalized`, `_unlock(bytes memory) returns (bytes memory)`, `_mintPosition(CallbackData memory) returns (bytes memory)`, `_settle(Currency, int128) returns (uint256)`, `_poolKey(address token, address quote) returns (PoolKey memory)`; `struct CallbackData {uint8 action; uint256 id; uint256 amount0; uint256 amount1;}`; fixture: `struct Launched {address token; bytes32 poolId; uint160 sqrtPriceX96; uint256 raised; uint256 fee; uint256 quoteToPool; uint256 tokensToPool; uint256 tokensBurned; uint128 liquidity;}`, `_predictToken(uint256 id, uint256 blockNumber, address sender) returns (address)`, `_rollUntilTokenSide(uint256 id, address sender, bool tokenIsCurrency0)`, `_launched(uint256 id) returns (Launched memory)` (reads the recorded logs), `_positionLiquidity(uint256 id) returns (uint128)`, `_slot0Price(uint256 id) returns (uint160)`, `_launch(MockERC20 quote, uint256 target, bool tokenIsCurrency0) returns (uint256 id, Launched memory l)`.

- [ ] **Step 1: Add the launch helpers to the fixture**

In `test/unit/SVLaunchpad.t.sol` add these imports:

```solidity
import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SVLaunchToken} from "../../src/SVLaunchToken.sol";
```

add `using StateLibrary for IPoolManager;` as the first line inside `abstract contract SVLaunchpadTestBase`, and append after `_fill`:

```solidity
    /// @dev The data part of a `Finalized` event in its ABI order, so one `abi.decode` fills it (decoding seven
    ///      values straight into struct fields runs out of stack under the legacy code generator).
    struct FinalizedData {
        uint160 sqrtPriceX96;
        uint256 raised;
        uint256 fee;
        uint256 quoteToPool;
        uint256 tokensToPool;
        uint256 tokensBurned;
        uint128 liquidity;
    }

    /// @dev The values of one launch, read back from the `Finalized` event.
    struct Launched {
        address token;
        bytes32 poolId;
        uint160 sqrtPriceX96;
        uint256 raised;
        uint256 fee;
        uint256 quoteToPool;
        uint256 tokensToPool;
        uint256 tokensBurned;
        uint128 liquidity;
    }

    /// @dev The spec's CREATE2 address for the token of raise `id` if `sender` launches it in `blockNumber`:
    ///      salt `keccak256(abi.encode(id, block.number, msg.sender))`, init code = creation code ++ constructor
    ///      arguments, deployer = the launchpad.
    function _predictToken(uint256 id, uint256 blockNumber, address sender) internal view returns (address) {
        ISVLaunchpad.Raise memory r = launchpad.getRaise(id);
        bytes32 salt = keccak256(abi.encode(id, blockNumber, sender));
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(SVLaunchToken).creationCode, abi.encode(r.name, r.symbol, SUPPLY, address(launchpad)))
        );
        return vm.computeCreate2Address(salt, initCodeHash, address(launchpad));
    }

    /// @dev Rolls forward until the token `sender` would deploy lands on the wanted side of the quote address,
    ///      so both currency orders are tested against the spec's real salt rather than a forced address. Each
    ///      block is a fair coin; 256 tries never fail in practice.
    function _rollUntilTokenSide(uint256 id, address sender, bool tokenIsCurrency0) internal {
        address quote = launchpad.getRaise(id).quote;
        for (uint256 i = 0; i < 256; i++) {
            if ((_predictToken(id, block.number, sender) < quote) == tokenIsCurrency0) return;
            vm.roll(block.number + 1);
        }
        revert("no block number within 256 puts the token on the wanted side of the quote");
    }

    /// @dev The `Finalized` event of raise `id` in the logs recorded since the last `vm.recordLogs()`.
    function _launched(uint256 id) internal returns (Launched memory l) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(launchpad) || logs[i].topics[0] != ISVLaunchpad.Finalized.selector) continue;
            assertEq(uint256(logs[i].topics[1]), id, "Finalized.id");
            l.token = address(uint160(uint256(logs[i].topics[2])));
            l.poolId = logs[i].topics[3];
            FinalizedData memory d = abi.decode(logs[i].data, (FinalizedData));
            l.sqrtPriceX96 = d.sqrtPriceX96;
            l.raised = d.raised;
            l.fee = d.fee;
            l.quoteToPool = d.quoteToPool;
            l.tokensToPool = d.tokensToPool;
            l.tokensBurned = d.tokensBurned;
            l.liquidity = d.liquidity;
            return l;
        }
        revert("no Finalized event in the recorded logs");
    }

    function _positionLiquidity(uint256 id) internal view returns (uint128 liquidity) {
        PoolKey memory key = launchpad.poolKey(id);
        (liquidity,,) = manager.getPositionInfo(key.toId(), address(launchpad), TICK_LOWER, TICK_UPPER, bytes32(0));
    }

    function _slot0Price(uint256 id) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = manager.getSlot0(launchpad.poolKey(id).toId());
    }

    /// @dev Create, put the token on the wanted side of the quote for the tenth contributor's launch, fill.
    function _launch(MockERC20 quote, uint256 target, bool tokenIsCurrency0)
        internal
        returns (uint256 id, Launched memory l)
    {
        id = _create(address(quote), target);
        _rollUntilTokenSide(id, _contributor(CONTRIBUTORS - 1), tokenIsCurrency0);
        vm.recordLogs();
        _fill(id);
        l = _launched(id);
    }
```

- [ ] **Step 2: Write the failing tests**

`test/unit/SVLaunchpad.launch.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {SVLaunchpadHarness} from "../utils/SVLaunchpadHarness.sol";
import {ISVLaunchpad} from "../../src/interfaces/ISVLaunchpad.sol";
import {SVLaunchToken} from "../../src/SVLaunchToken.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {Permit2Signer} from "../utils/Permit2Signer.sol";
import {SVLaunchpadTestBase} from "./SVLaunchpad.t.sol";

/// @notice The launch (spec section 4.2 `_finalize` steps 1 to 6 and section 4.3) on the local PoolManager:
///         both quote decimals, both currency orders, the floor path, the burn and dust accounting, the
///         callback guards, and the gas of the launching contribution.
contract SVLaunchpadLaunchTest is SVLaunchpadTestBase {
    /// @dev Every assertion the spec makes about a filled raise's launch, for one quote and one currency order.
    function _assertLaunch(MockERC20 quote, uint256 target, bool tokenIs0) internal {
        (uint256 id, Launched memory l) = _launch(quote, target, tokenIs0);
        ISVLaunchpad.Raise memory r = launchpad.getRaise(id);
        assertEq(r.status, 2, "status Launched");
        assertEq(r.launchedAt, block.timestamp, "launchedAt");
        assertEq(r.token, l.token, "token stored");
        assertEq(
            r.token, _predictToken(id, block.number, _contributor(CONTRIBUTORS - 1)), "CREATE2 with the spec's salt"
        );
        assertEq(l.token < address(quote), tokenIs0, "the token is on the wanted side of the quote");
        // 4.3: the pool's price is the stored price, the position's liquidity the stored liquidity.
        assertEq(_slot0Price(id), r.sqrtPriceX96, "slot0 price equals the stored sqrtPriceX96");
        assertEq(l.sqrtPriceX96, r.sqrtPriceX96, "the event carries the price");
        uint160 expected = tokenIs0
            ? uint160(Math.sqrt(FullMath.mulDiv(target, uint256(1) << 192, SALE_TOKENS)))
            : uint160(Math.sqrt(FullMath.mulDiv(SALE_TOKENS, uint256(1) << 192, target)));
        assertEq(r.sqrtPriceX96, expected, "the price is the spec's formula in the pool's currency order");
        assertGt(r.liquidity, 0, "liquidity above zero");
        assertEq(_positionLiquidity(id), r.liquidity, "position liquidity equals the stored liquidity");
        assertEq(l.liquidity, r.liquidity, "the event carries the liquidity");
        // The pool key: derived, hookless, 1 %, spacing 200.
        PoolKey memory key = launchpad.poolKey(id);
        assertEq(Currency.unwrap(key.currency0), tokenIs0 ? l.token : address(quote), "currency0");
        assertEq(Currency.unwrap(key.currency1), tokenIs0 ? address(quote) : l.token, "currency1");
        assertEq(key.fee, 10_000, "1 % LP fee");
        assertEq(key.tickSpacing, 200, "tick spacing 200");
        assertEq(address(key.hooks), address(0), "no hook");
        assertEq(PoolId.unwrap(key.toId()), l.poolId, "the event carries the pool id");
        // Money: fee, net, what the pool took, the dust, the burn.
        assertEq(l.raised, target, "raised");
        assertEq(l.fee, target * FEE_BPS / 10_000, "fee = raised * feeBps / 10000");
        uint256 net = target - l.fee;
        uint256 tokensForPool = FullMath.mulDiv(net, SALE_TOKENS, target);
        assertLe(l.quoteToPool, net, "the pool took at most the net raise");
        assertGe(l.quoteToPool, net - net / 1e9 - 1, "the pool took the net raise within a billionth");
        assertLe(l.tokensToPool, tokensForPool, "the pool took at most the tokens offered");
        assertGe(
            l.tokensToPool, tokensForPool - tokensForPool / 1e9 - 1, "the pool took the tokens within a billionth"
        );
        assertEq(l.tokensBurned, POOL_TOKENS - l.tokensToPool, "a filled raise burns only the pool tokens not used");
        assertEq(SVLaunchToken(l.token).totalSupply(), SUPPLY - l.tokensBurned, "supply after the burn");
        assertEq(
            SVLaunchToken(l.token).balanceOf(address(launchpad)),
            SALE_TOKENS + CREATOR_TOKENS,
            "the launchpad keeps the sale tokens for claims and the creator tokens for vesting"
        );
        assertEq(
            quote.balanceOf(feeWallet), l.fee + (net - l.quoteToPool), "fee wallet: the fee plus the unused quote"
        );
        assertEq(quote.balanceOf(address(launchpad)), 0, "the launchpad holds no quote after the launch");
    }

    function test_launch_with_a_6_decimal_quote_and_the_token_as_currency0() public {
        _assertLaunch(usdg, USDG_TARGET, true);
    }

    function test_launch_with_a_6_decimal_quote_and_the_token_as_currency1() public {
        _assertLaunch(usdg, USDG_TARGET, false);
    }

    function test_launch_with_an_18_decimal_quote_and_the_token_as_currency0() public {
        _assertLaunch(stk, STK_TARGET, true);
    }

    function test_launch_with_an_18_decimal_quote_and_the_token_as_currency1() public {
        _assertLaunch(stk, STK_TARGET, false);
    }

    function test_the_tenth_contribution_launches_in_the_same_transaction_and_costs_under_3_million_gas() public {
        uint256 id = _create(address(usdg), USDG_TARGET);
        for (uint256 i = 0; i < CONTRIBUTORS - 1; i++) {
            _contribute(_contributorKey(i), id, USDG_TARGET / CONTRIBUTORS);
        }
        assertEq(launchpad.getRaise(id).status, 1, "still Open at 90 %");
        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(usdg), amount: USDG_TARGET / CONTRIBUTORS}),
            nonce: nextNonce++,
            deadline: block.timestamp + 1 hours
        });
        bytes memory signature = Permit2Signer.sign(_contributorKey(9), permit2, permit, address(launchpad));
        vm.prank(_contributor(9));
        uint256 gasBefore = gasleft();
        launchpad.contribute(id, USDG_TARGET / CONTRIBUTORS, permit, signature);
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("gas of the launching contribution", gasUsed);
        assertLt(gasUsed, 3_000_000, "one token deployment, one initialize, one position mint");
        assertEq(launchpad.getRaise(id).status, 2, "Launched by the filling contribution");
    }

    function test_finalize_launches_a_raise_past_its_deadline_at_or_above_its_floor_burning_the_unsold_tokens() public {
        uint256 id = _createWithFloor(address(usdg), USDG_TARGET, USDG_TARGET / 2);
        // Six wallets at the cap: 60 % of the target, above the 50 % floor.
        for (uint256 i = 0; i < 6; i++) {
            _contribute(_contributorKey(i), id, USDG_TARGET / 10);
        }
        vm.prank(stranger);
        vm.expectRevert(ISVLaunchpad.NotLaunchable.selector);
        launchpad.finalize(id); // not yet: the deadline has not passed
        vm.warp(block.timestamp + 1 days);
        _rollUntilTokenSide(id, stranger, true);
        vm.recordLogs();
        vm.prank(stranger);
        launchpad.finalize(id);
        Launched memory l = _launched(id);
        uint256 raised = USDG_TARGET * 6 / 10;
        uint256 fee = raised * FEE_BPS / 10_000;
        uint256 soldTokens = raised * SALE_TOKENS / USDG_TARGET;
        assertEq(l.raised, raised, "raised 60 %");
        assertEq(l.fee, fee, "fee on what was raised");
        assertEq(
            l.tokensBurned,
            (SALE_TOKENS - soldTokens) + (POOL_TOKENS - l.tokensToPool),
            "unsold and unused tokens burned"
        );
        assertEq(
            SVLaunchToken(l.token).balanceOf(address(launchpad)),
            soldTokens + CREATOR_TOKENS,
            "sold and creator tokens kept"
        );
        assertEq(_slot0Price(id), launchpad.getRaise(id).sqrtPriceX96, "pool price equals the stored price");
        assertGe(l.quoteToPool, (raised - fee) - (raised - fee) / 1e9 - 1, "the net raise is in the pool");
        assertEq(launchpad.getRaise(id).creator, creator, "a stranger launched it; the creator is unchanged");
    }

    function test_finalize_reverts_NotLaunchable_under_the_floor_and_NotOpen_after_launch_or_unknown() public {
        uint256 id = _createWithFloor(address(usdg), USDG_TARGET, USDG_TARGET / 2);
        _contribute(_contributorKey(0), id, USDG_TARGET / 10);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(ISVLaunchpad.NotLaunchable.selector);
        launchpad.finalize(id);
        (uint256 launched,) = _launch(stk, STK_TARGET, true);
        vm.expectRevert(ISVLaunchpad.NotOpen.selector);
        launchpad.finalize(launched);
        vm.expectRevert(ISVLaunchpad.NotOpen.selector);
        launchpad.finalize(999);
    }

    function test_finalize_launches_a_raise_sitting_at_its_target() public {
        // Unreachable by construction (a filled raise launches inside `contribute`); the spec keeps the path, so
        // it is reached through the harness, which holds the quote the launch will move.
        SVLaunchpadHarness harness = new SVLaunchpadHarness(
            manager, ISignatureTransfer(permit2), owner, feeWallet, FEE_BPS, CREATOR_FEE_SHARE_BPS
        );
        vm.prank(owner);
        harness.setQuote(address(usdg), USDG_MIN, USDG_MAX);
        vm.prank(creator);
        uint256 id = harness.create(_params(address(usdg), USDG_TARGET));
        usdg.mint(address(harness), USDG_TARGET);
        harness.exposed_setRaised(id, USDG_TARGET);
        vm.prank(stranger);
        harness.finalize(id);
        assertEq(harness.getRaise(id).status, 2, "launched from the filled state");
        assertEq(usdg.balanceOf(address(harness)), 0, "the quote went to the pool and the fee wallet");
    }

    function test_poolKey_reverts_NotLaunched_before_launch() public {
        uint256 id = _create(address(usdg), USDG_TARGET);
        vm.expectRevert(ISVLaunchpad.NotLaunched.selector);
        launchpad.poolKey(id);
    }

    function test_unlockCallback_refuses_everyone_but_the_pool_manager_and_the_pool_manager_outside_a_launch() public {
        vm.expectRevert(ISVLaunchpad.NotPoolManager.selector);
        launchpad.unlockCallback("");
        vm.prank(address(manager));
        vm.expectRevert(ISVLaunchpad.UnexpectedCallback.selector);
        launchpad.unlockCallback("");
    }

    function test_two_raises_launch_two_different_tokens_and_pools() public {
        (uint256 first, Launched memory a) = _launch(usdg, USDG_TARGET, true);
        (uint256 second, Launched memory b) = _launch(usdg, USDG_TARGET, false);
        assertTrue(a.token != b.token, "different tokens");
        assertTrue(a.poolId != b.poolId, "different pools");
        assertEq(_positionLiquidity(first), a.liquidity, "first position intact");
        assertEq(_positionLiquidity(second), b.liquidity, "second position intact");
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `forge test --match-path test/unit/SVLaunchpad.launch.t.sol`
Expected: compilation fails, `Member "poolKey" not found` (and `finalize`, `unlockCallback`).

- [ ] **Step 4: Declare `finalize` and `poolKey` in the interface**

In `src/interfaces/ISVLaunchpad.sol`, after the `contribute` declaration:

```solidity
    /// @notice Anyone. Launch an Open raise that is at its target, or past its deadline at or above its floor.
    function finalize(uint256 id) external;
```

and between `quoteLimits` and `poolManager` (the spec's order):

```solidity
    /// @notice The pool key of a launched raise; reverts `NotLaunched` before launch.
    function poolKey(uint256 id) external view returns (PoolKey memory);
```

- [ ] **Step 5: Implement the launch**

In `src/SVLaunchpad.sol`:

(a) Replace the import block with:

```solidity
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {ISVLaunchpad} from "./interfaces/ISVLaunchpad.sol";
import {LaunchMath} from "./libraries/LaunchMath.sol";
import {SVLaunchToken} from "./SVLaunchToken.sol";
```

(b) Change the contract line and add the `using` directives:

```solidity
contract SVLaunchpad is ISVLaunchpad, IUnlockCallback, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using TransientSlot for *;
```

(c) After `STATUS_CLOSED`, add:

```solidity
    uint8 private constant ACTION_MINT = 1;
    uint8 private constant ACTION_COLLECT = 2;
    /// @dev Transient slot holding the "an unlock of ours is in flight" flag read by `unlockCallback`.
    bytes32 private constant UNLOCK_SLOT = keccak256("SVLaunchpad.unlockInFlight");
```

(d) After `uint256 public nextId;`, add the two structs:

```solidity
    /// @dev What `unlock` carries to `unlockCallback`: which position operation, for which raise, and for a mint
    ///      the amounts offered in pool currency order.
    struct CallbackData {
        uint8 action;
        uint256 id;
        uint256 amount0;
        uint256 amount1;
    }

    /// @dev The launch's working values, gathered in memory so `_finalize` stays within the stack the legacy
    ///      code generator allows (via-IR is off by design, as in the router).
    struct Launch {
        uint256 raised;
        uint256 fee;
        uint256 net;
        address token;
        bool tokenIs0;
        uint160 sqrtPriceX96;
        uint256 tokensForPool;
        uint128 liquidity;
        uint256 used0;
        uint256 used1;
        uint256 quoteToPool;
        uint256 tokensToPool;
        uint256 tokensBurned;
    }
```

(e) In `contribute`, after `emit Contributed(id, msg.sender, take, r.raised);`, append:

```solidity

        // 5.
        if (r.raised == r.target) _finalize(id);
```

(f) Under the `finalize and the launch` banner (drop its `: Task 4` suffix; likewise drop `: Tasks 4 and 6` from the callback banner in (g)):

```solidity
    /// @inheritdoc ISVLaunchpad
    /// @dev A raise at its target launches inside the filling `contribute`, so the first condition is a
    ///      belt-and-braces path; the second is the floor path after the deadline.
    function finalize(uint256 id) external nonReentrant {
        Raise storage r = raises[id];
        if (r.status != STATUS_OPEN) revert NotOpen();
        bool filled = r.raised == r.target;
        bool closedAtOrAboveFloor = block.timestamp >= r.deadline && r.raised >= r.floor;
        if (!filled && !closedAtOrAboveFloor) revert NotLaunchable();
        _finalize(id);
    }

    /// @dev The launch, in the spec's order. 1. the fee; 2. the token by CREATE2; 3. the price in the pool's
    ///      currency order and `initialize`; 4. the full-range position through `unlock`; 5. burn what the sale
    ///      and the pool did not use, send the fee and the unused quote to the fee wallet in one transfer;
    ///      6. status, timestamps, event. The position is owned by this contract and no function here can
    ///      decrease it: that is the lock.
    function _finalize(uint256 id) private {
        Raise storage r = raises[id];
        Launch memory l;
        // 1.
        l.raised = r.raised;
        l.fee = l.raised * feeBps / BPS;
        l.net = l.raised - l.fee;

        // 2.
        l.token = _deployToken(id, r.name, r.symbol);
        r.token = l.token;

        // 3.
        l.tokenIs0 = l.token < r.quote;
        l.sqrtPriceX96 = l.tokenIs0
            ? LaunchMath.sqrtPriceX96For(r.saleTokens, r.target)
            : LaunchMath.sqrtPriceX96For(r.target, r.saleTokens);
        r.sqrtPriceX96 = l.sqrtPriceX96;
        PoolKey memory key = _poolKey(l.token, r.quote);
        POOL_MANAGER.initialize(key, l.sqrtPriceX96);

        // 4.
        l.tokensForPool = FullMath.mulDiv(l.net, r.saleTokens, r.target);
        bytes memory result = _unlock(
            abi.encode(
                CallbackData({
                    action: ACTION_MINT,
                    id: id,
                    amount0: l.tokenIs0 ? l.tokensForPool : l.net,
                    amount1: l.tokenIs0 ? l.net : l.tokensForPool
                })
            )
        );
        (l.liquidity, l.used0, l.used1) = abi.decode(result, (uint128, uint256, uint256));
        (l.tokensToPool, l.quoteToPool) = l.tokenIs0 ? (l.used0, l.used1) : (l.used1, l.used0);

        // 5.
        l.tokensBurned =
            (r.saleTokens - FullMath.mulDiv(l.raised, r.saleTokens, r.target)) + (POOL_TOKENS - l.tokensToPool);
        if (l.tokensBurned != 0) SVLaunchToken(l.token).burn(l.tokensBurned);
        uint256 toFeeWallet = l.fee + (l.net - l.quoteToPool);
        if (toFeeWallet != 0) IERC20(r.quote).safeTransfer(feeWallet, toFeeWallet);

        // 6.
        r.status = STATUS_LAUNCHED;
        // The cast cannot truncate before the year 292 billion.
        // forge-lint: disable-next-line(unsafe-typecast)
        r.launchedAt = uint64(block.timestamp);
        r.liquidity = l.liquidity;
        _emitFinalized(id, key, l);
    }

    /// @dev The token by CREATE2 with the spec's salt: a retry in a later block or by another caller lands on a
    ///      new address, so a pool key that was front-run cannot block the launch for good.
    function _deployToken(uint256 id, string memory name, string memory symbol) private returns (address) {
        // Plain `keccak256(abi.encode(...))` so the salt reads as the spec writes it; the assembly form the
        // lint suggests would save a few gas once per launch at the cost of that readability.
        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 salt = keccak256(abi.encode(id, block.number, msg.sender));
        return address(new SVLaunchToken{salt: salt}(name, symbol, SUPPLY, address(this)));
    }

    /// @dev Lives apart from `_finalize` only to keep that function's live variables within the stack.
    function _emitFinalized(uint256 id, PoolKey memory key, Launch memory l) private {
        emit Finalized(
            id,
            l.token,
            PoolId.unwrap(key.toId()),
            l.sqrtPriceX96,
            l.raised,
            l.fee,
            l.quoteToPool,
            l.tokensToPool,
            l.tokensBurned,
            l.liquidity
        );
    }
```

(g) Under the `PoolManager callback` banner (Task 6 turns the last line of `unlockCallback` into a two-way dispatch):

```solidity
    /// @inheritdoc IUnlockCallback
    /// @dev Only the PoolManager may call this, and only while `_unlock` has a call in flight; the transient
    ///      flag is what stops a PoolManager unlock started by someone else from reaching the position code.
    ///      Not `nonReentrant`: it runs inside a guarded call.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        if (!UNLOCK_SLOT.asBoolean().tload()) revert UnexpectedCallback();
        CallbackData memory cb = abi.decode(data, (CallbackData));
        return _mintPosition(cb);
    }

    /// @dev Sets the in-flight flag around the PoolManager's `unlock`, which calls back into `unlockCallback`.
    function _unlock(bytes memory data) private returns (bytes memory result) {
        UNLOCK_SLOT.asBoolean().tstore(true);
        result = POOL_MANAGER.unlock(data);
        UNLOCK_SLOT.asBoolean().tstore(false);
    }

    /// @dev Spec step 4: `L = getLiquidityForAmounts(...)`, one `modifyLiquidity` with `+L`, then for each
    ///      currency `sync`, transfer exactly what the pool says is owed, `settle`. Both deltas are negative: a
    ///      full-range position at a price inside the range needs both currencies and each side rounds up to at
    ///      least one unit. Returns the liquidity and the amounts the position took, in currency order.
    function _mintPosition(CallbackData memory cb) private returns (bytes memory) {
        Raise storage r = raises[cb.id];
        PoolKey memory key = _poolKey(r.token, r.quote);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            r.sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(TICK_LOWER),
            TickMath.getSqrtPriceAtTick(TICK_UPPER),
            cb.amount0,
            cb.amount1
        );
        (BalanceDelta delta,) = POOL_MANAGER.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
        uint256 used0 = _settle(key.currency0, delta.amount0());
        uint256 used1 = _settle(key.currency1, delta.amount1());
        return abi.encode(liquidity, used0, used1);
    }

    /// @dev Pays a negative delta from this contract's own balance: `sync`, transfer, `settle`, one currency at
    ///      a time as the PoolManager requires. Returns what was paid. A zero-owed side cannot occur:
    ///      `LaunchMath.MIN_LAUNCH_SQRT_PRICE` keeps every launch price strictly inside the position's range, so
    ///      both sides owe at least one unit; an early return on zero would be unreachable code under the
    ///      coverage bar, which is why there is none.
    function _settle(Currency currency, int128 delta) private returns (uint256 owed) {
        // The delta of a fresh full-range position is negative on both sides, so `-delta` is a positive int128,
        // which fits uint128 and uint256 unchanged.
        // forge-lint: disable-next-line(unsafe-typecast)
        owed = uint256(uint128(-delta));
        POOL_MANAGER.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransfer(address(POOL_MANAGER), owed);
        POOL_MANAGER.settle();
    }
```

(h) Under the `Views` banner, after `getRaise`:

```solidity
    /// @inheritdoc ISVLaunchpad
    function poolKey(uint256 id) external view returns (PoolKey memory) {
        Raise storage r = raises[id];
        if (r.status != STATUS_LAUNCHED) revert NotLaunched();
        return _poolKey(r.token, r.quote);
    }
```

(i) Under the `Internal helpers` banner, before `_mayLaunch`:

```solidity
    /// @dev The pool key is derived, never stored: the lower address is `currency0`, the fee and spacing are
    ///      constants, and there is no hook.
    function _poolKey(address token, address quote) private pure returns (PoolKey memory) {
        (address c0, address c1) = token < quote ? (token, quote) : (quote, token);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: POOL_LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }
```

Why the pieces look the way they do: `Launch` is a memory struct because `_finalize` with these values as locals does not compile without via-IR; `_emitFinalized` exists for the same reason; the position takes at most the amounts offered (the helper rounds liquidity down, the pool rounds the amounts for that liquidity up, and the double ceiling never exceeds an integer bound), and on a full-range position the non-binding side keeps a remainder of about `sqrtLower / sqrtPrice` (or `sqrtPrice / sqrtUpper`) relative, a few thousand wei on an 18-decimal quote, which is why the tests bound the remainder by a billionth rather than by one unit; the remainder on the quote side travels with the fee in one transfer.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `forge test --match-path 'test/unit/SVLaunchpad*.t.sol' -vv`
Expected: `SVLaunchpadLaunchTest`: `11 passed`; the earlier suites still pass (the contribute suite's fill test now also launches). The `-vv` log shows `gas of the launching contribution` at about 2,150,000. Gates: `forge build --sizes` (`SVLaunchpad` about 19,000 bytes, under 24,576), `forge fmt --check`, `forge lint` (no findings), `forge test`, `forge coverage --report summary` (`src/SVLaunchpad.sol` 100 % on the four columns; the `ACTION_COLLECT` constant is unused until Task 6 and does not count).

- [ ] **Step 7: Commit**

```bash
git add src/SVLaunchpad.sol src/interfaces/ISVLaunchpad.sol test/unit/SVLaunchpad.t.sol test/unit/SVLaunchpad.launch.t.sol
git commit -m "SVLaunchpad: the launch, CREATE2 token, pool at the presale price, locked full-range position

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016tofArVnM9erCZUwPku467"
```

### Task 5: `claim`, `claimCreator` with 90-day vesting, `refund` with the floor rule and the stall valve, `setPayout`

**Files:**
- Modify: `src/SVLaunchpad.sol` (the after-launch and refund sections)
- Modify: `src/interfaces/ISVLaunchpad.sol` (declare `claim`, `claimCreator`, `refund`, `setPayout`)
- Create: `test/mocks/RevertingPoolManager.sol`
- Test: `test/unit/SVLaunchpad.claims.t.sol`

**Interfaces:**
- Consumes: fixture helpers `_create`, `_createWithFloor`, `_contribute`, `_fill`, `_launch`, `_params`, `_contributorKey`, `_contributor`, `_now`; `FullMath.mulDiv`; `SafeERC20.safeTransfer`.
- Produces: `function claim(uint256 id) external`, `function claimCreator(uint256 id) external`, `function refund(uint256 id) external`, `function setPayout(uint256 id, address payout) external`; `contract RevertingPoolManager { error PoolManagerDown(); fallback() external; }` (every call reverts `PoolManagerDown`).

- [ ] **Step 1: Write the mock and the failing tests**

`test/mocks/RevertingPoolManager.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice A PoolManager stand-in whose every call reverts, so a launch can never complete and the stall valve
///         is the only way out. Unit tests only.
contract RevertingPoolManager {
    error PoolManagerDown();

    fallback() external {
        revert PoolManagerDown();
    }
}
```

`test/unit/SVLaunchpad.claims.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {SVLaunchpad} from "../../src/SVLaunchpad.sol";
import {ISVLaunchpad} from "../../src/interfaces/ISVLaunchpad.sol";
import {SVLaunchToken} from "../../src/SVLaunchToken.sol";
import {RevertingPoolManager} from "../mocks/RevertingPoolManager.sol";
import {Permit2Signer} from "../utils/Permit2Signer.sol";
import {SVLaunchpadTestBase} from "./SVLaunchpad.t.sol";

/// @notice After the launch: `claim`, the creator's linear vesting, `setPayout`; and the two ways out of a raise
///         that did not launch: the floor rule at the deadline and the stall valve seven days later.
contract SVLaunchpadClaimsTest is SVLaunchpadTestBase {
    // -------------------------------------------------------------------------------------------------------
    // claim (spec section 4.2)
    // -------------------------------------------------------------------------------------------------------

    function test_claim_pays_contributed_times_saleTokens_over_target_once_and_emits() public {
        (uint256 id, Launched memory l) = _launch(usdg, USDG_TARGET, true);
        uint256 share = USDG_TARGET / CONTRIBUTORS;
        uint256 expected = share * SALE_TOKENS / USDG_TARGET;
        vm.expectEmit(true, true, true, true, address(launchpad));
        emit ISVLaunchpad.Claimed(id, _contributor(0), expected);
        vm.prank(_contributor(0));
        launchpad.claim(id);
        assertEq(SVLaunchToken(l.token).balanceOf(_contributor(0)), expected, "claimed tokens");
        assertTrue(launchpad.claimed(id, _contributor(0)), "marked claimed");
        assertEq(launchpad.contributed(id, _contributor(0)), share, "the contribution record stays");
        vm.prank(_contributor(0));
        vm.expectRevert(ISVLaunchpad.AlreadyClaimed.selector);
        launchpad.claim(id);
    }

    function test_all_claims_add_up_to_the_sold_tokens_on_a_filled_raise() public {
        (uint256 id, Launched memory l) = _launch(usdg, USDG_TARGET, true);
        uint256 sum;
        for (uint256 i = 0; i < CONTRIBUTORS; i++) {
            vm.prank(_contributor(i));
            launchpad.claim(id);
            sum += SVLaunchToken(l.token).balanceOf(_contributor(i));
        }
        assertEq(sum, SALE_TOKENS, "a filled raise sells exactly the sale tokens");
        assertEq(
            SVLaunchToken(l.token).balanceOf(address(launchpad)), CREATOR_TOKENS, "only the creator tokens remain"
        );
    }

    function test_claim_reverts_NothingToClaim_for_a_wallet_that_did_not_contribute() public {
        (uint256 id,) = _launch(usdg, USDG_TARGET, true);
        vm.prank(stranger);
        vm.expectRevert(ISVLaunchpad.NothingToClaim.selector);
        launchpad.claim(id);
    }

    function test_claim_reverts_NotLaunched_while_open_and_after_a_failure() public {
        uint256 id = _create(address(usdg), USDG_TARGET);
        _contribute(_contributorKey(0), id, 100e6);
        vm.prank(_contributor(0));
        vm.expectRevert(ISVLaunchpad.NotLaunched.selector);
        launchpad.claim(id);
        vm.warp(block.timestamp + 1 days);
        vm.prank(_contributor(0));
        launchpad.refund(id);
        vm.prank(_contributor(0));
        vm.expectRevert(ISVLaunchpad.NotLaunched.selector);
        launchpad.claim(id);
    }

    // -------------------------------------------------------------------------------------------------------
    // claimCreator (spec section 4.2): linear over 90 days from the launch
    // -------------------------------------------------------------------------------------------------------

    function test_claimCreator_vests_nothing_at_day_0_half_at_day_45_and_all_at_day_90() public {
        (uint256 id, Launched memory l) = _launch(usdg, USDG_TARGET, true);
        SVLaunchToken token = SVLaunchToken(l.token);
        vm.prank(creator);
        vm.expectRevert(ISVLaunchpad.NothingToClaim.selector);
        launchpad.claimCreator(id);
        vm.warp(block.timestamp + 45 days);
        vm.expectEmit(true, true, true, true, address(launchpad));
        emit ISVLaunchpad.CreatorClaimed(id, creator, CREATOR_TOKENS / 2);
        vm.prank(creator);
        launchpad.claimCreator(id);
        assertEq(token.balanceOf(creator), CREATOR_TOKENS / 2, "half vested at day 45");
        assertEq(launchpad.getRaise(id).creatorClaimed, CREATOR_TOKENS / 2, "creatorClaimed");
        vm.warp(block.timestamp + 45 days);
        vm.prank(creator);
        launchpad.claimCreator(id);
        assertEq(token.balanceOf(creator), CREATOR_TOKENS, "all vested at day 90");
        vm.warp(block.timestamp + 365 days);
        vm.prank(creator);
        vm.expectRevert(ISVLaunchpad.NothingToClaim.selector);
        launchpad.claimCreator(id);
        assertEq(token.balanceOf(address(launchpad)), SALE_TOKENS, "only the sale tokens remain for claims");
    }

    function test_claimCreator_pays_what_vested_since_the_last_call() public {
        (uint256 id, Launched memory l) = _launch(usdg, USDG_TARGET, true);
        vm.warp(block.timestamp + 9 days);
        vm.prank(creator);
        launchpad.claimCreator(id);
        vm.warp(block.timestamp + 18 days);
        vm.prank(creator);
        launchpad.claimCreator(id);
        assertEq(
            SVLaunchToken(l.token).balanceOf(creator), CREATOR_TOKENS * 27 / 90, "27 of 90 days vested in two calls"
        );
    }

    function test_claimCreator_reverts_NotCreator_and_NotLaunched() public {
        (uint256 id,) = _launch(usdg, USDG_TARGET, true);
        vm.warp(block.timestamp + 1 days);
        vm.prank(stranger);
        vm.expectRevert(ISVLaunchpad.NotCreator.selector);
        launchpad.claimCreator(id);
        uint256 open = _create(address(usdg), USDG_TARGET);
        vm.prank(creator);
        vm.expectRevert(ISVLaunchpad.NotLaunched.selector);
        launchpad.claimCreator(open);
    }

    // -------------------------------------------------------------------------------------------------------
    // setPayout
    // -------------------------------------------------------------------------------------------------------

    function test_setPayout_moves_the_creator_tokens_to_the_new_address() public {
        (uint256 id, Launched memory l) = _launch(usdg, USDG_TARGET, true);
        address payout = makeAddr("payout");
        vm.expectEmit(true, true, true, true, address(launchpad));
        emit ISVLaunchpad.PayoutChanged(id, payout);
        vm.prank(creator);
        launchpad.setPayout(id, payout);
        assertEq(launchpad.getRaise(id).payout, payout, "payout stored");
        vm.warp(block.timestamp + 90 days);
        vm.prank(creator);
        launchpad.claimCreator(id);
        assertEq(SVLaunchToken(l.token).balanceOf(payout), CREATOR_TOKENS, "the payout address received the tokens");
        assertEq(SVLaunchToken(l.token).balanceOf(creator), 0, "the creator's own address received nothing");
    }

    function test_setPayout_reverts_NotCreator_and_ZeroAddress() public {
        uint256 id = _create(address(usdg), USDG_TARGET);
        vm.prank(stranger);
        vm.expectRevert(ISVLaunchpad.NotCreator.selector);
        launchpad.setPayout(id, stranger);
        vm.prank(creator);
        vm.expectRevert(ISVLaunchpad.ZeroAddress.selector);
        launchpad.setPayout(id, address(0));
        vm.prank(creator);
        vm.expectRevert(ISVLaunchpad.NotCreator.selector);
        launchpad.setPayout(999, creator);
    }

    // -------------------------------------------------------------------------------------------------------
    // refund (spec section 4.2): the floor rule and the stall valve
    // -------------------------------------------------------------------------------------------------------

    function test_refund_after_the_deadline_under_the_floor_closes_the_raise_and_makes_everyone_whole() public {
        uint256 id = _create(address(usdg), USDG_TARGET); // floor = target: all or nothing
        _contribute(_contributorKey(0), id, 100e6);
        _contribute(_contributorKey(1), id, 250e6);
        vm.warp(block.timestamp + 1 days);
        vm.expectEmit(true, true, true, true, address(launchpad));
        emit ISVLaunchpad.Closed(id, 350e6);
        vm.expectEmit(true, true, true, true, address(launchpad));
        emit ISVLaunchpad.Refunded(id, _contributor(0), 100e6);
        vm.prank(_contributor(0));
        launchpad.refund(id);
        assertEq(launchpad.getRaise(id).status, 3, "Closed by the first refund");
        assertEq(usdg.balanceOf(_contributor(0)), USDG_MINT, "made whole");
        assertEq(launchpad.contributed(id, _contributor(0)), 0, "contribution zeroed");
        vm.prank(_contributor(1));
        launchpad.refund(id); // status Closed: no second Closed event, just the refund
        assertEq(usdg.balanceOf(_contributor(1)), USDG_MINT, "the second wallet made whole");
        assertEq(usdg.balanceOf(address(launchpad)), 0, "nothing left in the launchpad");
        assertEq(launchpad.getRaise(id).raised, 350e6, "raised keeps the historical total");
        vm.prank(_contributor(0));
        vm.expectRevert(ISVLaunchpad.NothingToClaim.selector);
        launchpad.refund(id); // twice
        vm.prank(stranger);
        vm.expectRevert(ISVLaunchpad.NothingToClaim.selector);
        launchpad.refund(id); // never contributed
        vm.expectRevert(ISVLaunchpad.NotOpen.selector);
        launchpad.finalize(id);
    }

    function test_refund_reverts_NotRefundable_before_the_deadline_at_the_floor_after_launch_or_unknown() public {
        uint256 id = _createWithFloor(address(usdg), USDG_TARGET, USDG_TARGET / 2);
        for (uint256 i = 0; i < 5; i++) {
            _contribute(_contributorKey(i), id, USDG_TARGET / 10); // exactly the floor
        }
        vm.prank(_contributor(0));
        vm.expectRevert(ISVLaunchpad.NotRefundable.selector);
        launchpad.refund(id); // before the deadline
        vm.warp(block.timestamp + 1 days);
        vm.prank(_contributor(0));
        vm.expectRevert(ISVLaunchpad.NotRefundable.selector);
        launchpad.refund(id); // at the deadline, at the floor: launchable, not refundable
        (uint256 launched,) = _launch(stk, STK_TARGET, true);
        vm.prank(_contributor(0));
        vm.expectRevert(ISVLaunchpad.NotRefundable.selector);
        launchpad.refund(launched);
        vm.prank(_contributor(0));
        vm.expectRevert(ISVLaunchpad.NotRefundable.selector);
        launchpad.refund(999);
    }

    function test_the_stall_valve_opens_refunds_seven_days_after_the_deadline_whatever_was_raised() public {
        // A launchpad whose PoolManager is down: the tenth contribution cannot launch and reverts; the raise sits
        // at 90 % above a 50 % floor, launchable but never launched; seven days after the deadline refunds open.
        RevertingPoolManager down = new RevertingPoolManager();
        SVLaunchpad stalled = new SVLaunchpad(
            IPoolManager(address(down)), ISignatureTransfer(permit2), owner, feeWallet, FEE_BPS, CREATOR_FEE_SHARE_BPS
        );
        vm.prank(owner);
        stalled.setQuote(address(usdg), USDG_MIN, USDG_MAX);
        ISVLaunchpad.CreateParams memory p = _params(address(usdg), USDG_TARGET);
        p.floor = USDG_TARGET / 2;
        vm.prank(creator);
        uint256 id = stalled.create(p);
        for (uint256 i = 0; i < 9; i++) {
            _contributeTo(stalled, _contributorKey(i), id, USDG_TARGET / 10);
        }
        ISignatureTransfer.PermitTransferFrom memory tenth = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(usdg), amount: USDG_TARGET / 10}),
            nonce: nextNonce++,
            deadline: block.timestamp + 1 hours
        });
        bytes memory tenthSignature = Permit2Signer.sign(_contributorKey(9), permit2, tenth, address(stalled));
        vm.prank(_contributor(9));
        vm.expectRevert(RevertingPoolManager.PoolManagerDown.selector);
        stalled.contribute(id, USDG_TARGET / 10, tenth, tenthSignature);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(RevertingPoolManager.PoolManagerDown.selector);
        stalled.finalize(id); // launchable, but the PoolManager is down
        vm.prank(_contributor(0));
        vm.expectRevert(ISVLaunchpad.NotRefundable.selector);
        stalled.refund(id); // above the floor: not refundable yet
        vm.warp(block.timestamp + 7 days);
        vm.expectEmit(true, true, true, true, address(stalled));
        emit ISVLaunchpad.Closed(id, USDG_TARGET * 9 / 10);
        vm.prank(_contributor(0));
        stalled.refund(id);
        assertEq(usdg.balanceOf(_contributor(0)), USDG_MINT, "refunded after the stall grace");
        for (uint256 i = 1; i < 9; i++) {
            vm.prank(_contributor(i));
            stalled.refund(id);
        }
        assertEq(usdg.balanceOf(address(stalled)), 0, "every contribution went back");
    }

    function test_setCreationOpen_false_does_not_block_contribute_finalize_claim_or_refund() public {
        uint256 failing = _create(address(usdg), USDG_TARGET);
        _contribute(_contributorKey(0), failing, 100e6);
        uint256 filling = _createWithFloor(address(usdg), USDG_TARGET, USDG_TARGET / 2);
        for (uint256 i = 0; i < 6; i++) {
            _contribute(_contributorKey(i), filling, USDG_TARGET / 10);
        }
        vm.prank(owner);
        launchpad.setCreationOpen(false);
        _contribute(_contributorKey(6), filling, USDG_TARGET / 10); // contribute still works
        vm.warp(block.timestamp + 1 days);
        _rollUntilTokenSide(filling, stranger, true);
        vm.prank(stranger);
        launchpad.finalize(filling); // finalize still works
        vm.prank(_contributor(0));
        launchpad.claim(filling); // claim still works
        vm.prank(_contributor(0));
        launchpad.refund(failing); // refund still works
        assertEq(launchpad.getRaise(filling).status, 2, "launched while creation was closed");
        assertEq(launchpad.getRaise(failing).status, 3, "closed while creation was closed");
    }

    /// @dev `_contribute` against another launchpad instance (the fixture's helper is bound to `launchpad`). Sign
    ///      before any expectation: the signing reads `DOMAIN_SEPARATOR()`, an external call that would consume a
    ///      pending `expectRevert` or `prank`, which is why the stall-valve test signs its tenth contribution inline.
    function _contributeTo(SVLaunchpad target, uint256 privateKey, uint256 id, uint256 amount) internal {
        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(usdg), amount: amount}),
            nonce: nextNonce++,
            deadline: block.timestamp + 1 hours
        });
        bytes memory signature = Permit2Signer.sign(privateKey, permit2, permit, address(target));
        vm.prank(vm.addr(privateKey));
        target.contribute(id, amount, permit, signature);
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `forge test --match-path test/unit/SVLaunchpad.claims.t.sol`
Expected: compilation fails, `Member "claim" not found` (and `claimCreator`, `refund`, `setPayout`).

- [ ] **Step 3: Declare the functions in the interface**

In `src/interfaces/ISVLaunchpad.sol`, after the `finalize` declaration:

```solidity
    /// @notice Claim the caller's tokens of a launched raise: `contributed * saleTokens / target`.
    function claim(uint256 id) external;

    /// @notice Creator only. Send the vested part of the creator's tokens to `payout`.
    function claimCreator(uint256 id) external;

    /// @notice Take the caller's contribution back from a raise that did not launch; the first call after the
    ///         deadline closes the raise.
    function refund(uint256 id) external;

    /// @notice Creator only. Change where creator tokens and the creator's fee share go; non-zero.
    function setPayout(uint256 id, address payout) external;
```

- [ ] **Step 4: Implement them**

In `src/SVLaunchpad.sol`, under the `After launch` banner (before the `refund` banner; drop the `: Tasks 5 and 6` and `: Task 5` suffixes of the two banners while filling them):

```solidity
    /// @inheritdoc ISVLaunchpad
    /// @dev `contributed * saleTokens / target` with `mulDiv`; the sum over all claims is `soldTokens` minus
    ///      rounding dust that stays here (spec section 4.3).
    function claim(uint256 id) external nonReentrant {
        Raise storage r = raises[id];
        if (r.status != STATUS_LAUNCHED) revert NotLaunched();
        if (claimed[id][msg.sender]) revert AlreadyClaimed();
        uint256 amount = contributed[id][msg.sender];
        if (amount == 0) revert NothingToClaim();
        claimed[id][msg.sender] = true;
        uint256 tokens = FullMath.mulDiv(amount, r.saleTokens, r.target);
        IERC20(r.token).safeTransfer(msg.sender, tokens);
        emit Claimed(id, msg.sender, tokens);
    }

    /// @inheritdoc ISVLaunchpad
    /// @dev Linear over `CREATOR_VESTING` from `launchedAt`; each call pays what vested since the last one.
    function claimCreator(uint256 id) external nonReentrant {
        Raise storage r = raises[id];
        if (r.status != STATUS_LAUNCHED) revert NotLaunched();
        if (msg.sender != r.creator) revert NotCreator();
        uint256 elapsed = block.timestamp - r.launchedAt;
        if (elapsed > CREATOR_VESTING) elapsed = CREATOR_VESTING;
        uint256 vested = CREATOR_TOKENS * elapsed / CREATOR_VESTING;
        uint256 amount = vested - r.creatorClaimed;
        if (amount == 0) revert NothingToClaim();
        r.creatorClaimed = vested;
        IERC20(r.token).safeTransfer(r.payout, amount);
        emit CreatorClaimed(id, r.payout, amount);
    }

    /// @inheritdoc ISVLaunchpad
    function setPayout(uint256 id, address payout) external nonReentrant {
        Raise storage r = raises[id];
        if (msg.sender != r.creator) revert NotCreator();
        if (payout == address(0)) revert ZeroAddress();
        r.payout = payout;
        emit PayoutChanged(id, payout);
    }
```

and under the `refund` banner:

```solidity
    /// @inheritdoc ISVLaunchpad
    /// @dev Refundable when Closed, or when Open and either past the deadline under the floor or past the
    ///      deadline plus `STALL_GRACE` whatever was raised (the stall valve). The first call from Open closes
    ///      the raise. `raised` keeps the historical total (`Closed` carries it). Nothing to burn: no token was
    ///      deployed. A caller with nothing to take back reverts, so a stranger cannot close a raise either.
    function refund(uint256 id) external nonReentrant {
        Raise storage r = raises[id];
        if (r.status == STATUS_OPEN) {
            bool underFloor = block.timestamp >= r.deadline && r.raised < r.floor;
            bool stalled = block.timestamp >= r.deadline + STALL_GRACE;
            if (!underFloor && !stalled) revert NotRefundable();
            r.status = STATUS_CLOSED;
            emit Closed(id, r.raised);
        } else if (r.status != STATUS_CLOSED) {
            revert NotRefundable();
        }
        uint256 amount = contributed[id][msg.sender];
        if (amount == 0) revert NothingToClaim();
        contributed[id][msg.sender] = 0;
        IERC20(r.quote).safeTransfer(msg.sender, amount);
        emit Refunded(id, msg.sender, amount);
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `forge test --match-path 'test/unit/SVLaunchpad*.t.sol' -vv`
Expected: `SVLaunchpadClaimsTest`: `13 passed`; all earlier suites pass. Gates: `forge fmt --check`, `forge lint`, `forge test`, `forge coverage --report summary` (`src/SVLaunchpad.sol` 100 % on the four columns).

- [ ] **Step 6: Commit**

```bash
git add src/SVLaunchpad.sol src/interfaces/ISVLaunchpad.sol test/mocks/RevertingPoolManager.sol test/unit/SVLaunchpad.claims.t.sol
git commit -m "SVLaunchpad: claims, creator vesting over 90 days, refunds under the floor and after the stall grace, setPayout

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016tofArVnM9erCZUwPku467"
```

### Task 6: `collectFees`: the zero-delta poke, `take`, the split, `FeesCollected`

**Files:**
- Modify: `src/SVLaunchpad.sol` (`collectFees`, `_split`, `_collectPosition`, `_take`; the dispatch in `unlockCallback`)
- Modify: `src/interfaces/ISVLaunchpad.sol` (declare `collectFees`)
- Modify: `test/unit/SVLaunchpad.t.sol` (fixture: `_swap`)
- Test: `test/unit/SVLaunchpad.fees.t.sol`

**Interfaces:**
- Consumes: v4-core `PoolSwapTest.swap(PoolKey, IPoolManager.SwapParams{zeroForOne, amountSpecified, sqrtPriceLimitX96}, PoolSwapTest.TestSettings{takeClaims, settleUsingBurn}, bytes)` (the `swapRouter` of `Deployers`; it pulls the input with `transferFrom`, so the payer approves it), `Deployers.MIN_PRICE_LIMIT` / `MAX_PRICE_LIMIT`; `IPoolManager.modifyLiquidity` with `liquidityDelta = 0` (the poke, returns the accrued fees as the caller delta), `IPoolManager.take(Currency, address, uint256)`.
- Produces: `function collectFees(uint256 id) external`; private `_collectPosition(CallbackData memory) returns (bytes memory)`, `_take(Currency, int128) returns (uint256)`, `_split(Currency, address payout, uint256 amount, uint16 shareBps) returns (uint256 creatorPart, uint256 platformPart)`; fixture `_swap(uint256 id, bool zeroForOne, uint256 amountIn)` (an exact-input swap paid by the test contract).

- [ ] **Step 1: Add the swap helper to the fixture**

In `test/unit/SVLaunchpad.t.sol` add the imports

```solidity
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
```

and append after `_launch`:

```solidity
    /// @dev One exact-input swap through the core's test router, paid by this test contract, with the price
    ///      limit at the far end so the whole input is consumed.
    function _swap(uint256 id, bool zeroForOne, uint256 amountIn) internal {
        PoolKey memory key = launchpad.poolKey(id);
        MockERC20 tokenIn = MockERC20(Currency.unwrap(zeroForOne ? key.currency0 : key.currency1));
        tokenIn.approve(address(swapRouter), amountIn);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
```

- [ ] **Step 2: Write the failing tests**

`test/unit/SVLaunchpad.fees.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {ISVLaunchpad} from "../../src/interfaces/ISVLaunchpad.sol";
import {SVLaunchToken} from "../../src/SVLaunchToken.sol";
import {SVLaunchpadTestBase} from "./SVLaunchpad.t.sol";

/// @notice `collectFees` (spec section 4.2): a zero-delta `modifyLiquidity` credits the fees accrued since the
///         last poke, `take` moves them into the launchpad, the split goes to the payout address and the fee
///         wallet, and the position's liquidity never moves. Swaps go through v4-core's `PoolSwapTest`.
contract SVLaunchpadFeesTest is SVLaunchpadTestBase {
    uint256 internal id;
    Launched internal l;
    SVLaunchToken internal token;
    bool internal quoteIs0;

    function setUp() public override {
        super.setUp();
        (id, l) = _launch(usdg, USDG_TARGET, true);
        token = SVLaunchToken(l.token);
        quoteIs0 = address(usdg) < l.token;
        usdg.mint(address(this), 10_000e6);
    }

    /// @dev Buys tokens with `quoteIn` USDG and sells every token bought straight back; returns the tokens sold.
    function _roundTrip(uint256 quoteIn) internal returns (uint256 tokensSold) {
        _swap(id, quoteIs0, quoteIn);
        tokensSold = token.balanceOf(address(this));
        assertGt(tokensSold, 0, "the buy paid out tokens");
        _swap(id, !quoteIs0, tokensSold);
    }

    function test_collectFees_pays_70_percent_to_the_payout_and_30_to_the_fee_wallet_on_both_currencies() public {
        uint256 tokensSold = _roundTrip(100e6);
        uint256 feeWalletBefore = usdg.balanceOf(feeWallet);
        uint128 liquidityBefore = _positionLiquidity(id);
        vm.recordLogs();
        vm.prank(stranger); // anyone may collect
        launchpad.collectFees(id);
        assertEq(_positionLiquidity(id), liquidityBefore, "the poke did not change the liquidity");
        uint256 creatorQuote = usdg.balanceOf(creator) - USDG_MINT;
        uint256 platformQuote = usdg.balanceOf(feeWallet) - feeWalletBefore;
        uint256 creatorTokens = token.balanceOf(creator);
        uint256 platformTokens = token.balanceOf(feeWallet);
        // 1 % of each exact input accrued to the only position; the pool floors the growth twice, so within 2.
        assertApproxEqAbs(creatorQuote + platformQuote, 100e6 / 100, 2, "1 % of the quote paid in");
        assertApproxEqAbs(creatorTokens + platformTokens, tokensSold / 100, 2, "1 % of the tokens paid in");
        assertEq(creatorQuote, (creatorQuote + platformQuote) * 7000 / 10_000, "creator: 70 % of the quote fees");
        assertEq(creatorTokens, (creatorTokens + platformTokens) * 7000 / 10_000, "creator: 70 % of the token fees");
        assertEq(usdg.balanceOf(address(launchpad)), 0, "the launchpad keeps no quote");
        assertEq(
            token.balanceOf(address(launchpad)), SALE_TOKENS + CREATOR_TOKENS, "the launchpad keeps no fee tokens"
        );
        // The event, in pool currency order.
        (uint256 c0, uint256 c1, uint256 p0, uint256 p1) = _feesCollected(vm.getRecordedLogs());
        assertEq(c0, quoteIs0 ? creatorQuote : creatorTokens, "creator0");
        assertEq(c1, quoteIs0 ? creatorTokens : creatorQuote, "creator1");
        assertEq(p0, quoteIs0 ? platformQuote : platformTokens, "platform0");
        assertEq(p1, quoteIs0 ? platformTokens : platformQuote, "platform1");
    }

    function test_collectFees_with_nothing_accrued_emits_zeros_and_moves_nothing() public {
        vm.recordLogs();
        launchpad.collectFees(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 c0, uint256 c1, uint256 p0, uint256 p1) = _feesCollected(logs);
        assertEq(c0 + c1 + p0 + p1, 0, "zeros");
        assertEq(_transfersFrom(logs, address(launchpad)), 0, "no transfer was made for a zero part");
    }

    function test_collectFees_after_a_one_way_swap_pays_fees_on_that_currency_only() public {
        _swap(id, quoteIs0, 100e6); // only quote came in
        vm.recordLogs();
        launchpad.collectFees(id);
        (uint256 c0, uint256 c1, uint256 p0, uint256 p1) = _feesCollected(vm.getRecordedLogs());
        uint256 quoteFees = quoteIs0 ? c0 + p0 : c1 + p1;
        uint256 tokenFees = quoteIs0 ? c1 + p1 : c0 + p0;
        assertApproxEqAbs(quoteFees, 100e6 / 100, 2, "fees on the quote side");
        assertEq(tokenFees, 0, "none on the token side");
    }

    function test_a_second_collection_pays_only_what_accrued_since_the_first() public {
        _roundTrip(100e6);
        launchpad.collectFees(id);
        uint256 creatorAfterFirst = usdg.balanceOf(creator);
        vm.recordLogs();
        launchpad.collectFees(id); // nothing new
        (uint256 c0, uint256 c1, uint256 p0, uint256 p1) = _feesCollected(vm.getRecordedLogs());
        assertEq(c0 + c1 + p0 + p1, 0, "the checkpoint moved: nothing to collect twice");
        _roundTrip(50e6);
        launchpad.collectFees(id);
        assertApproxEqAbs(
            usdg.balanceOf(creator) - creatorAfterFirst, 50e6 / 100 * 7000 / 10_000, 2, "only the new fees"
        );
    }

    function test_collectFees_follows_the_payout_address() public {
        address payout = makeAddr("payout");
        vm.prank(creator);
        launchpad.setPayout(id, payout);
        _roundTrip(100e6);
        launchpad.collectFees(id);
        assertGt(usdg.balanceOf(payout), 0, "the new payout address received the creator share");
        assertEq(usdg.balanceOf(creator), USDG_MINT, "the creator's own address received nothing");
    }

    function test_the_share_is_fixed_at_creation_and_a_zero_share_sends_everything_to_the_fee_wallet() public {
        vm.prank(owner);
        launchpad.setCreatorFeeShare(0);
        (uint256 later, Launched memory m) = _launch(stk, STK_TARGET, false);
        stk.mint(address(this), 1_000e18);
        bool stkIs0 = address(stk) < m.token;
        _swap(later, stkIs0, 10e18);
        uint256 feeWalletBefore = stk.balanceOf(feeWallet);
        vm.recordLogs();
        launchpad.collectFees(later);
        assertEq(stk.balanceOf(creator), STK_MINT, "a zero share pays the creator nothing");
        assertApproxEqAbs(stk.balanceOf(feeWallet) - feeWalletBefore, 10e18 / 100, 2, "the fee wallet gets all");
        assertEq(
            _transfersFrom(vm.getRecordedLogs(), address(launchpad)),
            1,
            "one transfer: no zero-value transfer to the creator"
        );
        // The earlier raise keeps its 70 % share.
        _roundTrip(100e6);
        launchpad.collectFees(id);
        assertGt(usdg.balanceOf(creator) - USDG_MINT, 0, "the first raise still pays its creator");
    }

    function test_collectFees_reverts_NotLaunched_before_launch() public {
        uint256 open = _create(address(usdg), USDG_TARGET);
        vm.expectRevert(ISVLaunchpad.NotLaunched.selector);
        launchpad.collectFees(open);
    }

    /// @dev The `FeesCollected` event among `logs`.
    function _feesCollected(Vm.Log[] memory logs)
        internal
        view
        returns (uint256 c0, uint256 c1, uint256 p0, uint256 p1)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(launchpad)) continue;
            if (logs[i].topics[0] != ISVLaunchpad.FeesCollected.selector) continue;
            return abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
        }
        revert("no FeesCollected event in the recorded logs");
    }

    /// @dev How many ERC20 `Transfer` events among `logs` were sent by `from`.
    function _transfersFrom(Vm.Log[] memory logs, address from) internal pure returns (uint256 count) {
        bytes32 transferTopic = keccak256("Transfer(address,address,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length != 3 || logs[i].topics[0] != transferTopic) continue;
            if (address(uint160(uint256(logs[i].topics[1]))) == from) count++;
        }
    }
}
```

`vm.getRecordedLogs()` drains the buffer, so each test reads it once and passes the array to both helpers.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `forge test --match-path test/unit/SVLaunchpad.fees.t.sol`
Expected: compilation fails, `Member "collectFees" not found`.

- [ ] **Step 4: Declare `collectFees` in the interface**

In `src/interfaces/ISVLaunchpad.sol`, after the `refund` declaration:

```solidity
    /// @notice Anyone. Collect the pool fees accrued to the launch position and split them between the
    ///         creator's payout address and the fee wallet.
    function collectFees(uint256 id) external;
```

- [ ] **Step 5: Implement it**

In `src/SVLaunchpad.sol`:

(a) In `unlockCallback`, replace `return _mintPosition(cb);` with:

```solidity
        return cb.action == ACTION_MINT ? _mintPosition(cb) : _collectPosition(cb);
```

(b) After `_settle`, under the callback banner:

```solidity
    /// @dev The fee poke: `modifyLiquidity` with a zero delta credits the fees accrued since the last poke to
    ///      this contract, and `take` moves them out. The liquidity of the position is untouched.
    function _collectPosition(CallbackData memory cb) private returns (bytes memory) {
        Raise storage r = raises[cb.id];
        PoolKey memory key = _poolKey(r.token, r.quote);
        (BalanceDelta delta,) = POOL_MANAGER.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: 0, salt: bytes32(0)
            }),
            ""
        );
        uint256 fees0 = _take(key.currency0, delta.amount0());
        uint256 fees1 = _take(key.currency1, delta.amount1());
        return abi.encode(fees0, fees1);
    }

    /// @dev Takes a positive delta into this contract; nothing to take means nothing accrued on that side.
    function _take(Currency currency, int128 delta) private returns (uint256 amount) {
        if (delta <= 0) return 0;
        // Checked positive just above, so the int128 fits uint128 and uint256 unchanged.
        // forge-lint: disable-next-line(unsafe-typecast)
        amount = uint256(uint128(delta));
        POOL_MANAGER.take(currency, address(this), amount);
    }
```

(c) Under the `After launch` banner, after `claimCreator` and before `setPayout` (no `: Task N` suffix may remain on any banner after this task):

```solidity
    /// @inheritdoc ISVLaunchpad
    /// @dev The only call that ever touches the position after launch, and it cannot change its liquidity.
    ///      The split uses the share fixed at the raise's creation. A zero part is not transferred.
    function collectFees(uint256 id) external nonReentrant {
        Raise storage r = raises[id];
        if (r.status != STATUS_LAUNCHED) revert NotLaunched();
        bytes memory result =
            _unlock(abi.encode(CallbackData({action: ACTION_COLLECT, id: id, amount0: 0, amount1: 0})));
        (uint256 fees0, uint256 fees1) = abi.decode(result, (uint256, uint256));
        PoolKey memory key = _poolKey(r.token, r.quote);
        (uint256 creator0, uint256 platform0) = _split(key.currency0, r.payout, fees0, r.creatorFeeShareBps);
        (uint256 creator1, uint256 platform1) = _split(key.currency1, r.payout, fees1, r.creatorFeeShareBps);
        emit FeesCollected(id, creator0, creator1, platform0, platform1);
    }

    /// @dev `shareBps` of `amount` to `payout`, the rest to the fee wallet; zero parts are not transferred.
    function _split(Currency currency, address payout, uint256 amount, uint16 shareBps)
        private
        returns (uint256 creatorPart, uint256 platformPart)
    {
        creatorPart = amount * shareBps / BPS;
        platformPart = amount - creatorPart;
        IERC20 token = IERC20(Currency.unwrap(currency));
        if (creatorPart != 0) token.safeTransfer(payout, creatorPart);
        if (platformPart != 0) token.safeTransfer(feeWallet, platformPart);
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `forge test --match-path 'test/unit/SVLaunchpad*.t.sol' -vv`
Expected: `SVLaunchpadFeesTest`: `7 passed`; everything else passes. Gates: `forge build --sizes` (`SVLaunchpad` 20,522 bytes, the final figure), `forge fmt --check`, `forge lint`, `forge test`, `forge coverage --report summary` (`src/SVLaunchpad.sol`, `src/SVLaunchToken.sol`, `src/libraries/LaunchMath.sol` at 100 % on the four columns). If a branch of `_split` or `_take` shows uncovered, the missing case is the one named in its `@dev` (a zero part, a zero-delta side); the two tests `..._with_nothing_accrued...` and `..._a_zero_share...` are the ones that cover them.

- [ ] **Step 7: Commit**

```bash
git add src/SVLaunchpad.sol src/interfaces/ISVLaunchpad.sol test/unit/SVLaunchpad.t.sol test/unit/SVLaunchpad.fees.t.sol
git commit -m "SVLaunchpad: collectFees with the zero-delta poke and the creator/fee wallet split

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016tofArVnM9erCZUwPku467"
```

### Task 7: Fuzz and invariant suites (spec 4.4), fuzz/invariant config, the coverage bar

**Files:**
- Modify: `foundry.toml` (append `[fuzz]` and `[invariant]` sections)
- Test: `test/unit/SVLaunchpad.fuzz.t.sol`, `test/unit/SVLaunchpad.invariant.t.sol`

**Interfaces:**
- Consumes: the fixture (`_create`, `_createWithFloor`, `_contribute`, `_fill`, `_launch`, `_rollUntilTokenSide`, `_positionLiquidity`, `_contributor`, `_contributorKey`, `swapRouter`, `manager`); forge-std `StdInvariant.targetContract(address)`, `targetSelector(FuzzSelector({addr, selectors}))`; `StateLibrary.getLiquidity(IPoolManager, PoolId)`.
- Produces: `contract LaunchpadHandler is Test` (the invariant runner's action surface: `claim(uint256 who)`, `claimCreator(uint256 jump)`, `collectFees()`, `swap(bool zeroForOne, uint256 amount)`, `contributeAgain(uint256 who)`, `refund(uint256 who)`, `finalize()`, `setPayout(address to)`).

- [ ] **Step 1: Add the fuzz and invariant sections**

Append to `foundry.toml` (after the `[fmt]` section):

```toml
# The launchpad suites. Fuzz runs are the default written out; invariant runs are the launched-raise handler
# of test/unit/SVLaunchpad.invariant.t.sol: every call is expected to revert or succeed on its own terms, so a
# revert is not a failure there.
[fuzz]
runs = 256

[invariant]
runs = 64
depth = 32
fail_on_revert = false
```

- [ ] **Step 2: Write the fuzz suite**

`test/unit/SVLaunchpad.fuzz.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SVLaunchToken} from "../../src/SVLaunchToken.sol";
import {SVLaunchpadTestBase} from "./SVLaunchpad.t.sol";

/// @notice Spec section 4.4, fuzz: random contribution sequences never exceed the target or any wallet's cap;
///         the quote held equals the sum of open contributions; claims sum to `soldTokens` within dust; and a
///         launch never takes more than it offered the pool, for any target in the USDG bounds and either
///         currency order. Contribution sequences are derived from one seed so no array fuzzing is involved.
contract SVLaunchpadFuzzTest is SVLaunchpadTestBase {
    uint256 internal constant STEPS = 24;

    function testFuzz_contributions_never_exceed_the_target_or_a_wallet_cap(uint256 seed) public {
        uint256 id = _create(address(usdg), USDG_TARGET);
        uint256 cap = USDG_TARGET / 10;
        uint256 held;
        for (uint256 i = 0; i < STEPS; i++) {
            uint256 who = uint256(keccak256(abi.encode(seed, i, "who"))) % CONTRIBUTORS;
            uint256 amount = bound(uint256(keccak256(abi.encode(seed, i, "amount"))), 1, cap * 2);
            uint256 before = launchpad.contributed(id, _contributor(who));
            if (before == cap) continue; // would revert WalletCapReached, which the contribute suite covers
            _contribute(_contributorKey(who), id, amount);
            uint256 taken = launchpad.contributed(id, _contributor(who)) - before;
            held += taken;
            assertLe(launchpad.getRaise(id).raised, USDG_TARGET, "raised above the target");
            assertLe(launchpad.contributed(id, _contributor(who)), cap, "a wallet above its cap");
            assertEq(taken, amount < cap - before ? amount : cap - before, "took the amount or trimmed it to the cap");
            if (launchpad.getRaise(id).status == 2) {
                assertEq(usdg.balanceOf(address(launchpad)), 0, "launched: the launchpad holds no quote");
                return;
            }
            assertEq(usdg.balanceOf(address(launchpad)), held, "the quote held equals the open contributions");
        }
    }

    /// @dev Ten wallets contribute between half the cap and the cap, so the raise ends between 50 and 100 % of
    ///      the target and launches either by filling or on the floor path; every claim is then paid and the sum
    ///      is `soldTokens` minus at most one unit of rounding per wallet.
    function testFuzz_claims_sum_to_soldTokens_within_dust(uint256 seed) public {
        uint256 id = _createWithFloor(address(usdg), USDG_TARGET, USDG_TARGET / 2);
        uint256 cap = USDG_TARGET / 10;
        for (uint256 i = 0; i < CONTRIBUTORS; i++) {
            _contribute(_contributorKey(i), id, bound(uint256(keccak256(abi.encode(seed, i))), cap / 2, cap));
        }
        if (launchpad.getRaise(id).status != 2) {
            vm.warp(block.timestamp + 1 days);
            vm.prank(stranger);
            launchpad.finalize(id);
        }
        uint256 raised = launchpad.getRaise(id).raised;
        uint256 soldTokens = FullMath.mulDiv(raised, SALE_TOKENS, USDG_TARGET);
        SVLaunchToken token = SVLaunchToken(launchpad.getRaise(id).token);
        uint256 sum;
        for (uint256 i = 0; i < CONTRIBUTORS; i++) {
            vm.prank(_contributor(i));
            launchpad.claim(id);
            sum += token.balanceOf(_contributor(i));
        }
        assertLe(sum, soldTokens, "claims above soldTokens");
        assertGe(sum, soldTokens - CONTRIBUTORS, "claims below soldTokens by more than one unit per wallet");
        assertEq(
            token.balanceOf(address(launchpad)), CREATOR_TOKENS + (soldTokens - sum), "the dust stays in the launchpad"
        );
    }

    /// @dev Spec section 4.3: the position takes at most the amounts offered; the token remainder is burned and
    ///      the quote remainder goes to the fee wallet. Any target within the USDG bounds, either currency order.
    function testFuzz_a_launch_never_takes_more_than_it_offered_the_pool(uint256 rawTarget, bool tokenIs0) public {
        uint256 target = bound(rawTarget, USDG_MIN, USDG_MAX);
        target = target - target % CONTRIBUTORS; // ten equal contributions fill it exactly
        (, Launched memory l) = _launch(usdg, target, tokenIs0);
        uint256 fee = target * FEE_BPS / 10_000;
        uint256 net = target - fee;
        uint256 tokensForPool = FullMath.mulDiv(net, SALE_TOKENS, target);
        assertEq(l.fee, fee, "fee");
        assertLe(l.quoteToPool, net, "quote: at most what was offered");
        assertGe(l.quoteToPool, net - net / 1e9 - 1, "quote: within a billionth of what was offered");
        assertLe(l.tokensToPool, tokensForPool, "tokens: at most what was offered");
        assertGe(l.tokensToPool, tokensForPool - tokensForPool / 1e9 - 1, "tokens: within a billionth");
        assertEq(l.tokensBurned, POOL_TOKENS - l.tokensToPool, "the unused pool tokens are burned");
        assertEq(
            usdg.balanceOf(feeWallet), fee + (net - l.quoteToPool), "the fee wallet holds the fee and the remainder"
        );
        assertEq(usdg.balanceOf(address(launchpad)), 0, "the launchpad holds no quote");
        assertEq(_slot0Price(_lastId()), l.sqrtPriceX96, "the pool opened at the stored price");
    }

    function _lastId() internal view returns (uint256) {
        return launchpad.nextId() - 1;
    }
}
```

- [ ] **Step 3: Write the invariant suite**

`test/unit/SVLaunchpad.invariant.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {SVLaunchpad} from "../../src/SVLaunchpad.sol";
import {SVLaunchToken} from "../../src/SVLaunchToken.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {SVLaunchpadTestBase} from "./SVLaunchpad.t.sol";

/// @notice Every call anyone can make against a launched raise, for the invariant runner to sequence at random:
///         claims, creator claims across time, fee collection, swaps in both directions, and the calls that must
///         revert after launch (contribute, refund, finalize). Reverts are expected and allowed
///         (`fail_on_revert = false`); the invariants are checked after every call.
contract LaunchpadHandler is Test {
    SVLaunchpad public immutable LAUNCHPAD;
    PoolSwapTest public immutable SWAP_ROUTER;
    uint256 public immutable ID;
    MockERC20 public immutable QUOTE;
    SVLaunchToken public immutable TOKEN;
    address public immutable CREATOR;
    address[] public contributors;

    constructor(
        SVLaunchpad launchpad,
        PoolSwapTest swapRouter,
        uint256 id,
        MockERC20 quote,
        SVLaunchToken token,
        address creator,
        address[] memory wallets
    ) {
        LAUNCHPAD = launchpad;
        SWAP_ROUTER = swapRouter;
        ID = id;
        QUOTE = quote;
        TOKEN = token;
        CREATOR = creator;
        contributors = wallets;
        quote.approve(address(swapRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
    }

    function claim(uint256 who) external {
        vm.prank(contributors[bound(who, 0, contributors.length - 1)]);
        LAUNCHPAD.claim(ID);
    }

    function claimCreator(uint256 jump) external {
        vm.warp(block.timestamp + bound(jump, 0, 10 days));
        vm.prank(CREATOR);
        LAUNCHPAD.claimCreator(ID);
    }

    function collectFees() external {
        LAUNCHPAD.collectFees(ID);
    }

    function swap(bool zeroForOne, uint256 amount) external {
        PoolKey memory key = LAUNCHPAD.poolKey(ID);
        MockERC20 tokenIn = MockERC20(Currency.unwrap(zeroForOne ? key.currency0 : key.currency1));
        amount = bound(amount, 1, tokenIn.balanceOf(address(this)) / 10 + 1);
        if (amount > tokenIn.balanceOf(address(this))) return;
        SWAP_ROUTER.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function contributeAgain(uint256 who) external {
        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(QUOTE), amount: 1}),
            nonce: 0,
            deadline: block.timestamp
        });
        vm.prank(contributors[bound(who, 0, contributors.length - 1)]);
        LAUNCHPAD.contribute(ID, 1, permit, "");
    }

    function refund(uint256 who) external {
        vm.prank(contributors[bound(who, 0, contributors.length - 1)]);
        LAUNCHPAD.refund(ID);
    }

    function finalize() external {
        LAUNCHPAD.finalize(ID);
    }

    function setPayout(address to) external {
        vm.prank(CREATOR);
        LAUNCHPAD.setPayout(ID, to);
    }
}

/// @notice Spec section 4.4, invariant: after launch, the position's liquidity never changes across any sequence
///         of calls, and the raise stays launched.
contract SVLaunchpadInvariantTest is SVLaunchpadTestBase {
    using StateLibrary for IPoolManager;

    LaunchpadHandler internal handler;
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        id = _create(address(usdg), USDG_TARGET);
        _fill(id);
        address[] memory wallets = new address[](CONTRIBUTORS);
        for (uint256 i = 0; i < CONTRIBUTORS; i++) {
            wallets[i] = _contributor(i);
        }
        SVLaunchToken token = SVLaunchToken(launchpad.getRaise(id).token);
        handler = new LaunchpadHandler(launchpad, swapRouter, id, usdg, token, creator, wallets);
        usdg.mint(address(handler), 10_000e6);
        // The handler sells tokens too: one contributor's claim is moved to it.
        vm.prank(_contributor(0));
        launchpad.claim(id);
        // Read before the prank: `balanceOf` is an external call and would consume it.
        uint256 claimedTokens = token.balanceOf(_contributor(0));
        vm.prank(_contributor(0));
        token.transfer(address(handler), claimedTokens);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.claim.selector;
        selectors[1] = handler.claimCreator.selector;
        selectors[2] = handler.collectFees.selector;
        selectors[3] = handler.swap.selector;
        selectors[4] = handler.contributeAgain.selector;
        selectors[5] = handler.refund.selector;
        selectors[6] = handler.finalize.selector;
        selectors[7] = handler.setPayout.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_position_liquidity_never_changes_after_launch() public view {
        uint128 stored = launchpad.getRaise(id).liquidity;
        assertGt(stored, 0, "the launch minted liquidity");
        assertEq(_positionLiquidity(id), stored, "the position's liquidity changed after launch");
        assertEq(
            manager.getLiquidity(launchpad.poolKey(id).toId()), stored, "the pool holds the launch position alone"
        );
    }

    function invariant_the_raise_stays_launched() public view {
        assertEq(launchpad.getRaise(id).status, 2, "status left Launched");
    }
}
```

- [ ] **Step 4: Run the two suites**

Run: `forge test --match-path 'test/unit/SVLaunchpad.fuzz.t.sol' -vv` then `forge test --match-path 'test/unit/SVLaunchpad.invariant.t.sol' -vv`
Expected: fuzz `3 passed` (256 runs each; the launch fuzz takes the longest, tens of seconds); invariant `2 passed` with `calls: 2048, reverts: <some>` (reverts are the expected `NotOpen`, `NotRefundable`, `NothingToClaim`, `AlreadyClaimed`, `ZeroAddress` and swaps against an empty side; they do not fail the run). If `_rollUntilTokenSide` ever reports no block within 256 tries, raise its bound: it is a coin flip per block.

- [ ] **Step 5: The coverage bar**

Run: `forge coverage --report summary --report lcov`
Expected: `src/SVLaunchpad.sol`, `src/SVLaunchToken.sol` and `src/libraries/LaunchMath.sol` at 100.00 % on Lines, Statements, Branches and Funcs (the summary may list only files with executable lines; `LaunchMath`'s inlined internal function may appear under its own path or not at all; either way `lcov.info` must show no `DA:` record with zero hits and no `BRDA:` record with a `-` or `0` for those three files: `grep -A2000 'SF:src/SVLaunchpad.sol' lcov.info | grep -m1 -E 'BRDA:.*,(0|-)$'` prints nothing). If a line or branch is uncovered, add the missing case to the suite that owns that function (Tasks 2 to 6 name them) rather than removing the branch. Then all gates: `forge fmt --check`, `forge build --sizes`, `forge lint`, `forge test`.

- [ ] **Step 6: Commit**

```bash
git add foundry.toml test/unit/SVLaunchpad.fuzz.t.sol test/unit/SVLaunchpad.invariant.t.sol
git commit -m "Fuzz and invariant suites: caps, claims within dust, launch amounts, liquidity locked after launch

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016tofArVnM9erCZUwPku467"
```

### Task 8: Fork suite against Robinhood Chain: USDG and NVDA raises, the real Permit2 and PoolManager, a swap through the Universal Router

**Files:**
- Test: `test/fork/SVLaunchpadFork.t.sol`

**Interfaces:**
- Consumes: the deployed PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951`, Permit2 `0x000000000022D473030F116dDEE9F6B43aC78BA3`, Universal Router `0x06AfBA43Fd06227fA663b0DAecF536f6EaA6bf99`, StateView `0xF3334192D15450CdD385c8B70e03f9A6bD9E673b` (`IStateView.getSlot0(PoolId) returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)`, `getPositionInfo(PoolId, address owner, int24 tickLower, int24 tickUpper, bytes32 salt) returns (uint128 liquidity, uint256, uint256)`), USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` (6 decimals), NVDA `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` (18 decimals); the existing `SVRouter(owner, feeWallet, universalRouter, permit2, suitsNft)` and `ISVRouter.SwapParams{key, zeroForOne, amountIn, amountOutMin, hookData, deadline}` with `swapExactIn(p, permit, signature)`; `Permit2Signer.sign`; the topic0 of the PoolManager's `Initialize` event, `0xdd466e674ea557f56295e2d0218a125ea4b4f0f6f3307b95f85e6110838d6438` (`cast keccak 'Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)'`).
- Produces: `contract SVLaunchpadForkTest is Test`, skipped without `ROBINHOOD_RPC_URL`.

- [ ] **Step 1: Pin the block**

The public RPC serves only recent state (README: "a pinned block was refused after about fifteen minutes once"). Before writing the file, read the head and pin a block a little behind it:

```sh
cast block-number --rpc-url "$ROBINHOOD_RPC_URL"
```

Put that number minus 100 into `FORK_BLOCK` below and the date and time into its comment. `66_115_626` in the code is the block SVRouter was deployed at (18 Sep 2026), a real block the archive endpoint serves; replace it, or pass `ROBINHOOD_FORK_BLOCK=<recent block>` at run time.

- [ ] **Step 2: Write the fork suite**

`test/fork/SVLaunchpadFork.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {SVLaunchpad} from "../../src/SVLaunchpad.sol";
import {ISVLaunchpad} from "../../src/interfaces/ISVLaunchpad.sol";
import {SVLaunchToken} from "../../src/SVLaunchToken.sol";
import {SVRouter} from "../../src/SVRouter.sol";
import {ISVRouter} from "../../src/interfaces/ISVRouter.sol";
import {Permit2Signer} from "../utils/Permit2Signer.sol";

/// @notice The launchpad against the real Robinhood Chain: a fresh `SVLaunchpad` in front of the deployed
///         PoolManager and the canonical Permit2, raising USDG and NVDA from `vm.addr` keys with real Permit2
///         signatures, launching, trading the new pool through a fresh `SVRouter` and the deployed Universal
///         Router, and collecting fees. The pool state is read through the deployed StateView, which was built
///         for the deployed PoolManager, so no assumption about its storage layout is made here.
///
/// @dev Skipping: `setUp` calls `vm.skip(true)` and returns when `ROBINHOOD_RPC_URL` is unset, so `forge test`
///      with no network reports these tests as skipped, never as failed. The pinned block goes stale on the
///      public endpoint within minutes (see test/fork/SVRouterFork.t.sol); pass `ROBINHOOD_FORK_BLOCK=<recent>`
///      or use an archive endpoint. Every assertion is relative to the forked state.
///
///      If the launch reverts inside `POOL_MANAGER.initialize` with empty revert data, the deployed PoolManager
///      does not expose v4.0.0's two-argument `initialize(PoolKey,uint160)`; confirm with
///      `cast call $POOL_MANAGER 'initialize((address,address,uint24,int24,address),uint160)(int24)' ...` on an
///      unused key and report before changing the contract: that call shape is a spec decision (section 4).
contract SVLaunchpadForkTest is Test {
    /// @dev Robinhood Chain (id 4663). Re-pin per Step 1 of the task before running.
    uint256 internal constant FORK_BLOCK = 66_115_626;

    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant UNIVERSAL_ROUTER = 0x06AfBA43Fd06227fA663b0DAecF536f6EaA6bf99;
    IStateView internal constant STATE_VIEW = IStateView(0xF3334192D15450CdD385c8B70e03f9A6bD9E673b);
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // 6 decimals
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC; // 18 decimals
    bytes32 internal constant INITIALIZE_TOPIC = 0xdd466e674ea557f56295e2d0218a125ea4b4f0f6f3307b95f85e6110838d6438;

    uint256 internal constant CREATOR_KEY = 0xC4EA;
    uint256 internal constant OWNER_KEY = 0x0E7E;
    uint256 internal constant FEE_WALLET_KEY = 0xFEE7;
    uint256 internal constant ROUTER_FEE_WALLET_KEY = 0xFEE8;
    uint256 internal constant TRADER_KEY = 0x7A4DE;
    uint256 internal constant CONTRIBUTOR_KEY_BASE = 0xC0000;
    uint256 internal constant CONTRIBUTORS = 10;

    uint16 internal constant FEE_BPS = 200;
    uint16 internal constant CREATOR_FEE_SHARE_BPS = 7000;
    /// @dev USD 100 of USDG: the minimum is lowered for the test, as the spec's rehearsal (section 10) does.
    uint256 internal constant USDG_TARGET = 100e6;
    /// @dev One NVDA, floor at half: six wallets at the cap reach 60 %.
    uint256 internal constant NVDA_TARGET = 1e18;
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    uint256 internal constant SALE_TOKENS = 450_000_000e18;
    uint256 internal constant CREATOR_TOKENS = 100_000_000e18;
    uint256 internal constant USDG_FUND = 1_000e6;
    uint256 internal constant NVDA_FUND = 10e18;
    int24 internal constant TICK_LOWER = -887_200;
    int24 internal constant TICK_UPPER = 887_200;

    address internal creator;
    address internal owner;
    address internal feeWallet;
    address internal routerFeeWallet;
    address internal trader;
    SVLaunchpad internal launchpad;
    SVRouter internal router;
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
        routerFeeWallet = vm.addr(ROUTER_FEE_WALLET_KEY);
        trader = vm.addr(TRADER_KEY);
        vm.label(creator, "creator");
        vm.label(owner, "owner");
        vm.label(feeWallet, "feeWallet");
        vm.label(trader, "trader");
        vm.label(POOL_MANAGER, "PoolManager");
        vm.label(PERMIT2, "Permit2");
        vm.label(UNIVERSAL_ROUTER, "UniversalRouter");
        vm.label(USDG, "USDG");
        vm.label(NVDA, "NVDA");

        launchpad = new SVLaunchpad(
            IPoolManager(POOL_MANAGER), ISignatureTransfer(PERMIT2), owner, feeWallet, FEE_BPS, CREATOR_FEE_SHARE_BPS
        );
        vm.startPrank(owner);
        launchpad.setQuote(USDG, 10e6, 250_000e6);
        launchpad.setQuote(NVDA, 1e17, 1_250e18);
        vm.stopPrank();
        // A fresh router with its own fee wallet, so the launchpad's fee wallet only ever receives launchpad money.
        router = new SVRouter(owner, routerFeeWallet, UNIVERSAL_ROUTER, PERMIT2, address(0));

        // Funding by `deal`, asserted, as the router's fork suite does; see the note below if it fails.
        for (uint256 i = 0; i < CONTRIBUTORS; i++) {
            _fund(_contributor(i));
        }
        _fund(creator);
        _fund(trader);
    }

    /// @dev `deal` finds the balance slot of NVDA (proven by the router's fork suite) and, this suite asserts,
    ///      of USDG. If the USDG assertion fails, replace the `deal` with a prank of the PoolManager, which holds
    ///      USDG for the live pools: `vm.prank(POOL_MANAGER); IERC20(USDG).transfer(wallet, USDG_FUND);`.
    function _fund(address wallet) internal {
        deal(USDG, wallet, USDG_FUND);
        deal(NVDA, wallet, NVDA_FUND);
        assertEq(IERC20(USDG).balanceOf(wallet), USDG_FUND, "deal did not fund USDG");
        assertEq(IERC20(NVDA).balanceOf(wallet), NVDA_FUND, "deal did not fund NVDA");
        vm.startPrank(wallet);
        IERC20(USDG).approve(PERMIT2, type(uint256).max);
        IERC20(NVDA).approve(PERMIT2, type(uint256).max);
        vm.stopPrank();
    }

    function _contributorKey(uint256 i) internal pure returns (uint256) {
        return CONTRIBUTOR_KEY_BASE + i;
    }

    function _contributor(uint256 i) internal pure returns (address) {
        return vm.addr(_contributorKey(i));
    }

    function _params(address quote, uint256 target, uint256 floor)
        internal
        view
        returns (ISVLaunchpad.CreateParams memory)
    {
        return ISVLaunchpad.CreateParams({
            name: "Fork Launch",
            symbol: "FORK",
            image: "https://example.com/fork.png",
            website: "https://example.com",
            x: "",
            telegram: "",
            quote: quote,
            target: target,
            floor: floor,
            // forge-lint: disable-next-line(unsafe-typecast)
            start: uint64(block.timestamp),
            duration: 1 days
        });
    }

    /// @dev Signed before the prank on purpose: signing reads Permit2's `DOMAIN_SEPARATOR()`, an external call.
    function _contribute(uint256 privateKey, uint256 id, address quote, uint256 amount) internal {
        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: quote, amount: amount}),
            nonce: nextNonce++,
            deadline: block.timestamp + 1 hours
        });
        bytes memory signature = Permit2Signer.sign(privateKey, PERMIT2, permit, address(launchpad));
        vm.prank(vm.addr(privateKey));
        launchpad.contribute(id, amount, permit, signature);
    }

    function _slot0Price(uint256 id) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = STATE_VIEW.getSlot0(launchpad.poolKey(id).toId());
    }

    function _positionLiquidity(uint256 id) internal view returns (uint128 liquidity) {
        (liquidity,,) = STATE_VIEW.getPositionInfo(
            launchpad.poolKey(id).toId(), address(launchpad), TICK_LOWER, TICK_UPPER, bytes32(0)
        );
    }

    // -------------------------------------------------------------------------------------------------------
    // The tests
    // -------------------------------------------------------------------------------------------------------

    function test_usdg_raise_fills_launches_trades_through_the_universal_router_and_collects_fees() public {
        vm.prank(creator);
        uint256 id = launchpad.create(_params(USDG, USDG_TARGET, USDG_TARGET));
        vm.recordLogs();
        for (uint256 i = 0; i < CONTRIBUTORS; i++) {
            _contribute(_contributorKey(i), id, USDG, USDG_TARGET / CONTRIBUTORS);
        }
        ISVLaunchpad.Raise memory r = launchpad.getRaise(id);
        assertEq(r.status, 2, "launched by the tenth contribution");
        assertTrue(r.token != address(0), "token deployed");
        PoolKey memory key = launchpad.poolKey(id);
        bytes32 poolId = PoolId.unwrap(key.toId());

        // The launch transaction's `Initialize` log from the PoolManager carries the expected pool id.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 initializes;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != POOL_MANAGER || logs[i].topics[0] != INITIALIZE_TOPIC) continue;
            initializes++;
            assertEq(logs[i].topics[1], poolId, "Initialize.id is the launch pool");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), Currency.unwrap(key.currency0), "currency0");
            assertEq(address(uint160(uint256(logs[i].topics[3]))), Currency.unwrap(key.currency1), "currency1");
        }
        assertEq(initializes, 1, "exactly one Initialize in the launch");

        // Spec 4.3 on the real PoolManager: slot0 equals the stored price, the position holds L.
        assertEq(_slot0Price(id), r.sqrtPriceX96, "slot0 price equals the stored sqrtPriceX96");
        assertEq(_positionLiquidity(id), r.liquidity, "position liquidity equals the stored liquidity");
        assertGt(r.liquidity, 0, "liquidity above zero");
        assertGe(
            IERC20(USDG).balanceOf(feeWallet), USDG_TARGET * FEE_BPS / 10_000, "fee wallet holds the fee (plus dust)"
        );
        assertEq(IERC20(USDG).balanceOf(address(launchpad)), 0, "the launchpad holds no USDG");

        // A claim.
        vm.prank(_contributor(0));
        launchpad.claim(id);
        assertEq(
            IERC20(r.token).balanceOf(_contributor(0)),
            (USDG_TARGET / CONTRIBUTORS) * SALE_TOKENS / USDG_TARGET,
            "claimed tokens"
        );

        // A buy through the fresh SVRouter and the deployed Universal Router: 5 USDG for tokens.
        bool usdgIs0 = Currency.unwrap(key.currency0) == USDG;
        uint128 amountIn = 5e6;
        ISVRouter.SwapParams memory p = ISVRouter.SwapParams({
            key: key,
            zeroForOne: usdgIs0,
            amountIn: amountIn,
            amountOutMin: 1,
            hookData: "",
            deadline: block.timestamp + 1 hours
        });
        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: USDG, amount: amountIn}),
            nonce: nextNonce++,
            deadline: block.timestamp + 1 hours
        });
        bytes memory signature = Permit2Signer.sign(TRADER_KEY, PERMIT2, permit, address(router));
        vm.prank(trader);
        uint256 amountOut = router.swapExactIn(p, permit, signature);
        assertGt(amountOut, 0, "the Universal Router traded the launch pool");
        assertEq(IERC20(r.token).balanceOf(trader), amountOut, "the trader holds the tokens");
        console2.log("5 USDG bought tokens:", amountOut);

        // Fees: 1 % of the router's net input accrued to the position; 70 % to the creator, 30 % to the fee wallet.
        uint256 feeWalletBefore = IERC20(USDG).balanceOf(feeWallet);
        uint256 creatorBefore = IERC20(USDG).balanceOf(creator);
        launchpad.collectFees(id);
        uint256 creatorGain = IERC20(USDG).balanceOf(creator) - creatorBefore;
        uint256 platformGain = IERC20(USDG).balanceOf(feeWallet) - feeWalletBefore;
        (uint256 routerFee,) = router.feeFor(trader, amountIn);
        assertApproxEqAbs(creatorGain + platformGain, (amountIn - routerFee) / 100, 2, "1 % of the pool's input");
        assertEq(creatorGain, (creatorGain + platformGain) * CREATOR_FEE_SHARE_BPS / 10_000, "70 % to the creator");
        assertEq(_positionLiquidity(id), r.liquidity, "the poke left the liquidity untouched");
    }

    function test_nvda_raise_launches_on_the_floor_path_by_a_stranger() public {
        vm.prank(creator);
        uint256 id = launchpad.create(_params(NVDA, NVDA_TARGET, NVDA_TARGET / 2));
        for (uint256 i = 0; i < 6; i++) {
            _contribute(_contributorKey(i), id, NVDA, NVDA_TARGET / 10);
        }
        vm.warp(block.timestamp + 1 days);
        vm.prank(trader);
        launchpad.finalize(id);
        ISVLaunchpad.Raise memory r = launchpad.getRaise(id);
        assertEq(r.status, 2, "launched at 60 % of the target");
        assertEq(_slot0Price(id), r.sqrtPriceX96, "slot0 price equals the stored price");
        assertEq(_positionLiquidity(id), r.liquidity, "position liquidity equals the stored liquidity");
        uint256 raised = NVDA_TARGET * 6 / 10;
        uint256 soldTokens = raised * SALE_TOKENS / NVDA_TARGET;
        assertEq(
            SVLaunchToken(r.token).balanceOf(address(launchpad)), soldTokens + CREATOR_TOKENS, "unsold tokens burned"
        );
        assertEq(IERC20(NVDA).balanceOf(address(launchpad)), 0, "the launchpad holds no NVDA");
    }

    function test_a_raise_under_its_floor_refunds_in_full() public {
        vm.prank(creator);
        uint256 id = launchpad.create(_params(USDG, USDG_TARGET, USDG_TARGET));
        _contribute(_contributorKey(0), id, USDG, 3e6);
        _contribute(_contributorKey(1), id, USDG, 7e6);
        vm.warp(block.timestamp + 1 days);
        vm.prank(_contributor(0));
        launchpad.refund(id);
        vm.prank(_contributor(1));
        launchpad.refund(id);
        assertEq(IERC20(USDG).balanceOf(_contributor(0)), USDG_FUND, "wallet 0 made whole");
        assertEq(IERC20(USDG).balanceOf(_contributor(1)), USDG_FUND, "wallet 1 made whole");
        assertEq(launchpad.getRaise(id).status, 3, "closed");
        vm.prank(_contributor(0));
        vm.expectRevert(ISVLaunchpad.NotLaunched.selector);
        launchpad.claim(id);
    }
}
```

- [ ] **Step 3: Run without the RPC to verify it skips, then with it**

Run: `forge test --match-path 'test/fork/*'`
Expected: `SVLaunchpadForkTest` reports `skipped` (as `SVRouterForkTest` does).

Run: `ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-path 'test/fork/SVLaunchpadFork.t.sol' -vv` (add `ROBINHOOD_FORK_BLOCK=<recent block>` if the pin has aged out; use the archive endpoint from `.env` for repeated runs).
Expected: `3 passed, 0 failed`, with `forked block`, and `5 USDG bought tokens:` in the log. If `deal did not fund USDG` fails, apply the PoolManager-prank fallback in `_fund`'s comment. If the first test reverts inside `initialize`, follow the contract-level `@dev` note (report; do not change the call shape on your own).

- [ ] **Step 4: Commit**

```bash
git add test/fork/SVLaunchpadFork.t.sol
git commit -m "Fork tests: USDG and NVDA raises on the real PoolManager, Permit2 signatures, a swap through the Universal Router, fees

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016tofArVnM9erCZUwPku467"
```

### Task 9: `script/DeployLaunchpad.s.sol` with `QUOTES_JSON`, its unit test, README, `.env.example`, verify docs, gas snapshot

**Files:**
- Create: `script/DeployLaunchpad.s.sol`
- Test: `test/unit/DeployLaunchpad.t.sol`
- Modify: `.env.example` (append the launchpad inputs)
- Modify: `README.md` (title, a launchpad section, layout rows, build notes, env table rows, deploy and verify commands, the deployment table)
- Create: `.gas-snapshot` (by `forge snapshot`)
- Create (untracked, like the router's): `docs/verify/SVLaunchpad.standard-input.json`, `docs/verify/launchpad-constructor-args.hex` at deploy time

**Interfaces:**
- Consumes: `SVLaunchpad` constructor `(IPoolManager, ISignatureTransfer, address owner, address feeWallet, uint16 feeBps, uint16 creatorFeeShareBps)` and `setQuote(address, uint256, uint256)`; `LaunchMath.sqrtPriceX96For`; OZ `IERC20Metadata.decimals()`; forge cheatcodes `vm.envAddress`, `vm.envUint`, `vm.envString`, `vm.envOr(string, bool)`, `vm.keyExistsJson(string json, string key)`, `vm.parseJsonAddress/parseJsonString/parseJsonUint(string json, string key)`, `vm.toString(uint256)`.
- Produces: `contract DeployLaunchpad is Script` with `run() returns (SVLaunchpad)`, `struct QuoteRow {address asset; string symbol; uint256 decimals; uint256 minTarget; uint256 maxTarget;}`, `parseQuotes(string memory json) public view returns (QuoteRow[] memory)`, `checkQuote(QuoteRow memory row) public view returns (uint160 minPrice, uint160 maxPrice)` (the token-first prices at the two bounds). The `QUOTES_JSON` shape the frontend's `scripts/launchpad-quotes.mts` must produce: a JSON array of objects `{ "asset": "0x…" (EIP-55 or lower-case), "symbol": "USDG", "decimals": 6, "minTarget": "1000000000", "maxTarget": "250000000000" }`, targets as raw-unit decimal strings (numbers are accepted too), passed to the script as the text of the environment variable `QUOTES_JSON`.

- [ ] **Step 1: Write the failing test**

`test/unit/DeployLaunchpad.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployLaunchpad} from "../../script/DeployLaunchpad.s.sol";
import {ISVLaunchpad} from "../../src/interfaces/ISVLaunchpad.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice The deploy script's pure parts: the `QUOTES_JSON` shape and the per-row checks. `run()` itself needs
///         a chain and an environment and is not executed by a test, as for the router's script.
contract DeployLaunchpadTest is Test {
    DeployLaunchpad internal script;
    MockERC20 internal usdg;
    MockERC20 internal stock;

    function setUp() public {
        script = new DeployLaunchpad();
        usdg = new MockERC20("USD Global", "USDG", 6);
        stock = new MockERC20("Stock", "STK", 18);
    }

    function _json() internal view returns (string memory) {
        return string.concat(
            '[{"asset":"',
            vm.toString(address(usdg)),
            '","symbol":"USDG","decimals":6,"minTarget":"1000000000","maxTarget":"250000000000"},',
            '{"asset":"',
            vm.toString(address(stock)),
            '","symbol":"STK","decimals":18,"minTarget":"10000000000000000000","maxTarget":"2500000000000000000000"}]'
        );
    }

    function test_parseQuotes_reads_every_row_with_string_numbers_as_raw_amounts() public view {
        DeployLaunchpad.QuoteRow[] memory rows = script.parseQuotes(_json());
        assertEq(rows.length, 2, "two rows");
        assertEq(rows[0].asset, address(usdg), "row 0 asset");
        assertEq(rows[0].symbol, "USDG", "row 0 symbol");
        assertEq(rows[0].decimals, 6, "row 0 decimals");
        assertEq(rows[0].minTarget, 1_000e6, "row 0 min from a string");
        assertEq(rows[0].maxTarget, 250_000e6, "row 0 max from a string");
        assertEq(rows[1].asset, address(stock), "row 1 asset");
        assertEq(rows[1].minTarget, 10e18, "row 1 min");
        assertEq(rows[1].maxTarget, 2_500e18, "row 1 max");
    }

    function test_parseQuotes_returns_no_rows_for_an_empty_array() public view {
        assertEq(script.parseQuotes("[]").length, 0, "no rows");
    }

    function test_checkQuote_accepts_the_default_rows_and_returns_their_token_first_prices() public view {
        DeployLaunchpad.QuoteRow[] memory rows = script.parseQuotes(_json());
        (uint160 usdgMin, uint160 usdgMax) = script.checkQuote(rows[0]);
        (uint160 stockMin, uint160 stockMax) = script.checkQuote(rows[1]);
        assertGt(usdgMin, 0, "USDG: a price at the minimum target");
        assertGt(usdgMax, usdgMin, "USDG: a larger target opens at a higher token-first price");
        assertGt(stockMin, 0, "stock: a price at the minimum target");
        assertGt(stockMax, stockMin, "stock: same ordering");
    }

    function test_checkQuote_rejects_a_zero_asset() public {
        DeployLaunchpad.QuoteRow memory row = script.parseQuotes(_json())[0];
        row.asset = address(0);
        vm.expectRevert(bytes("quote asset is zero"));
        script.checkQuote(row);
    }

    function test_checkQuote_rejects_a_zero_minimum() public {
        DeployLaunchpad.QuoteRow memory row = script.parseQuotes(_json())[0];
        row.minTarget = 0;
        vm.expectRevert(bytes("quote bounds: need 0 < minTarget <= maxTarget"));
        script.checkQuote(row);
    }

    function test_checkQuote_rejects_a_minimum_above_the_maximum() public {
        DeployLaunchpad.QuoteRow memory row = script.parseQuotes(_json())[0];
        row.minTarget = row.maxTarget + 1;
        vm.expectRevert(bytes("quote bounds: need 0 < minTarget <= maxTarget"));
        script.checkQuote(row);
    }

    function test_checkQuote_rejects_wrong_decimals() public {
        DeployLaunchpad.QuoteRow memory row = script.parseQuotes(_json())[0];
        row.decimals = 18;
        vm.expectRevert(bytes("quote decimals differ from the token's"));
        script.checkQuote(row);
    }

    function test_checkQuote_rejects_a_minimum_whose_price_cannot_be_represented() public {
        DeployLaunchpad.QuoteRow memory row = script.parseQuotes(_json())[0];
        // 2e7 raw units: fine with the token as currency0, overflows with the quote as currency0 (spec 4.3).
        row.minTarget = 20_000_000;
        vm.expectRevert(ISVLaunchpad.TargetOutOfRange.selector);
        script.checkQuote(row);
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `forge test --match-path test/unit/DeployLaunchpad.t.sol`
Expected: compilation fails, `Source "../../script/DeployLaunchpad.s.sol" not found`.

- [ ] **Step 3: Write the script**

`script/DeployLaunchpad.s.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {SVLaunchpad} from "../src/SVLaunchpad.sol";
import {LaunchMath} from "../src/libraries/LaunchMath.sol";

/// @notice Deploys SVLaunchpad on Robinhood Chain from environment variables and enables the quote assets listed
///         in `QUOTES_JSON` (see .env.example and the README).
/// @dev The deployer key is never in the environment: pass it to forge with --account, --ledger or --interactive.
///      `QUOTES_JSON` holds the JSON text itself (not a path: `fs_permissions` is empty by design), produced by
///      the frontend's `scripts/launchpad-quotes.mts`. Example:
///
///        QUOTES_JSON="$(cat ../SuitVenturesMarket-frontend/launchpad-quotes.json)" \
///        forge script script/DeployLaunchpad.s.sol --rpc-url robinhood --account <name> --broadcast \
///          --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api
///
///      The script refuses any chain but Robinhood Chain, and any PoolManager or Permit2 address but the chain's
///      unless ALLOW_OTHER_ADDRESSES=true is set on purpose. Every quote row is checked before anything is
///      broadcast: bounds, the token's decimals, and the presale price in both currency orders at the minimum
///      and the maximum target (spec section 4.3), so no enabled asset can accept a raise that cannot launch.
contract DeployLaunchpad is Script {
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    address internal constant ROBINHOOD_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint256 internal constant SALE_TOKENS = 450_000_000e18;
    uint256 internal constant MAX_FEE_BPS = 500;
    uint256 internal constant BPS = 10_000;

    /// @notice One row of `QUOTES_JSON`: `{"asset": "0x…", "symbol": "USDG", "decimals": 6,
    ///         "minTarget": "1000000000", "maxTarget": "250000000000"}`; the targets are raw units as strings.
    struct QuoteRow {
        address asset;
        string symbol;
        uint256 decimals;
        uint256 minTarget;
        uint256 maxTarget;
    }

    function run() external returns (SVLaunchpad launchpad) {
        address owner = vm.envAddress("OWNER");
        address feeWallet = vm.envAddress("FEE_WALLET");
        address poolManager = vm.envAddress("POOL_MANAGER");
        address permit2 = vm.envAddress("PERMIT2");
        uint256 feeBps = vm.envUint("FEE_BPS");
        uint256 creatorFeeShareBps = vm.envUint("CREATOR_FEE_SHARE_BPS");
        QuoteRow[] memory rows = parseQuotes(vm.envString("QUOTES_JSON"));

        require(block.chainid == ROBINHOOD_CHAIN_ID, "not Robinhood Chain (chain id 4663): check --rpc-url");
        if (!vm.envOr("ALLOW_OTHER_ADDRESSES", false)) {
            require(
                poolManager == ROBINHOOD_POOL_MANAGER,
                "POOL_MANAGER is not the chain's PoolManager; set ALLOW_OTHER_ADDRESSES=true to override"
            );
            require(
                permit2 == CANONICAL_PERMIT2, "PERMIT2 is not the canonical Permit2; set ALLOW_OTHER_ADDRESSES=true"
            );
        }
        // The two counterparties must exist on the target chain.
        require(poolManager.code.length != 0, "POOL_MANAGER has no code on this chain");
        require(permit2.code.length != 0, "PERMIT2 has no code on this chain");
        require(feeBps <= MAX_FEE_BPS, "FEE_BPS above 500");
        require(creatorFeeShareBps <= BPS, "CREATOR_FEE_SHARE_BPS above 10000");
        require(rows.length != 0, "QUOTES_JSON has no rows");
        for (uint256 i = 0; i < rows.length; i++) {
            checkQuote(rows[i]);
        }

        vm.startBroadcast();
        launchpad = new SVLaunchpad(
            IPoolManager(poolManager),
            ISignatureTransfer(permit2),
            owner,
            feeWallet,
            // Both bounded by the requires above.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint16(feeBps),
            // forge-lint: disable-next-line(unsafe-typecast)
            uint16(creatorFeeShareBps)
        );
        for (uint256 i = 0; i < rows.length; i++) {
            launchpad.setQuote(rows[i].asset, rows[i].minTarget, rows[i].maxTarget);
        }
        vm.stopBroadcast();

        console.log("SVLaunchpad deployed at:", address(launchpad));
        console.log("  chain id:              ", block.chainid);
        console.log("  owner:                 ", owner);
        console.log("  fee wallet:            ", feeWallet);
        console.log("  pool manager:          ", poolManager);
        console.log("  permit2:               ", permit2);
        console.log("  fee bps:               ", feeBps);
        console.log("  creator fee share bps: ", creatorFeeShareBps);
        for (uint256 i = 0; i < rows.length; i++) {
            console.log("  quote enabled:", rows[i].symbol, rows[i].asset);
            console.log("    min / max:", rows[i].minTarget, rows[i].maxTarget);
        }
    }

    /// @notice Parses `QUOTES_JSON`, an array of `QuoteRow` objects; string numbers are accepted for the targets.
    function parseQuotes(string memory json) public view returns (QuoteRow[] memory rows) {
        uint256 count;
        while (vm.keyExistsJson(json, string.concat("$[", vm.toString(count), "]"))) {
            count++;
        }
        rows = new QuoteRow[](count);
        for (uint256 i = 0; i < count; i++) {
            string memory at = string.concat("$[", vm.toString(i), "].");
            rows[i] = QuoteRow({
                asset: vm.parseJsonAddress(json, string.concat(at, "asset")),
                symbol: vm.parseJsonString(json, string.concat(at, "symbol")),
                decimals: vm.parseJsonUint(json, string.concat(at, "decimals")),
                minTarget: vm.parseJsonUint(json, string.concat(at, "minTarget")),
                maxTarget: vm.parseJsonUint(json, string.concat(at, "maxTarget"))
            });
        }
    }

    /// @notice One row's checks: non-zero asset, `0 < minTarget <= maxTarget`, the token's `decimals()` on
    ///         chain equals the row's, and the presale price is representable in both currency orders at both
    ///         bounds (spec section 4.3; reverts `TargetOutOfRange` otherwise). Returns the token-first prices at
    ///         the two bounds, so a caller can see what it checked.
    function checkQuote(QuoteRow memory row) public view returns (uint160 minPrice, uint160 maxPrice) {
        require(row.asset != address(0), "quote asset is zero");
        require(row.minTarget != 0 && row.minTarget <= row.maxTarget, "quote bounds: need 0 < minTarget <= maxTarget");
        require(IERC20Metadata(row.asset).decimals() == row.decimals, "quote decimals differ from the token's");
        minPrice = LaunchMath.sqrtPriceX96For(SALE_TOKENS, row.minTarget);
        LaunchMath.sqrtPriceX96For(row.minTarget, SALE_TOKENS);
        maxPrice = LaunchMath.sqrtPriceX96For(SALE_TOKENS, row.maxTarget);
        LaunchMath.sqrtPriceX96For(row.maxTarget, SALE_TOKENS);
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `forge test --match-path test/unit/DeployLaunchpad.t.sol -vv`
Expected: `8 passed, 0 failed`. `forge lint` clean (the two casts carry their reasons).

- [ ] **Step 5: `.env.example`**

Append to `.env.example`:

```
# Inputs of script/DeployLaunchpad.s.sol, in addition to OWNER and FEE_WALLET above.
# Chain fact: the Uniswap v4 PoolManager on Robinhood Chain (the script refuses another address unless
# ALLOW_OTHER_ADDRESSES=true).
POOL_MANAGER=0x8366a39CC670B4001A1121B8F6A443A643e40951
# Launch fee in basis points, at most 500 (2 % = 200), and the creator's share of collected pool fees (70 % = 7000).
FEE_BPS=200
CREATOR_FEE_SHARE_BPS=7000
# The JSON text (not a path) of the quote assets to enable at deploy, produced by the frontend's
# scripts/launchpad-quotes.mts: an array of {"asset", "symbol", "decimals", "minTarget", "maxTarget"} with the
# targets as raw-unit strings. One line. Example with USDG alone:
# QUOTES_JSON='[{"asset":"0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168","symbol":"USDG","decimals":6,"minTarget":"1000000000","maxTarget":"250000000000"}]'
```

- [ ] **Step 6: README**

Make these edits to `README.md`:

(a) Title and intro: change the first line to `# SVRouter and SVLaunchpad` and add after the intro paragraph:

```markdown
The second contract, `SVLaunchpad`, is the LongMarkets token launchpad: a fixed-price raise in an admin-enabled
quote asset that, on success, deploys the token (`SVLaunchToken`), seeds a locked full-range Uniswap v4 pool at
the presale price in one transaction, and on failure refunds every contributor in full.

- Launchpad spec (binding): the frontend repo's `docs/superpowers/specs/2026-09-27-launchpad-design.md`, section 4
- Launchpad plan: [`docs/superpowers/plans/2026-09-27-launchpad-contracts.md`](docs/superpowers/plans/2026-09-27-launchpad-contracts.md)
```

(b) Insert a section `## SVLaunchpad: how to review` before `## Layout`:

```markdown
## SVLaunchpad: how to review

1. **The design (20 min):** the spec's section 3 (the defaults and why) and section 4 (the contracts).
2. **The contracts (60 min):** `src/interfaces/ISVLaunchpad.sol` (every event, error and function; the frontend
   decodes and calls against this file), `src/SVLaunchToken.sol`, `src/libraries/LaunchMath.sol`, then
   `src/SVLaunchpad.sol` top to bottom. The body comments carry the spec's step numbers.

   | Spec rule | Where in `src/SVLaunchpad.sol` |
   |---|---|
   | Constants of 4.2, fee cap 5 %, deploy values emitted as `<Thing>Changed` | the constants block; the constructor |
   | `create`: creation open, the gate as a capped static call, every bound, the price in both currency orders | `create`, `_mayLaunch`, `_checkText`, `LaunchMath.sqrtPriceX96For` |
   | `contribute`: window, 10 % cap, trimming, Permit2 pulls exactly the trimmed amount, auto-launch at target | `contribute` |
   | The launch: CREATE2 token with the spec's salt, price, `initialize`, one full-range position, burn, dust, `Finalized` | `finalize`, `_finalize`, `_deployToken`, `unlockCallback`, `_unlock`, `_mintPosition`, `_settle` |
   | The lock: the position is owned by the launchpad and no code path carries a negative `liquidityDelta` | `_mintPosition` (`+L`), `_collectPosition` (`0`); `test/unit/SVLaunchpad.invariant.t.sol` |
   | Claims and the 90-day creator vesting | `claim`, `claimCreator` |
   | Refunds under the floor at the deadline, and the 7-day stall valve | `refund` |
   | Fee collection: the zero-delta poke, `take`, the split fixed at creation | `collectFees`, `_collectPosition`, `_take`, `_split` |
   | Only the PoolManager, only during our own unlock | `unlockCallback` (`NotPoolManager`, `UnexpectedCallback`, the transient flag) |
   | Owner settings, two-step ownership, no renounce | the settings block |

3. **What the unit suites prove (40 min):** `test/unit/SVLaunchpad.t.sol` (fixture, constructor, settings,
   `create`), `SVLaunchpad.contribute.t.sol`, `SVLaunchpad.launch.t.sol` (both quote decimals, both currency
   orders, the floor path, the burn and dust accounting), `SVLaunchpad.claims.t.sol` (claims, vesting, refunds,
   the stall valve with a PoolManager that is down), `SVLaunchpad.fees.t.sol` (swaps through v4-core's test
   router, the 70/30 split), `SVLaunchpad.fuzz.t.sol`, `SVLaunchpad.invariant.t.sol`, `LaunchMath.t.sol`,
   `SVLaunchToken.t.sol`, `DeployLaunchpad.t.sol`.
4. **What the fork suite proves (15 min):** `test/fork/SVLaunchpadFork.t.sol`: a USDG raise and an NVDA raise on
   the real PoolManager with real Permit2 signatures, the `Initialize` log with the expected pool id, the pool's
   price and the position's liquidity read through the deployed StateView, a swap through a fresh `SVRouter` and
   the deployed Universal Router, fee collection, and a refund.

**Decisions that are yours** (spec section 3, the defaults pending MAXLONG): anyone may launch; 2 % fee; 45/45/10
with the creator's tenth over 90 days; USD 1,000 to 250,000 per asset; creator-set floor 50 to 100 %; LP fee 1 %,
collected fees 70/30. Two choices made in the build, flagged for you: a zero-contribution `refund` reverts
`NothingToClaim` (so a stranger cannot close a raise), and `setQuote(address(0), ...)` reverts `ZeroAddress`.

**Run it yourself:**

```
forge build --sizes                  # SVLaunchpad about 20.5 KB at 200 optimizer runs (see Build)
forge test                           # every unit suite; the fork files report skipped
forge coverage --report summary      # bar: 100 % on src/SVLaunchpad.sol, src/SVLaunchToken.sol, src/libraries/LaunchMath.sol
forge snapshot --check               # gas of every test against .gas-snapshot
ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-path 'test/fork/SVLaunchpadFork.t.sol' -vv
```

A launch costs about 2.2 million gas (the launching contribution in `SVLaunchpad.launch.t.sol` logs the figure;
`.gas-snapshot` lists every test): one token deployment, one pool initialisation, one position mint.

## Deployments (Robinhood Chain, chain id 4663)

| Contract | Address | Block | Notes |
|---|---|---|---|
| `SVRouter` | `0xc9E6b76aA834e746080b1F8Ad6943930eD5147a9` | 66,115,626 | 18 Sep 2026; `feeBps` 50, `holderFeeBps` 0, no Suits NFT |
| `SVLaunchpad` | not deployed yet | | after Kobe's review: fill this row from `broadcast/DeployLaunchpad.s.sol/4663/run-latest.json` (`jq -r '.transactions[0].contractAddress, .receipts[0].blockNumber'`) |
```

(c) Layout table: add rows

```markdown
| `src/SVLaunchpad.sol` | the launchpad singleton (spec section 4.2) |
| `src/SVLaunchToken.sol` | the fixed-supply launch token (spec section 4.1) |
| `src/libraries/LaunchMath.sol` | the presale price as a v4 `sqrtPriceX96`, both currency orders (spec section 4.3) |
| `src/interfaces/ISVLaunchpad.sol` | the launchpad's structs, events, errors and functions: the frontend's ABI |
| `script/DeployLaunchpad.s.sol` | deploys the launchpad from environment variables and enables the quotes of `QUOTES_JSON` |
| `test/utils/LaunchMathHarness.sol`, `SVLaunchpadHarness.sol` | test doubles: the library as an external call; the launchpad with a back door for unreachable states |
| `test/mocks/RevertingPoolManager.sol` | a PoolManager that is down, for the stall valve |
```

(d) In `## Build, test, coverage, fork`, after the first paragraph add:

```markdown
One exception to the single optimizer setting: `SVLaunchpad` embeds `SVLaunchToken`'s init code for its CREATE2
deployment and does not fit EIP-170 at 1,000,000 runs (26,459 runtime bytes measured on 27 Sep 2026), so
`foundry.toml` compiles `src/SVLaunch*.sol` at 200 runs through a `compilation_restrictions` entry (20,522 bytes).
Every other file, `SVRouter` included, keeps 1,000,000 runs; the router's runtime size is unchanged (7,647
bytes) while its metadata hash moves with the remapping list, so the deployed router's exact verification input
stays in the untracked `docs/verify/`. The unit suites deploy a local `PoolManager`, which needs the
`solmate/=lib/v4-core/lib/solmate/` remapping; `forge build --sizes` lists it (19,766 bytes at 200 runs) and,
because restrictions propagate to importing files, a second `SVRouter.launchpad` row for the fork test that
imports both contracts.
```

(e) Environment variables table: add rows

```markdown
| `POOL_MANAGER` | launchpad deploy script | `0x8366a39CC670B4001A1121B8F6A443A643e40951`, the Uniswap v4 PoolManager |
| `FEE_BPS` | launchpad deploy script | the launch fee in basis points, at most 500; 200 at deploy |
| `CREATOR_FEE_SHARE_BPS` | launchpad deploy script | the creator's share of collected pool fees, at most 10000; 7000 at deploy |
| `QUOTES_JSON` | launchpad deploy script | the JSON text of the quote assets to enable (array of `{asset, symbol, decimals, minTarget, maxTarget}`, targets as raw-unit strings), from the frontend's `scripts/launchpad-quotes.mts` |
```

(f) In `## Deploy and verify`, append:

```markdown
### SVLaunchpad

```sh
QUOTES_JSON="$(cat ../SuitVenturesMarket-frontend/launchpad-quotes.json)" \
forge script script/DeployLaunchpad.s.sol --rpc-url robinhood --account <keystore name> --broadcast \
  --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api
```

The script refuses to run unless `block.chainid == 4663`, and unless `POOL_MANAGER` and `PERMIT2` are the chain's
constants (`ALLOW_OTHER_ADDRESSES=true` overrides); it checks every quote row (bounds, decimals, the presale
price in both currency orders at both bounds) before broadcasting, deploys, then calls `setQuote` once per row.

To verify an already deployed launchpad on Blockscout, and to keep the exact build for a manual verification:

```sh
forge verify-contract <address> src/SVLaunchpad.sol:SVLaunchpad --chain-id 4663 \
  --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api \
  --constructor-args "$(cast abi-encode 'constructor(address,address,address,address,uint16,uint16)' \
    "$POOL_MANAGER" "$PERMIT2" "$OWNER" "$FEE_WALLET" "$FEE_BPS" "$CREATOR_FEE_SHARE_BPS")"

forge verify-contract --show-standard-json-input <address> src/SVLaunchpad.sol:SVLaunchpad --chain-id 4663 \
  > docs/verify/SVLaunchpad.standard-input.json
cast abi-encode 'constructor(address,address,address,address,uint16,uint16)' \
  "$POOL_MANAGER" "$PERMIT2" "$OWNER" "$FEE_WALLET" "$FEE_BPS" "$CREATOR_FEE_SHARE_BPS" \
  > docs/verify/launchpad-constructor-args.hex
```

`docs/verify/` stays untracked, as for the router: it carries the real owner and fee wallet addresses.

Every launched token is a new `SVLaunchToken`, compiled inside the launchpad's 200-run job; verify one with:

```sh
forge verify-contract <token address> src/SVLaunchToken.sol:SVLaunchToken --chain-id 4663 \
  --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api --optimizer-runs 200 \
  --constructor-args "$(cast abi-encode 'constructor(string,string,uint256,address)' \
    "<name>" "<symbol>" 1000000000000000000000000000 "<launchpad address>")"
```
```

(g) Replace the stale line `**Not done on purpose:** no deployment, no Blockscout verification, no GitHub remote, no frontend wiring. All of that starts after your review.` with `**Not done on purpose:** no GitHub remote. The router is deployed (table above); the launchpad deploys after your review.`

- [ ] **Step 7: Gas snapshot and the final gates**

Run: `forge snapshot` (writes `.gas-snapshot`; the fork suites are skipped without the RPC and do not appear), then `forge fmt --check`, `forge build --sizes`, `forge lint`, `forge test`, `forge coverage --report summary`, and, with the RPC, `forge test --match-path 'test/fork/*' -vv` (both fork files).
Expected: all clean; coverage 100 % on the three `src` files; `script/DeployLaunchpad.s.sol` shows `parseQuotes` and `checkQuote` covered and `run` not (as the router's script, on purpose).

- [ ] **Step 8: Commit**

```bash
git add script/DeployLaunchpad.s.sol test/unit/DeployLaunchpad.t.sol .env.example README.md .gas-snapshot
git commit -m "Deploy script for SVLaunchpad with QUOTES_JSON, README and env docs, gas snapshot

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016tofArVnM9erCZUwPku467"
```

---

## After Kobe's review

Deploy from his EOA with the command in the README (the frontend produces `launchpad-quotes.json` first), record the address and block in the README's deployment table and in the workspace README's section 2, then the frontend plan's rollout steps (spec section 10): `NEXT_PUBLIC_SVLAUNCHPAD_ADDRESS`, the migration, the rehearsal raise.

## Self-Review

Run against the spec (section 4, as amended 27 Sep) after the plan was written.

**1. Spec coverage**

| Spec item | Task |
|---|---|
| 4 conventions: solc 0.8.26, cancun, no via_ir; `Ownable2Step` with `renounceOwnership` reverting; `ReentrancyGuard`; `SafeERC20`; events and errors in `ISVLaunchpad`; `<Thing>Changed` emitted at construction; bps over 10,000; single-token Permit2 overload; gate as a 100,000-gas static call; the `solmate/` remapping | Tasks 1 (remapping, interface), 2 (constructor, settings, gate), 3 (Permit2 overload); `nonReentrant` on every external state-changing function except `unlockCallback` (Tasks 2 to 6) |
| 4.1 `SVLaunchToken`: OZ `ERC20` + `ERC20Burnable`, constructor `(name, symbol, supply, recipient)`, whole supply to the launchpad, no owner/mint/pause, 18 decimals, CREATE2 with salt `keccak256(abi.encode(id, block.number, msg.sender))` in the launch transaction | Task 1 (token, tests), Task 4 (`_deployToken`, `_predictToken` in the tests asserts the salt) |
| 4.2 constructor `(poolManager, permit2, owner, feeWallet, feeBps, creatorFeeShareBps)` | Task 2 |
| 4.2 setters and bounds (`setFee` ≤ 500 `FeeTooHigh`, `setFeeWallet` non-zero, `setQuote` `max == 0` disables else `0 < min ≤ max`, `setLauncherGate` zero = open, `setCreatorFeeShare` ≤ 10000 applying to later raises, `setCreationOpen` pausing `create` only) with their events | Task 2 (tests for every bound); Task 5 (`setCreationOpen` does not block contribute, finalize, claim, refund) |
| 4.2 constants table | Task 2 (`test_the_constants_are_the_spec_values`) |
| 4.2 `Raise` storage, `contributed`, `claimed`, `nextId` from 1; pool key derived, `poolKey(id)` after launch | Tasks 1 (struct), 2 (storage), 4 (`poolKey`, `_poolKey`) |
| 4.2 Function signatures block, names verbatim, `quoteLimits`, `poolManager()`, `permit2()`, `CreateParams` order | Tasks 1 to 6 (each declares its functions), Global Constraints |
| 4.2 `create` steps 1 to 3 including `start == 0` means now, both price orders, text bounds, `RaiseCreated` + `RaiseMetadata` | Task 2 |
| 4.2 `contribute` steps 1 to 5: window, `PermitMismatch`, `take = min(...)`, `RaiseFull` / `WalletCapReached`, pull exactly `take`, `Contributed`, auto-launch | Task 3 (steps 1 to 4, `RaiseFull` through the harness), Task 4 (step 5) |
| 4.2 `finalize`: Open and (at target or past the deadline at or above the floor) | Task 4 (floor path; at-target path through the harness) |
| 4.2 `_finalize` steps 1 to 6: fee, CREATE2 token, price and `initialize`, `unlock` → `modifyLiquidity` with `getLiquidityForAmounts` and `sync`/`transfer`/`settle` per currency, burn `(saleTokens − soldTokens) + (poolTokens − tokensUsed)`, unused quote to the fee wallet, status/`launchedAt`/`liquidity`, `Finalized` | Task 4 |
| 4.2 `claim`, `claimCreator` (linear 90 days), `refund` (Closed, or Open past the deadline under the floor, or past deadline + 7 days; first call closes and emits `Closed`), `setPayout` | Task 5 |
| 4.2 `collectFees`: zero-delta poke, `take` both currencies, split by `creatorFeeShareBps` fixed at creation, `FeesCollected` | Task 6 |
| 4.2 `unlockCallback`: only the PoolManager, only with an unlock in flight (transient flag), data carries id and action | Task 4 (guards, mint), Task 6 (collect dispatch) |
| 4.2 guards: `nonReentrant`, no `receive`, no native currency, only enabled quotes | Tasks 2 to 6 |
| 4.2 events (16) and errors (26), exact field names, types, order and `indexed` flags | Task 1 (verbatim; topic hashes pinned by test) |
| 4.3 price formula, exact while `amount1 / amount0 < 2^64`, `create` rejects either order failing, liquidity with `getLiquidityForAmounts` at `sqrtAt(±887200)`, remainder burned / to the fee wallet, slot0 price and position liquidity asserted, claims with `mulDiv` summing to `soldTokens` within dust | Task 2 (`LaunchMath`, both-order tests), Task 4 (launch assertions), Task 7 (fuzz: amounts, claims) |
| 4.4 unit tests: `Deployers` PoolManager, real Permit2 etched, 6- and 18-decimal quotes, token on both sides; full lifecycle; floor path with `finalize` by a stranger; failure path; stall valve with a PoolManager that reverts; caps and reverts; admin bounds and gate variants; `setCreationOpen`; `renounceOwnership` | Tasks 2 to 6 |
| 4.4 fuzz (caps, held quote, claims within dust) and invariant (position liquidity never changes) | Task 7 |
| 4.4 fork: real PoolManager, USDG and one stock token, `ROBINHOOD_RPC_URL` skip, pinned block, real Permit2 signature, `finalize`, swap through the Universal Router, `collectFees`, the `Initialize` log with the expected pool id | Task 8 |
| 4.5 `script/DeployLaunchpad.s.sol` with `OWNER`, `FEE_WALLET`, `POOL_MANAGER`, `PERMIT2`, `FEE_BPS`, `CREATOR_FEE_SHARE_BPS`, `QUOTES_JSON`; `setQuote` per row; each minimum checked against the 4.3 bounds; Blockscout verification as the router's; README deployment table | Task 9 |

Gaps: none against section 4. Two things the spec leaves open were decided and flagged in the README (Task 9) and in the interface comments: a zero-contribution `refund` reverts `NothingToClaim`; `setQuote` refuses the zero asset with `ZeroAddress`. The per-file optimizer restriction is what spec 4.2 "Contract size" requires (Global Constraints, Task 2).

**2. Placeholder scan**

Searched the plan for "TBD", "TODO", "implement later", "fill in", "add validation", "handle edge cases", "similar to Task", "write tests for": none. Every code step carries the code; every run step names the command and the expected result; every commit step names the message. The two rows of the README deployment table that cannot be known before the broadcast say "not deployed yet" with the exact command that fills them. The fork block pin is a real block with the re-pin instruction.

**3. Type consistency**

- `ISVLaunchpad` names used across tasks: `create`, `contribute`, `finalize`, `claim`, `claimCreator`, `refund`, `collectFees`, `setPayout`, `setFee`, `setFeeWallet`, `setQuote`, `setLauncherGate`, `setCreatorFeeShare`, `setCreationOpen`, `getRaise`, `poolKey`, `quoteLimits`, `contributed`, `claimed`, `nextId`, `feeWallet`, `feeBps`, `creatorFeeShareBps`, `launcherGate`, `creationOpen`, `poolManager`, `permit2`: identical in the interface (Tasks 2 to 6), the contract, and every test (the constructor test reads `poolManager()` and `permit2()`; the settings test reads `quoteLimits`).
- Fixture helpers: `_fund`, `_contributorKey`, `_contributor`, `_now`, `_params`, `_create`, `_createWithFloor` (Task 2); `_contribute(uint256 privateKey, uint256 id, uint256 amount)`, `_fill(uint256 id)` (Task 3); `Launched`, `FinalizedData`, `_predictToken`, `_rollUntilTokenSide`, `_launched`, `_positionLiquidity`, `_slot0Price`, `_launch(MockERC20, uint256, bool) returns (uint256, Launched memory)` (Task 4); `_swap(uint256 id, bool zeroForOne, uint256 amountIn)` (Task 6): each later task calls them with these signatures.
- Contract privates: `_finalize`, `_deployToken`, `_emitFinalized`, `_unlock`, `_mintPosition`, `_settle` (Task 4), `_collectPosition`, `_take`, `_split` (Task 6), `_poolKey` (Task 4, used by Task 6), `_mayLaunch`, `_checkText`, `_emitMetadata`, `_nonZero` (Task 2); `CallbackData`, `Launch`, `ACTION_MINT`, `ACTION_COLLECT`, `UNLOCK_SLOT` (Task 4, used by Task 6).
- `LaunchMath.MIN_LAUNCH_SQRT_PRICE` (4310618292, the position's lower edge) is the library's lower bound, referenced by the `LaunchMath` tests and named in `_settle`'s reason for having no zero early-return; `DeployLaunchpad.checkQuote` returns `(uint160 minPrice, uint160 maxPrice)`, which its test asserts on.
- `LaunchMath.sqrtPriceX96For(uint256 amount0, uint256 amount1) returns (uint160)` is called with `(SALE_TOKENS, target)` for the token as currency0 and `(target, SALE_TOKENS)` for the quote as currency0 in Task 2 (`create`), Task 4 (`_finalize`), Task 9 (`checkQuote`), and the tests.
- Event decoding in tests uses `ISVLaunchpad.Finalized.selector` and `ISVLaunchpad.FeesCollected.selector` (Solidity 0.8.15+ event selectors), the same values Task 1 pins to `cast keccak` hashes.
- Harnesses: `SVLaunchpadHarness.exposed_setRaised(uint256 id, uint256 raised)` (Task 3) is what Task 4 uses; it needs `raises` to be `internal`, which Task 2 declares.
- Counts stated in run steps: Task 1 5, Task 2 7 + 27, Task 3 13, Task 4 11, Task 5 13, Task 6 7, Task 7 3 + 2, Task 8 3, Task 9 8.

**What was proven before writing (27 Sep 2026, scratch build with this repo's `lib/`, `foundry.toml` and `remappings.txt` plus the two changes above):** the contract and library code of Tasks 2 to 6 and the script of Task 9 compile with `forge build`, `forge fmt --check` and `forge lint` clean; a probe suite equivalent to the launch, claim, vesting, fee-split, floor, refund, stall-valve, both-order price, callback-guard, JSON-parsing, fuzz and invariant tests above passes (22 tests, 2 fuzz at 32 runs, 2 invariants at 8 runs); `forge coverage` builds under the compiler restriction; `SVLaunchpad` is 20,522 runtime bytes and `SVRouter` stays at 7,647. The admin, `create`, `contribute` and fork suites were written from the same fixture but not executed; expect at most small compile fixes there, never a change to the contract's behaviour.

**Fix round (review of 27 Sep, `contracts-plan-review.md`):** the stall-valve test now signs its tenth contribution inline so the Permit2 `DOMAIN_SEPARATOR()` read cannot consume the `expectRevert` (the probe's version placed the expectation directly before the call; the helper form printed earlier had not been executed); `LaunchMath`'s lower bound is the position's lower edge `4310618292` rather than `TickMath.MIN_SQRT_PRICE`, with a boundary test whose values were computed exactly (`(1e41, 296)` gives 4310478063 in the sliver, `(1e41, 297)` gives 4317753137 above it) and `_settle` documents why it has no zero early-return; the router wording says size unchanged and metadata hash changed, and the `--sizes` expectation lists the `PoolManager` and `SVRouter.launchpad` rows; the event count reads 16; every Solidity line fits 120 columns (calls wrapped, two test names shortened, `_feesCollected`'s header and condition split, the fork `SwapParams` literal one field per line) and `forge fmt` is named canonical in Global Constraints; the five banner suffixes are dropped by the tasks that fill them; `checkQuote` returns the two token-first prices and its test asserts on them; the interface's views follow the spec's block order with `poolKey` inserted between `quoteLimits` and `poolManager`; the stale "three wallets" remark is gone. The hardened bound and the reordered interface were re-read, not re-run.
