# Instant Launchpad Contracts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `SVLaunchToken` and `SVLaunchpad` in `SuitVenturesMarket-contracts` per the instant launchpad spec: one transaction deploys a fixed-supply token by CREATE2, initialises its hookless 1 % Uniswap v4 pool at the creator's snapped opening valuation, places the whole supply in one one-sided position the launchpad owns and can never decrease, and optionally buys the creator a first allocation through Permit2; trading fees are collected by anyone and split between the launch's payout address and the fee wallet, with a refused delivery credited for a later claim. Unit, fuzz, invariant and fork suites, a deploy script with its per-currency bounds config, and the README section come with it.

**Architecture:** One singleton `src/SVLaunchpad.sol` (OpenZeppelin v5.7 `Ownable2Step`, `ReentrancyGuard`, `SafeERC20`, `TransientSlot`, `Create2`, `Math`; Permit2's `ISignatureTransfer`; v4-core `IPoolManager`, `StateLibrary`, `TickMath`, `FullMath`, `Hooks`; v4-periphery `LiquidityAmounts`) talks to the PoolManager directly through `unlock` and its own `unlockCallback`. It deploys `src/SVLaunchToken.sol` (OpenZeppelin `ERC20` plus `ERC20Burnable`) with a salt that mixes in the caller. Every struct, event and error lives in `src/interfaces/ISVLaunchpad.sol`, which grows task by task until it equals spec section 4.2. Unit tests run offline on a `PoolManager` deployed inside the test, the real Permit2 etched at its canonical address, and v4-core's `PoolSwapTest` for trades; the fork suite runs against Robinhood Chain when `ROBINHOOD_RPC_URL` is set.

**Tech Stack:** Foundry (forge 1.4.0-nightly `6f49a622` on the build machine), Solidity 0.8.26 on Cancun, OpenZeppelin Contracts v5.7.0, Uniswap v4-core v4.0.0, v4-periphery `3231810e` (only `LiquidityAmounts` and interfaces), permit2 `cc56ad0f`, forge-std v1.9.7; the deployed SVRouter, Universal Router, V4 Quoter and StateView for the fork suite.

**Spec (binding):** `/Users/kobs/Desktop/SuitVenturesMarket/SuitVenturesMarket-frontend/docs/superpowers/specs/2026-09-28-instant-launchpad-design.md`. This plan implements sections 3, 4, 8.1 and 8.3 and serves 9, 11, 12 and 14; sections 5 to 7 and 8.2 belong to the frontend plan. Brief: `SuitVenturesMarket-frontend/.superpowers/sdd/2026-09-29-instant-launchpad/brief.md`. Where the plan had to settle something the spec leaves open, the task says so in a line starting **Settled here:**.

## Global Constraints

- Repo: `/Users/kobs/Desktop/SuitVenturesMarket/SuitVenturesMarket-contracts`, branch `main` at `22c114d`, no remote. Every path below is relative to it. The work lands on a branch `feat/instant-launchpad` created from `main`; each task runs in its own git worktree created from the tip of that branch after the previous task merged.
- A fresh worktree has empty submodules. Before the first build in a worktree run `git submodule update --init --recursive`; the nested `lib/v4-core/lib/solmate` tree is required by the `solmate/` remapping. `.env` is git-ignored and therefore absent from a worktree; nothing in Tasks 1 to 4 and 6 needs it.
- Spec section 4 conventions, verbatim: "`pragma solidity 0.8.26;`, named imports, `Ownable2Step` with `renounceOwnership` reverting `RenounceDisabled`, OpenZeppelin `ReentrancyGuard` and `SafeERC20`, every error and event declared in the interface, setter events named `<Thing>Changed` and emitted once by the constructor with the initial value, bps over 10,000, `// ----` section banners, `@inheritdoc` plus a `@dev` that says why, no `via_ir`. The one build change is the remapping `solmate/=lib/v4-core/lib/solmate/`."
- Spec section 4.2 is the external surface, verbatim: struct, event, error and function names, types and parameter order are copied from it and from nowhere else. The PositionManager is not used.
- Spec section 4.3 constants, verbatim:

  | Name | Value |
  |---|---|
  | `SUPPLY` | `1_000_000_000e18` |
  | `POOL_FEE` | `10_000`, 1 % static LP fee |
  | `TICK_SPACING` | `200` |
  | `MIN_USABLE_TICK`, `MAX_USABLE_TICK` | `−887_200`, `887_200` |
  | `MAX_ROUTER_FEE_BPS` | `50`, 0.5 % |
  | `MIN_VALUATION`, `MAX_VALUATION` | `1e8`, `1e36` raw quote units (maximum amended from `1e41` on 29 Sep 2026) |
  | `MAX_NAME_BYTES`, `MAX_SYMBOL_BYTES`, `MAX_URI_BYTES` | `32`, `11`, `128` |
  | `GATE_CHECK_GAS` | `100_000`, as SVRouter's `HOLDER_CHECK_GAS` |

- The eleven constants above are `internal` in `SVLaunchpad` and not part of `ISVLaunchpad`, to keep bytecode margin; tests prove their values through behaviour, never through getters. `GATE_CHECK_GAS` stays private.
- Spec section 4.3 initial settings: router fee 50, creator share 7,000, first-buy cap 2,000, daily limit 5, launcher gate from the constructor, hook zero, no currency until the deploy script adds them.
- Repo conventions (research notes `contracts-repo.md` section 2): OpenZeppelin imports first, then v4-core, v4-periphery, permit2, then local; constants and immutables `UPPER_SNAKE`, storage `camelCase`, private helpers `_camelCase`, constructor parameters with a trailing underscore; lint suppressions justified one line above as `// forge-lint: disable-next-line(<rule>)`; `abi.encodeCall` for every selector in `src/`; a zero amount is never transferred.
- Command, action and selector constants come from the installed libraries (`IERC20.transfer`, `IERC721.balanceOf`, `IPoolManager.Initialize.selector`, `Hooks.*_FLAG`), never hand-written, and `src/` never hand-writes a selector. **Settled here:** the tests' `PERMIT_PULL` selector is the keccak of Permit2's signature string, copied from `test/unit/SVRouter.t.sol:60-61`, because `permitTransferFrom` is overloaded and has no unambiguous `.selector`.
- `via_ir` stays `false`. A stack-too-deep error, including one that appears only under `forge coverage`, is fixed by moving locals into a memory struct or splitting a function, never by `via_ir` or `--ir-minimum`.
- After any edit to compiler keys in `foundry.toml` (`additional_compiler_profiles`, `compilation_restrictions`, a profile section), run `forge clean` before the next build.
- `fs_permissions` stays `[]` until Task 6, which adds exactly `{ access = "read", path = "./script/config" }`.
- No private key, RPC key or real wallet address in the repo. Tests use `vm.addr` keys and `makeAddr`; `.env.example` carries placeholders and public chain facts only; `.env` is never read, printed or committed.
- `forge fmt` is canonical: after writing any `.sol` file run `forge fmt` on it; where the formatter's line breaks differ from this plan's, the formatter wins.
- Gates after every task, in this order, all green before the commit:
  1. `forge fmt --check`
  2. `forge build --sizes --skip test --skip script` (`SVRouter` still 7,647 bytes; from Task 3 on, `SVLaunchpad` at most 24,320 bytes, that is at least 256 bytes under the 24,576-byte limit, else stop and report to the controller). The skips keep the PoolManager the tests import, 26,988 bytes, out of the size check.
  3. `forge test --no-match-path 'test/fork/*'` (the unit suite, which includes fuzz and invariant tests; the SVRouter suites still pass)
  4. `FOUNDRY_PROFILE=coverage forge coverage --report summary --no-match-path 'test/fork/*'`: every file under `src/` at 100.00 % lines, statements, branches and functions from the unit suite alone. The `coverage` profile, added in Task 3 Step 7, clears the per-file compiler restriction, which coverage builds cannot combine; in Tasks 1 and 2, before it exists, run the same command without the `FOUNDRY_PROFILE=coverage` prefix.
  5. `ROBINHOOD_RPC_URL= forge test --match-path 'test/fork/*'`: both fork contracts report skipped, never failed
  6. Task 5 only: `ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-path 'test/fork/SVLaunchpadFork.t.sol' -vv` passes
- Commit after every task, message exactly as the task gives it, ending with these two lines:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_016RxWfZk26aLfhGaoXcrYLf
  ```
- Model routing: implementers Opus; test and coverage runners, which execute and report and never edit, Sonnet; reviewers Opus, including a drift check of each task against spec sections 3 and 4.
- Kobe reads the README section written in Task 6: plain words, no em-dashes, no parenthetical asides, numbers in tables.

## Review Focus

The five inputs the spec implies that are most likely to bite a real user, each pinned by a test in the task that owns the code:

1. **Settings changed after a launch.** The owner disables the launch's currency, lowers the creator share and the router fee, closes launches and moves the fee wallet. A person expects the existing launch to keep collecting, the payout to keep the share fixed at launch, and only the platform share to follow the new fee wallet. Test: `test_settings_changed_after_a_launch_touch_it_only_through_the_fee_wallet` in Task 4.
2. **A sell before anyone has bought.** Below the opening price there is no liquidity. A person expects the seller to pay nothing and receive nothing, nothing to become collectable, and the next buyer to pay exactly what they would have paid without the sell. Test: `test_a_sell_before_the_first_buy_costs_nothing_leaves_nothing_to_collect_and_changes_no_price` in Task 4.
3. **A first buy of one raw unit.** The router fee rounds to zero and the pool's 1 % fee swallows the unit. A person expects the launch to succeed with zero tokens bought and no zero-value transfer to the fee wallet. Test: `test_a_one_unit_first_buy_launches_buys_nothing_and_sends_no_fee` in Task 3.
4. **Launches exactly at a currency's bounds and at `MAX_VALUATION`.** A person expects the minimum and the maximum themselves to be accepted, and at the top of the range, where the pool takes the whole supply, nothing to be burned and no burn call to be made. Test: `test_launches_at_the_bounds_and_at_MAX_VALUATION_where_nothing_is_burned` in Task 3.
5. **One payout address earning from two launches in the same currency while the currency refuses it.** A person expects both launches' shares to add up in one owed balance and one claim to pay it all. Test: `test_owed_shares_from_two_launches_in_one_currency_add_up_and_one_claim_pays_both` in Task 4.

## File structure

| Path | Task | Responsibility |
|---|---|---|
| `remappings.txt` | 1 | + `solmate/=lib/v4-core/lib/solmate/` |
| `src/SVLaunchToken.sol` | 1 | OZ `ERC20` + `ERC20Burnable`, whole supply minted once to the launchpad |
| `src/interfaces/ISVLaunchpad.sol` | 1 to 4 | structs, events, errors (Task 1); settings and pure views (Task 2); `launch`, `unlockCallback`, launch views (Task 3); fees, claims, payout (Task 4) |
| `src/SVLaunchpad.sol` | 2 to 4 | constants, storage, constructor, settings, gate, opening maths (Task 2); `launch` and the launch callback (Task 3); `collectFees`, `claim`, `setPayout`, `uncollectedFees` (Task 4) |
| `foundry.toml` | 3, 6 | the mandatory low-run profile for `src/SVLaunch*.sol` and `[profile.coverage]` (Task 3); `fs_permissions` read of `./script/config` (Task 6) |
| `test/mocks/MockQuirkyERC20.sol` | 1 | quote double: refuses chosen recipients by revert or `false`, can answer `transfer` with no data, can burn a transfer fee on every transfer or only on transfers to one address |
| `test/mocks/MockRevertingGate.sol`, `test/mocks/MockGasBurningGate.sol` | 1 | launcher gates that revert and that burn their gas allowance |
| `test/mocks/MockChainlinkAggregator.sol` | 6 | settable `latestRoundData` and `decimals` for the deploy script's tests |
| `test/unit/SVLaunchToken.t.sol` | 1 | the token, the event and error ABI against the spec's signatures, the local PoolManager |
| `test/unit/LaunchMocks.t.sol` | 1 | the doubles behave as the later suites rely on |
| `test/unit/SVLaunchpad.t.sol` | 2, 3, 4 | the abstract fixture `SVLaunchpadTestBase` (grows in Tasks 3 and 4) and `SVLaunchpadSettingsTest` |
| `test/unit/SVLaunchpad.launch.t.sol` | 3 | `launch` in both currency orders and both decimals, every revert at its step, the daily limit, the callback guards |
| `test/unit/SVLaunchpad.fees.t.sol` | 4 | collection, split, delivery and credit, claims, payout, measured amounts, storage layout |
| `test/unit/SVLaunchpad.invariant.t.sol` | 4 | the balance-equals-owed and locked-liquidity invariants over random call sequences |
| `test/unit/SVLaunchpadAbi.t.sol` | 4 | every function selector of `ISVLaunchpad` against the spec's signature |
| `test/unit/SVLaunchpad.fuzz.t.sol` | 5 | valuation, dust, first-buy curve and fee-split fuzzing |
| `test/fork/SVLaunchpadFork.t.sol` | 5 | USDG and NVDA launches on the real PoolManager and Permit2, trades through the deployed SVRouter and Universal Router, Quoter and StateView cross-checks |
| `script/DeployLaunchpad.s.sol` | 6 | chain and address guards, config parsing, USD to raw bounds, ownership sequence, printout |
| `script/config/launch-currencies.example.json` | 6 | the canonical config schema, one row of each price source; the real file comes from the frontend generator |
| `test/unit/DeployLaunchpad.t.sol` | 6 | the script's parsing, pricing and conversion |
| `README.md`, `.env.example` | 6 | the SVLaunchpad section, env names |

## Task order and dependencies

Strictly sequential: each task starts from the previous task's commit.

| Task | Depends on | Deliverable |
|---|---|---|
| 1 Scaffold: remapping, token, interface types, mocks | none | token and ABI pinned, local PoolManager builds |
| 2 Settings, gate, currency config, opening maths | 1 | `SVLaunchpad` deployable with every owner setting and the price views |
| 3 `launch` | 2 | a launch in both currency orders with the first buy, every revert |
| 4 Fees, claims, payout, invariants | 3 | the complete contract; interface equals spec 4.2 |
| 5 Fuzz and fork suites | 4 | spec 8.1 fuzz and fork proofs |
| 6 Deploy script, config, README | 4 (5 for the README's fork facts) | the deploy path Kobe runs |

---

### Task 1: Scaffold: the `solmate` remapping, `SVLaunchToken`, the interface's types, events and errors, the test doubles

**Files:**
- Modify: `remappings.txt` (append one line)
- Create: `src/SVLaunchToken.sol`
- Create: `src/interfaces/ISVLaunchpad.sol`
- Create: `test/mocks/MockQuirkyERC20.sol`, `test/mocks/MockRevertingGate.sol`, `test/mocks/MockGasBurningGate.sol`
- Test: `test/unit/SVLaunchToken.t.sol`, `test/unit/LaunchMocks.t.sol`

**Interfaces:**
- Consumes: OZ `ERC20(string name_, string symbol_)`, `ERC20Burnable.burn(uint256)`, `ERC20._update(address,address,uint256)`; v4-core `PoolManager(address initialOwner)` (needs `solmate/src/auth/Owned.sol`, hence the remapping), `PoolSwapTest(IPoolManager)`; the existing `test/mocks/MockERC721ShortReply.sol`.
- Produces:
  - `contract SVLaunchToken is ERC20, ERC20Burnable` with `uint256 public constant SUPPLY = 1_000_000_000e18` and `constructor(string memory name_, string memory symbol_, address recipient)`.
  - `interface ISVLaunchpad` with `struct LaunchParams {string name; string symbol; string metadataUri; address quote; uint256 valuation; uint256 firstBuy; uint256 minFirstBuyTokens; address payout; bytes32 salt; uint256 deadline;}`, `struct Launch {address creator; uint64 launchedAt; uint16 creatorShareBps; bool tokenIsCurrency0; address payout; int24 openTick; address quote; address hook; uint128 liquidity;}`, `struct CurrencyConfig {uint256 minValuation; uint256 maxValuation; uint256 creationFee;}`, `struct LaunchedData {bytes32 poolId; address payout; address hook; bool tokenIsCurrency0; int24 openTick; uint256 openingValuation; uint128 liquidity; uint256 tokensInPool; uint256 firstBuyIn; uint256 firstBuyTokens; uint256 routerFee; uint256 creationFee; uint16 creatorShareBps; string name; string symbol; string metadataUri;}`, `struct PendingFees {uint256 tokenFees; uint256 quoteFees; uint256 tokenToPayout; uint256 quoteToPayout; uint256 tokenToFeeWallet; uint256 quoteToFeeWallet;}`, the 11 events and 24 errors of spec 4.2. No functions yet; Tasks 2 to 4 append them.
  - `contract MockQuirkyERC20 is ERC20` with `enum Refusal {None, Revert, ReturnFalse}`, `error Refused(address to)`, `constructor(string name_, string symbol_, uint8 decimals_)`, `mint(address to, uint256 amount)`, `setRefusal(address to, Refusal mode)`, `setNoReturnData(bool on)`, `setTransferFee(uint16 bps, address onlyTo)` (`onlyTo == address(0)` taxes every transfer), public getters `refusal(address)`, `noReturnData()`, `feeBps()`, `feeOnlyTo()`.
  - `contract MockRevertingGate` with `error GateIsUnwell()` and `balanceOf(address) returns (uint256)` that always reverts; `contract MockGasBurningGate` whose `balanceOf(address)` hashes until its gas is gone.

- [ ] **Step 1: Branch and add the remapping**

```bash
git checkout -b feat/instant-launchpad
```

Append one line to `remappings.txt` so it reads:

```
forge-std/=lib/forge-std/src/
@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/
@uniswap/v4-core/=lib/v4-core/
@uniswap/v4-periphery/=lib/v4-periphery/
@uniswap/universal-router/=lib/universal-router/
permit2/=lib/permit2/
solmate/=lib/v4-core/lib/solmate/
```

- [ ] **Step 2: Write the failing token and ABI tests**

`test/unit/SVLaunchToken.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SVLaunchToken} from "../../src/SVLaunchToken.sol";
import {ISVLaunchpad} from "../../src/interfaces/ISVLaunchpad.sol";

/// @notice The launch token (spec section 4.1), the event and error ABI of spec section 4.2 against its canonical
///         signatures, and the `solmate/` remapping that lets the unit suites deploy a local PoolManager.
contract SVLaunchTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    address internal recipient;

    function setUp() public {
        recipient = makeAddr("launchpad");
    }

    function test_constructor_mints_the_whole_supply_once_to_the_recipient_with_18_decimals() public {
        SVLaunchToken token = new SVLaunchToken("Launch Token", "LT", recipient);
        assertEq(token.name(), "Launch Token", "name");
        assertEq(token.symbol(), "LT", "symbol");
        assertEq(token.decimals(), 18, "18 decimals");
        assertEq(token.SUPPLY(), SUPPLY, "SUPPLY is one billion tokens");
        assertEq(token.totalSupply(), SUPPLY, "the whole supply exists");
        assertEq(token.balanceOf(recipient), SUPPLY, "and the recipient holds all of it");
    }

    function test_burn_reduces_the_supply_and_the_holder_balance() public {
        SVLaunchToken token = new SVLaunchToken("Launch Token", "LT", recipient);
        vm.prank(recipient);
        token.burn(1e18);
        assertEq(token.totalSupply(), SUPPLY - 1e18, "supply after the burn");
        assertEq(token.balanceOf(recipient), SUPPLY - 1e18, "balance after the burn");
    }

    /// @dev No owner, no mint, no pause: a call to any such selector finds no function and no fallback.
    function test_the_token_has_no_mint_owner_or_pause_entry_point() public {
        SVLaunchToken token = new SVLaunchToken("Launch Token", "LT", recipient);
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
    function test_a_local_pool_manager_and_the_core_swap_router_deploy() public {
        IPoolManager manager = IPoolManager(address(new PoolManager(address(this))));
        PoolSwapTest router = new PoolSwapTest(manager);
        assertGt(address(manager).code.length, 0, "the PoolManager compiled and deployed");
        assertGt(address(router).code.length, 0, "the core's swap test router deployed");
    }

    /// @dev The three activity events the reader indexes; the frontend pins the same three topic0 values.
    function test_the_activity_event_topics_match_the_spec_signatures() public pure {
        assertEq(
            ISVLaunchpad.Launched.selector,
            keccak256(
                "Launched(address,address,address,(bytes32,address,address,bool,int24,uint256,uint128,uint256,uint256,uint256,uint256,uint256,uint16,string,string,string))"
            ),
            "Launched"
        );
        assertEq(
            ISVLaunchpad.FeesCollected.selector,
            keccak256("FeesCollected(address,address,uint256,uint256,uint256,uint256)"),
            "FeesCollected"
        );
        assertEq(
            ISVLaunchpad.PayoutChanged.selector, keccak256("PayoutChanged(address,address,address)"), "PayoutChanged"
        );
    }

    function test_the_setting_event_topics_match_the_spec_signatures() public pure {
        assertEq(ISVLaunchpad.FeeWalletChanged.selector, keccak256("FeeWalletChanged(address)"), "FeeWalletChanged");
        assertEq(ISVLaunchpad.RouterFeeChanged.selector, keccak256("RouterFeeChanged(uint16)"), "RouterFeeChanged");
        assertEq(
            ISVLaunchpad.CreatorShareChanged.selector, keccak256("CreatorShareChanged(uint16)"), "CreatorShareChanged"
        );
        assertEq(
            ISVLaunchpad.FirstBuyCapChanged.selector, keccak256("FirstBuyCapChanged(uint16)"), "FirstBuyCapChanged"
        );
        assertEq(
            ISVLaunchpad.DailyLaunchLimitChanged.selector,
            keccak256("DailyLaunchLimitChanged(uint8)"),
            "DailyLaunchLimitChanged"
        );
        assertEq(
            ISVLaunchpad.LauncherGateChanged.selector, keccak256("LauncherGateChanged(address)"), "LauncherGateChanged"
        );
        assertEq(ISVLaunchpad.HookChanged.selector, keccak256("HookChanged(address)"), "HookChanged");
        assertEq(
            ISVLaunchpad.CurrencyChanged.selector,
            keccak256("CurrencyChanged(address,uint256,uint256,uint256)"),
            "CurrencyChanged"
        );
    }

    /// @dev The frontend decodes reverts by name from its own ABI; a wrong parameter list here would change the
    ///      selector it sees.
    function test_the_error_selectors_match_the_spec_signatures() public pure {
        assertEq(ISVLaunchpad.ZeroAddress.selector, bytes4(keccak256("ZeroAddress()")), "ZeroAddress");
        assertEq(ISVLaunchpad.RenounceDisabled.selector, bytes4(keccak256("RenounceDisabled()")), "RenounceDisabled");
        assertEq(ISVLaunchpad.Expired.selector, bytes4(keccak256("Expired()")), "Expired");
        assertEq(
            ISVLaunchpad.NotAllowedToLaunch.selector, bytes4(keccak256("NotAllowedToLaunch()")), "NotAllowedToLaunch"
        );
        assertEq(
            ISVLaunchpad.DailyLimitReached.selector, bytes4(keccak256("DailyLimitReached()")), "DailyLimitReached"
        );
        assertEq(ISVLaunchpad.BadName.selector, bytes4(keccak256("BadName()")), "BadName");
        assertEq(ISVLaunchpad.BadSymbol.selector, bytes4(keccak256("BadSymbol()")), "BadSymbol");
        assertEq(ISVLaunchpad.UriTooLong.selector, bytes4(keccak256("UriTooLong()")), "UriTooLong");
        assertEq(
            ISVLaunchpad.CurrencyNotAllowed.selector, bytes4(keccak256("CurrencyNotAllowed()")), "CurrencyNotAllowed"
        );
        assertEq(
            ISVLaunchpad.ValuationOutOfRange.selector,
            bytes4(keccak256("ValuationOutOfRange(uint256,uint256,uint256)")),
            "ValuationOutOfRange"
        );
        assertEq(ISVLaunchpad.PermitMismatch.selector, bytes4(keccak256("PermitMismatch()")), "PermitMismatch");
        assertEq(
            ISVLaunchpad.FirstBuyTooLarge.selector,
            bytes4(keccak256("FirstBuyTooLarge(uint256,uint256)")),
            "FirstBuyTooLarge"
        );
        assertEq(
            ISVLaunchpad.FirstBuyTooSmall.selector,
            bytes4(keccak256("FirstBuyTooSmall(uint256,uint256)")),
            "FirstBuyTooSmall"
        );
        assertEq(ISVLaunchpad.BadPayout.selector, bytes4(keccak256("BadPayout()")), "BadPayout");
        assertEq(ISVLaunchpad.FeeTooHigh.selector, bytes4(keccak256("FeeTooHigh()")), "FeeTooHigh");
        assertEq(ISVLaunchpad.BpsTooHigh.selector, bytes4(keccak256("BpsTooHigh()")), "BpsTooHigh");
        assertEq(ISVLaunchpad.BoundsOutOfRange.selector, bytes4(keccak256("BoundsOutOfRange()")), "BoundsOutOfRange");
        assertEq(ISVLaunchpad.HookNotAllowed.selector, bytes4(keccak256("HookNotAllowed()")), "HookNotAllowed");
        assertEq(ISVLaunchpad.UnknownLaunch.selector, bytes4(keccak256("UnknownLaunch()")), "UnknownLaunch");
        assertEq(ISVLaunchpad.NotPayout.selector, bytes4(keccak256("NotPayout()")), "NotPayout");
        assertEq(ISVLaunchpad.NothingToCollect.selector, bytes4(keccak256("NothingToCollect()")), "NothingToCollect");
        assertEq(ISVLaunchpad.NothingOwed.selector, bytes4(keccak256("NothingOwed()")), "NothingOwed");
        assertEq(ISVLaunchpad.NotPoolManager.selector, bytes4(keccak256("NotPoolManager()")), "NotPoolManager");
        assertEq(
            ISVLaunchpad.UnexpectedCallback.selector, bytes4(keccak256("UnexpectedCallback()")), "UnexpectedCallback"
        );
    }
}
```

- [ ] **Step 3: Write the failing tests of the doubles**

`test/unit/LaunchMocks.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {MockQuirkyERC20} from "../mocks/MockQuirkyERC20.sol";
import {MockRevertingGate} from "../mocks/MockRevertingGate.sol";
import {MockGasBurningGate} from "../mocks/MockGasBurningGate.sol";

/// @notice The test doubles do exactly what the launchpad suites rely on; a double that silently does something
///         else would make a passing launchpad test prove nothing.
contract LaunchMocksTest is Test {
    MockQuirkyERC20 internal quirky;
    address internal alice;
    address internal bob;

    function setUp() public {
        quirky = new MockQuirkyERC20("Quirky USD", "QUSD", 6);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        quirky.mint(address(this), 1_000_000);
    }

    function test_a_plain_transfer_moves_the_amount_and_returns_true() public {
        assertTrue(quirky.transfer(bob, 10_000), "returns true");
        assertEq(quirky.balanceOf(bob), 10_000, "bob received the amount");
        assertEq(quirky.decimals(), 6, "decimals as constructed");
    }

    function test_a_revert_refusal_reverts_with_Refused() public {
        quirky.setRefusal(bob, MockQuirkyERC20.Refusal.Revert);
        vm.expectRevert(abi.encodeWithSelector(MockQuirkyERC20.Refused.selector, bob));
        quirky.transfer(bob, 1);
    }

    function test_a_false_refusal_returns_false_and_moves_nothing() public {
        quirky.setRefusal(bob, MockQuirkyERC20.Refusal.ReturnFalse);
        (bool ok, bytes memory reply) = address(quirky).call(abi.encodeCall(quirky.transfer, (bob, 1)));
        assertTrue(ok, "the call itself succeeds");
        assertEq(reply, abi.encode(false), "and answers false");
        assertEq(quirky.balanceOf(bob), 0, "nothing moved");
    }

    function test_no_return_data_moves_the_amount_and_answers_nothing() public {
        quirky.setNoReturnData(true);
        (bool ok, bytes memory reply) = address(quirky).call(abi.encodeCall(quirky.transfer, (bob, 7)));
        assertTrue(ok, "the call succeeds");
        assertEq(reply.length, 0, "with no return data");
        assertEq(quirky.balanceOf(bob), 7, "and the amount moved");
    }

    function test_a_transfer_fee_on_every_transfer_burns_its_share() public {
        quirky.setTransferFee(100, address(0));
        quirky.transfer(bob, 10_000);
        assertEq(quirky.balanceOf(bob), 9_900, "1 % burned on the way");
        assertEq(quirky.totalSupply(), 1_000_000 - 100, "the fee left the supply");
    }

    function test_a_transfer_fee_limited_to_one_recipient_spares_everyone_else() public {
        quirky.setTransferFee(100, bob);
        quirky.transfer(alice, 10_000);
        quirky.transfer(bob, 10_000);
        assertEq(quirky.balanceOf(alice), 10_000, "alice is not taxed");
        assertEq(quirky.balanceOf(bob), 9_900, "bob is");
    }

    /// @dev Permit2 and the PoolManager's test router pull with `transferFrom`; a refusal is about `transfer` only.
    function test_transferFrom_ignores_refusals() public {
        quirky.setRefusal(bob, MockQuirkyERC20.Refusal.Revert);
        quirky.approve(alice, 5);
        vm.prank(alice);
        quirky.transferFrom(address(this), bob, 5);
        assertEq(quirky.balanceOf(bob), 5, "transferFrom delivered to a refused address");
    }

    function test_the_reverting_gate_reverts_and_the_gas_burning_gate_runs_out_of_gas() public {
        MockRevertingGate reverting = new MockRevertingGate();
        MockGasBurningGate burning = new MockGasBurningGate();
        vm.expectRevert(MockRevertingGate.GateIsUnwell.selector);
        reverting.balanceOf(alice);
        (bool ok,) = address(burning).staticcall{gas: 100_000}(abi.encodeCall(IERC721.balanceOf, (alice)));
        assertFalse(ok, "the gas-burning gate never answers within 100,000 gas");
    }
}
```

- [ ] **Step 4: Run both files to verify they fail**

Run: `forge test --match-path 'test/unit/SVLaunchToken.t.sol'` and `forge test --match-path 'test/unit/LaunchMocks.t.sol'`
Expected: compilation fails with `Source "../../src/SVLaunchToken.sol" not found` and `Source "../mocks/MockQuirkyERC20.sol" not found`.

- [ ] **Step 5: Write the token**

`src/SVLaunchToken.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @title SVLaunchToken
/// @notice The token a MaxLong Markets launch creates: a plain OpenZeppelin ERC20 with `burn`, 18 decimals, one
///         billion tokens minted once to the launchpad. No owner, no mint after construction, no pause, no
///         blocklist, no transfer fee, no hooks.
/// @dev Spec: docs/superpowers/specs/2026-09-28-instant-launchpad-design.md (frontend repo), section 4.1. Deployed
///      only by SVLaunchpad with CREATE2 inside the launch transaction; the launchpad burns the dust the pool did
///      not take, so it ends the launch holding none of it.
contract SVLaunchToken is ERC20, ERC20Burnable {
    /// @notice The whole supply, minted once in the constructor.
    uint256 public constant SUPPLY = 1_000_000_000e18;

    /// @notice Mints the whole supply to `recipient`, always the launchpad. 18 decimals, no owner, no mint after this.
    /// @param name_ The token name the creator chose.
    /// @param symbol_ The token symbol the creator chose.
    /// @param recipient The launchpad.
    constructor(string memory name_, string memory symbol_, address recipient) ERC20(name_, symbol_) {
        _mint(recipient, SUPPLY);
    }
}
```

- [ ] **Step 6: Write the interface's types, events and errors**

`src/interfaces/ISVLaunchpad.sol` (Tasks 2 to 4 append the functions inside the interface, after the errors):

```solidity
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
}
```

- [ ] **Step 7: Write the doubles**

`test/mocks/MockQuirkyERC20.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice A quote currency with the behaviours the launchpad must survive, each off until switched on: refusing
///         chosen recipients of `transfer` by reverting or by answering `false`, answering `transfer` with no
///         return data, and burning a transfer fee on every transfer or only on transfers to one address.
///         `transferFrom` never refuses, so Permit2 and the PoolManager's test router can still pull. Unit tests only.
contract MockQuirkyERC20 is ERC20 {
    /// @notice How `transfer` treats one recipient.
    enum Refusal {
        None,
        Revert,
        ReturnFalse
    }

    /// @notice `transfer` to `to` is refused by revert.
    error Refused(address to);

    uint8 private immutable DECIMALS;
    mapping(address => Refusal) public refusal;
    bool public noReturnData;
    uint16 public feeBps;
    address public feeOnlyTo;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        DECIMALS = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return DECIMALS;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setRefusal(address to, Refusal mode) external {
        refusal[to] = mode;
    }

    function setNoReturnData(bool on) external {
        noReturnData = on;
    }

    /// @param bps The share of every taxed transfer that is burned.
    /// @param onlyTo Tax only transfers to this address; zero taxes every transfer.
    function setTransferFee(uint16 bps, address onlyTo) external {
        feeBps = bps;
        feeOnlyTo = onlyTo;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        Refusal mode = refusal[to];
        if (mode == Refusal.Revert) revert Refused(to);
        if (mode == Refusal.ReturnFalse) return false;
        _transfer(msg.sender, to, value);
        if (noReturnData) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return true;
    }

    /// @dev The fee is burned from the amount sent: the sender is debited `value`, the recipient credited the rest.
    function _update(address from, address to, uint256 value) internal override {
        bool taxed = feeBps != 0 && from != address(0) && to != address(0)
            && (feeOnlyTo == address(0) || to == feeOnlyTo);
        if (!taxed) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = value * feeBps / 10_000;
        super._update(from, address(0), fee);
        super._update(from, to, value - fee);
    }
}
```

`test/mocks/MockRevertingGate.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice A launcher gate whose `balanceOf` reverts. The launchpad must read it as "not allowed", never bubble
///         the revert. Unit tests only.
contract MockRevertingGate {
    error GateIsUnwell();

    function balanceOf(address) external pure returns (uint256) {
        revert GateIsUnwell();
    }
}
```

`test/mocks/MockGasBurningGate.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice A launcher gate whose `balanceOf` never answers: it hashes until the call's gas allowance is gone. The
///         launchpad's 100,000 gas cap must turn it into "not allowed". Unit tests only.
contract MockGasBurningGate {
    function balanceOf(address) external view returns (uint256 total) {
        total = uint256(blockhash(block.number - 1));
        while (gasleft() > 0) {
            total = uint256(keccak256(abi.encode(total)));
        }
    }
}
```

- [ ] **Step 8: Run both files to verify they pass**

Run: `forge fmt && forge test --match-path 'test/unit/SVLaunchToken.t.sol' -vv` then `forge test --match-path 'test/unit/LaunchMocks.t.sol' -vv`
Expected: `7 passed, 0 failed` and `8 passed, 0 failed`.

- [ ] **Step 9: Gates**

Run gates 1 to 5 of Global Constraints. Expected: fmt clean; `forge build --sizes --skip test --skip script` lists `SVLaunchToken` and `SVRouter` at 7,647 bytes; `forge test --no-match-path 'test/fork/*'` passes the 59 SVRouter tests plus these 15; coverage shows `src/SVLaunchToken.sol` at 100.00 % on all four columns and `src/SVRouter.sol` unchanged at 100.00 %; the fork suite reports skipped.

- [ ] **Step 10: Commit**

```bash
git add remappings.txt src/SVLaunchToken.sol src/interfaces/ISVLaunchpad.sol test/mocks/MockQuirkyERC20.sol test/mocks/MockRevertingGate.sol test/mocks/MockGasBurningGate.sol test/unit/SVLaunchToken.t.sol test/unit/LaunchMocks.t.sol
git commit -m "Launchpad scaffold: SVLaunchToken, ISVLaunchpad types, events and errors, the test doubles, the solmate remapping

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016RxWfZk26aLfhGaoXcrYLf"
```

---

### Task 2: `SVLaunchpad` skeleton: constants, storage, constructor, every owner setting, the launcher gate, `predictToken`, `openingFor`; the shared fixture

**Files:**
- Create: `src/SVLaunchpad.sol`
- Modify: `src/interfaces/ISVLaunchpad.sol` (append the functions of this task after the errors)
- Test: `test/unit/SVLaunchpad.t.sol` (the abstract fixture `SVLaunchpadTestBase` and the suite `SVLaunchpadSettingsTest`)

**Interfaces:**
- Consumes: Task 1's `ISVLaunchpad` types, events, errors and `SVLaunchToken`; OZ `Ownable(address)`, `Ownable2Step`, `ReentrancyGuard`, `Create2.computeAddress(bytes32 salt, bytes32 bytecodeHash) returns (address)`, `Math.sqrt(uint256)`, `Math.sqrt(uint256, Math.Rounding)`, `IERC721.balanceOf`; v4-core `TickMath.getTickAtSqrtPrice(uint160) returns (int24)`, `TickMath.getSqrtPriceAtTick(int24) returns (uint160)`, `FullMath.mulDiv`, `FullMath.mulDivRoundingUp`, `Hooks.isValidHookAddress(IHooks, uint24)`, `Hooks.hasPermission(IHooks, uint160)`, `Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG`, `Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG`, `Hooks.ALL_HOOK_MASK`; test side `DeployPermit2().deployPermit2() returns (address)`, `MockERC20(name, symbol, decimals)` with `mint`, `MockERC721` with `mint(to, id)`, `MockERC721ShortReply`, Task 1's gates.
- Produces:
  - `contract SVLaunchpad is ISVLaunchpad, Ownable2Step, ReentrancyGuard` with `constructor(IPoolManager poolManager_, ISignatureTransfer permit2_, address owner_, address feeWallet_, address launcherGate_)`; internal constants `SUPPLY, POOL_FEE, TICK_SPACING, MIN_USABLE_TICK, MAX_USABLE_TICK, MAX_ROUTER_FEE_BPS, MIN_VALUATION, MAX_VALUATION, MAX_NAME_BYTES, MAX_SYMBOL_BYTES, MAX_URI_BYTES` (not in `ISVLaunchpad`); public immutables `POOL_MANAGER`, `PERMIT2`; public storage `feeWallet, routerFeeBps, creatorShareBps, firstBuyCapBps, dailyLaunchLimit, launcherGate, hook, launchCount`; private `_currencies`, `_launches`, `_days`, `_owed` in the slot order of spec 4.4; `struct DayCount {uint64 day; uint8 count;}`; the eight setters, `renounceOwnership`, `isAllowedLauncher(address) public view returns (bool)`, `currency(address) returns (CurrencyConfig memory)`, `predictToken(address creator, bytes32 salt, string calldata name, string calldata symbol) returns (address)`, `openingFor(address token, address quote, uint256 valuation) pure returns (int24 openTick, uint160 sqrtPriceX96, uint256 snappedValuation)`; private `_opening` (the same maths `launch` uses in Task 3), `_salt(address creator, bytes32 salt) returns (bytes32)`, `_checkPayout(address)` (the payout rule, also applied to the fee wallet here and reused by Tasks 3 and 4), `_nonZero(address) returns (address)`.
  - `abstract contract SVLaunchpadTestBase is Test` with constants `CREATOR_KEY = 0xC4EA`, `STRANGER_KEY = 0xB0BB1E`, `SUPPLY`, `MIN_VALUATION`, `MAX_VALUATION`, `USDG_MIN = 5_000e6`, `USDG_MAX = 10_000_000e6`, `STK_MIN = 50e18`, `STK_MAX = 100_000e18`, `MINT = 1e30`, `NOW = 1_790_000_000`, `MIN_USABLE_TICK`, `MAX_USABLE_TICK`; state `manager (IPoolManager)`, `swapRouter (PoolSwapTest)`, `permit2`, `usdg`, `stk` (`MockERC20`, 6 and 18 decimals), `gate (MockERC721`, the creator holds token 1), `launchpad`, `creator`, `stranger`, `owner`, `feeWallet`, `nextNonce`; helpers `_fund(address wallet, address token)`, `_hookAt(uint160 flags) returns (address)`. Tasks 3 and 4 append helpers to it.

**Settled here:** `setCurrency` with `maxValuation == 0` clears the whole row and emits `CurrencyChanged(quote, 0, 0, 0)`, the row as stored, whatever minimum and fee it was given. The constants of spec 4.3 are `internal`, for bytecode margin; the tests prove each through behaviour. The fee wallet follows the payout rule (amended 29 Sep 2026): zero reverts `ZeroAddress`, this contract or the PoolManager reverts `BadPayout`, in the constructor and in `setFeeWallet`.

- [ ] **Step 1: Write the failing fixture and settings suite**

`test/unit/SVLaunchpad.t.sol`:

```solidity
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

/// @notice Shared fixture for the launchpad unit suites: a local PoolManager and v4-core's swap test router, the
///         real Permit2 etched at its canonical address, two mock quotes at 6 and 18 decimals allowed at the
///         DEFAULT USD 5,000 to 10,000,000 bounds (the 18-decimal one priced at USD 100), a mock Suits NFT as the
///         launcher gate with the creator holding one, and an SVLaunchpad at the spec's initial settings.
/// @dev Every account is a `vm.addr` key or a `makeAddr` label; no real wallet or key appears. The clock starts at
///      a fixed timestamp so the tests read the same everywhere.
abstract contract SVLaunchpadTestBase is Test {
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
        hookAddress =
            address((uint160(uint256(keccak256(abi.encode("hook", flags)))) & ~Hooks.ALL_HOOK_MASK) | flags);
        vm.etch(hookAddress, hex"00");
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
        address removeOnly = _hookAt(Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);
        vm.prank(owner);
        launchpad.setHook(removeOnly);
        assertEq(launchpad.hook(), removeOnly, "remove-liquidity hooks without the returns-delta flag are allowed");
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `forge test --match-path 'test/unit/SVLaunchpad.t.sol'`
Expected: compilation fails with `Source "../../src/SVLaunchpad.sol" not found`.

- [ ] **Step 3: Declare this task's functions in the interface**

In `src/interfaces/ISVLaunchpad.sol`, inside the interface, after the last error, append:

```solidity

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
```

Task 3 inserts `launch` and `unlockCallback` under a new `Anyone` banner before `Owner only`, and `getLaunch`, `poolKeyOf` and `launchesToday` into the Views; Task 4 adds the rest. The final order is the spec's.

- [ ] **Step 4: Write the launchpad as of this task**

`src/SVLaunchpad.sol`:

```solidity
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
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(SVLaunchToken).creationCode, abi.encode(name, symbol, address(this))));
        return Create2.computeAddress(_salt(creator, salt), initCodeHash);
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
        return keccak256(abi.encode(creator, salt));
    }

    /// @dev Reverts with `ZeroAddress()` for the zero address, otherwise returns the input unchanged. Used in the
    ///      constructor's `Ownable` argument, which is evaluated before any base constructor runs.
    function _nonZero(address account) private pure returns (address) {
        if (account == address(0)) revert ZeroAddress();
        return account;
    }
}
```

The private mappings `_launches`, `_days` and `_owed` are declared here, unused until Tasks 3 and 4, so the slot order of spec 4.4 is fixed from the first commit; solc does not warn about unused private state.

- [ ] **Step 5: Run the suite to verify it passes**

Run: `forge fmt && forge test --match-path 'test/unit/SVLaunchpad.t.sol' -vv`
Expected: `SVLaunchpadSettingsTest`: `27 passed, 0 failed`. If an opening value differs, stop: the snapping code must reproduce spec section 3.2 exactly; do not edit the expected numbers, they come from the pinned TickMath and match the spec's table.

- [ ] **Step 6: Gates**

Run gates 1 to 5 of Global Constraints. Expected: `forge build --sizes --skip test --skip script` lists `SVLaunchpad` well under 24,576 bytes; coverage, still without the profile prefix, shows `src/SVLaunchpad.sol` and `src/SVLaunchToken.sol` at 100.00 % on all four columns. If a branch of `_opening` shows uncovered, the missing case is named in `test_openingFor_takes_every_snapping_branch`; add it there rather than removing the branch.

- [ ] **Step 7: Commit**

```bash
git add src/SVLaunchpad.sol src/interfaces/ISVLaunchpad.sol test/unit/SVLaunchpad.t.sol
git commit -m "SVLaunchpad settings, launcher gate, currency bounds, predictToken and the snapped opening maths

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016RxWfZk26aLfhGaoXcrYLf"
```

---

### Task 3: `launch`: CREATE2 token, `initialize`, the one-sided position and the first buy inside one unlock, fees, dust burn, `Launched`

**Files:**
- Modify: `src/SVLaunchpad.sol` (imports, `using` lines, the transient slot constant, the callback types, the launch section, three views, four helpers)
- Modify: `src/interfaces/ISVLaunchpad.sol` (an `Anyone` banner with `launch` and `unlockCallback`; `getLaunch`, `poolKeyOf`, `launchesToday` in the Views)
- Modify: `test/unit/SVLaunchpad.t.sol` (fixture: imports and launch helpers)
- Modify: `foundry.toml` only if the size check of Step 7 requires it
- Test: `test/unit/SVLaunchpad.launch.t.sol`

**Interfaces:**
- Consumes: Task 2's contract, `_opening`, `_salt`; v4-core `IPoolManager.initialize(PoolKey, uint160) returns (int24)`, `unlock(bytes) returns (bytes)`, `modifyLiquidity(PoolKey, IPoolManager.ModifyLiquidityParams{tickLower, tickUpper, liquidityDelta, salt}, bytes) returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)`, `swap(PoolKey, IPoolManager.SwapParams{zeroForOne, amountSpecified, sqrtPriceLimitX96}, bytes) returns (BalanceDelta)`, `sync(Currency)`, `settle() returns (uint256)`, `take(Currency, address, uint256)`, `IPoolManager.CurrencyNotSettled`, `Pool.PoolAlreadyInitialized`, `BalanceDelta.amount0()/amount1()`, `PoolKey.toId()`, `TickMath.MIN_SQRT_PRICE`, `TickMath.MAX_SQRT_PRICE`; v4-periphery `LiquidityAmounts.getLiquidityForAmount0(uint160, uint160, uint256) returns (uint128)`, `getLiquidityForAmount1(uint160, uint160, uint256) returns (uint128)`; OZ `TransientSlot` (`bytes32.asBoolean().tload()` and `.tstore(bool)`), `SafeERC20.safeTransfer`; Permit2 `permitTransferFrom(PermitTransferFrom, SignatureTransferDetails, address owner, bytes signature)`; test side `SqrtPriceMath.getAmount0Delta(uint160, uint160, uint128, bool)`, `getAmount1Delta(...)`, `StateLibrary.getSlot0`, `getLiquidity`, `getPositionInfo(manager, poolId, owner, tickLower, tickUpper, salt)`, `vm.snapshotState()`, `vm.revertToState(uint256)`, `Permit2Signer.sign(uint256 key, address permit2, PermitTransferFrom, address spender)`, `SignatureVerification.InvalidSigner`.
- Produces:
  - `function launch(LaunchParams calldata p, ISignatureTransfer.PermitTransferFrom calldata permit, bytes calldata signature) external returns (address token)`; `function unlockCallback(bytes calldata data) external returns (bytes memory)` (the `Action.Launch` path; Task 4 adds the dispatch); views `getLaunch(address) returns (Launch memory)`, `poolKeyOf(address) returns (PoolKey memory)`, `launchesToday(address) returns (uint256)`.
  - In the contract: `enum Action {Launch, Collect}`, `struct LaunchCallback {PoolKey key; int24 tickLower; int24 tickUpper; address token; address quote; bool tokenIsCurrency0; uint256 net; address creator; uint256 minFirstBuyTokens;}`, `struct LaunchResult {uint128 liquidity; uint256 owed; uint256 tokensOut;}` (spec 4.2 verbatim), `struct LaunchState` (the working memory of `launch`); private `_countLaunch(address)`, `_checkText(LaunchParams calldata)`, `_pull(address quote, uint256 total, PermitTransferFrom calldata, bytes calldata)`, `_unlock(bytes memory) returns (bytes memory)`, `_unlockLaunch(LaunchState memory, uint256 minFirstBuyTokens) returns (LaunchResult memory)`, `_launchCallback(LaunchCallback memory) returns (bytes memory)`, `_firstBuy(LaunchCallback memory) returns (uint256 tokensOut)`, `_pay(address currency_, uint256 amount)`, `_finishLaunch(LaunchState memory, LaunchParams calldata)`, `_emitLaunched(LaunchState memory, LaunchParams calldata)`, `_liquidityFor(bool tokenIsCurrency0, int24 openTick) returns (uint128)`, `_key(address token, address quote, address hook_) returns (PoolKey memory)`, `_range(bool tokenIsCurrency0, int24 openTick) returns (int24 tickLower, int24 tickUpper)`, `_launchOf(address token) returns (Launch memory)`. Task 4 reuses `_unlock`, `_key`, `_range`, `_launchOf`, and Task 2's `_checkPayout`.
  - Fixture (in `SVLaunchpadTestBase`): constants `PERMIT_PULL`, `NAME = "Launch Token"`, `SYMBOL = "LT"`, `URI`; `struct Expected {int24 openTick; uint160 sqrtPriceX96; uint256 snapped; uint128 liquidity; uint256 owed;}`; helpers `_saltFor(address who, address quote, bool tokenFirst) returns (bytes32)`, `_params(address who, address quote, uint256 valuation, bool tokenFirst) returns (LaunchParams memory)`, `_permit(uint256 key, address token, uint256 amount) returns (PermitTransferFrom memory, bytes memory)`, `_emptyPermit() returns (PermitTransferFrom memory)`, `_launch(uint256 key, LaunchParams memory) returns (address)`, `_launchFree(address quote, uint256 valuation, bool tokenFirst) returns (address)`, `_launchWithBuy(address quote, uint256 valuation, bool tokenFirst, uint256 firstBuy) returns (address)`, `_expectLaunchRevert(uint256 key, LaunchParams memory, bytes memory revertData)`, `_dryRunTokensOut(LaunchParams memory) returns (uint256)`, `_quirkyQuote(uint256 creationFee) returns (MockQuirkyERC20)`, `_expected(address token, address quote, uint256 valuation) returns (Expected memory)`, `_dustBound(address token, address quote, uint160 sqrtOpen) returns (uint256)`, `_keyFor(address token, address quote, address hookAddress) returns (PoolKey memory)`, `_range(address token) returns (int24, int24)`, `_positionLiquidity(address token) returns (uint128)`, `_activeLiquidity(address token) returns (uint128)`, `_slot0(address token) returns (uint160 sqrtPriceX96, int24 tick)`, `_launchedFrom(Vm.Log[] memory) returns (address token, LaunchedData memory)`, `_transfersTo(Vm.Log[] memory, address token, address to) returns (uint256)`, `_expectNoPermitPull()`, `_expectOnePermitPull()`.

**Settled here:** `getLaunch` of an unknown token returns the empty struct (a launch exists when `creator` is non-zero, spec 4.4), while `poolKeyOf` reverts `UnknownLaunch`, since a key with a zero quote would name no pool. The first-buy checks run after the swap whether or not there was one, so `minFirstBuyTokens > 0` without a first buy reverts `FirstBuyTooSmall(0, min)` as spec 4.5 step 11.3 says. Fee-on-transfer quotes, as the spec was amended on 29 Sep 2026: a quote taxing every transfer fails the measured pull of step 7 with `PermitMismatch` on a first buy and on a creation fee; a quote taxing only transfers into the PoolManager passes the pull and reverts `CurrencyNotSettled` at the quote settlement; a free launch in a taxed quote pulls nothing and succeeds.

- [ ] **Step 1: Add the launch helpers to the fixture**

In `test/unit/SVLaunchpad.t.sol` add these imports after the existing ones:

```solidity
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
```

Add `using StateLibrary for IPoolManager;` as the first line inside `abstract contract SVLaunchpadTestBase is Test {`, then, directly after `uint256 internal nextNonce;`, add:

```solidity
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
```

and append these helpers after `_hookAt`:

```solidity
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
```

- [ ] **Step 2: Write the failing launch suite**

`test/unit/SVLaunchpad.launch.t.sol`:

```solidity
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
            permitted: ISignatureTransfer.TokenPermissions({token: address(stk), amount: 1}),
            nonce: 7,
            deadline: 0
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
```

- [ ] **Step 3: Run it to verify it fails**

Run: `forge test --match-path 'test/unit/SVLaunchpad.launch.t.sol'`
Expected: compilation fails with `Member "launch" not found or not visible after argument-dependent lookup in contract SVLaunchpad` (and `getLaunch`, `poolKeyOf`, `launchesToday`, `unlockCallback`).

- [ ] **Step 4: Declare this task's functions in the interface**

In `src/interfaces/ISVLaunchpad.sol`, directly after the last error and before the `Owner only` banner, insert:

```solidity

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
```

In the Views section, directly before `predictToken`, insert:

```solidity
    /// @notice One launch as stored; an empty struct (zero `creator`) when the token was not launched here.
    function getLaunch(address token) external view returns (Launch memory);

    /// @notice The pool key of a launch; reverts `UnknownLaunch` for a token not launched here.
    function poolKeyOf(address token) external view returns (PoolKey memory);

```

and directly after `isAllowedLauncher`, insert:

```solidity

    /// @notice Launches `account` made on the current UTC day.
    function launchesToday(address account) external view returns (uint256);
```

- [ ] **Step 5: Implement the launch**

In `src/SVLaunchpad.sol`:

(a) Replace the import block with:

```solidity
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
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {ISVLaunchpad} from "./interfaces/ISVLaunchpad.sol";
import {SVLaunchToken} from "./SVLaunchToken.sol";
```

(b) Replace `    using Hooks for IHooks;` with:

```solidity
    using Hooks for IHooks;
    using SafeERC20 for IERC20;
    using TransientSlot for *;
```

(c) Directly after `uint8 private constant INITIAL_DAILY_LAUNCH_LIMIT = 5;`, add:

```solidity
    /// @dev The transient "unlock in flight" flag read by `unlockCallback` (spec section 4.4), at the ERC-7201
    ///      slot of the namespace "svlaunchpad.unlocking".
    bytes32 private constant UNLOCKING_SLOT =
        keccak256(abi.encode(uint256(keccak256("svlaunchpad.unlocking")) - 1)) & ~bytes32(uint256(0xff));
```

(d) Directly after the `DayCount` struct, add:

```solidity

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
```

(e) Directly before the `Owner settings` banner, add the launch section:

```solidity
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
        (, LaunchCallback memory cb) = abi.decode(data, (Action, LaunchCallback));
        return _launchCallback(cb);
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
```

(f) In the Views section, directly before `isAllowedLauncher`, add:

```solidity
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

```

and directly after `isAllowedLauncher`, add:

```solidity

    /// @inheritdoc ISVLaunchpad
    function launchesToday(address account) external view returns (uint256) {
        DayCount memory d = _days[account];
        return d.day == block.timestamp / 1 days ? d.count : 0;
    }
```

(g) In the Internal helpers section, directly after `_opening`, add:

```solidity

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
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `forge fmt && forge test --match-path 'test/unit/SVLaunchpad*.t.sol' -vv`
Expected: `SVLaunchpadLaunchTest`: `36 passed, 0 failed`; `SVLaunchpadSettingsTest` still `27 passed`. The `-vv` log shows `gas of a launch with a first buy` at about 1.14 million in the normal build (the review build's measurement); under `forge coverage`, which compiles unoptimised, it is about 1.58 million, which is why the test's limit is 2,500,000. If the expected `Launched` event of a free launch differs in `liquidity` or `tokensInPool`, compare the contract's `_liquidityFor` and the order of `tickLower`/`tickUpper` with spec 3.3 before touching the fixture's `_expected`, which recomputes spec 3.3 with the pool's own libraries.

- [ ] **Step 7: The launch profile, the coverage profile, the size check (spec section 4.11)**

The review build measured `SVLaunchpad` at 26,372 bytes after this task and 31,700 bytes after Task 4 at 1,000,000 optimizer runs, over the EIP-170 limit of 24,576, so the low-run profile is mandatory. Add these lines to `foundry.toml` directly after `auto_detect_remappings = false` (both keys are needed; forge 1.4 parses them, verified 29 Sep 2026):

```toml
# SVLaunchpad embeds SVLaunchToken's creation code for its CREATE2 deployment, which puts it over the EIP-170
# limit of 24,576 bytes at 1,000,000 optimizer runs. The two launch sources are compiled at 200 runs instead;
# every other file, SVRouter included, keeps the setting above, so SVRouter's bytecode is unchanged. Launched
# tokens and the launchpad therefore verify with --optimizer-runs 200.
additional_compiler_profiles = [{ name = "launchpad", optimizer_runs = 200 }]
compilation_restrictions = [{ paths = "src/SVLaunch*.sol", optimizer_runs = 200 }]
```

and append this section at the end of `foundry.toml`:

```toml
# Coverage builds are unoptimised and cannot honour a per-file compiler restriction, so this profile clears
# both keys. Run coverage as: FOUNDRY_PROFILE=coverage forge coverage --report summary --no-match-path 'test/fork/*'
[profile.coverage]
additional_compiler_profiles = []
compilation_restrictions = []
```

Then run `forge clean` and `forge build --sizes --skip test --skip script`.

Stop rule: `SVLaunchpad` must be at most 24,320 bytes, at least 256 bytes under the limit. If it is above that at 200 runs, change both `optimizer_runs = 200` values above to `optimizer_runs = 1`, update the comment's "200 runs" and "--optimizer-runs 200" to 1, run `forge clean`, and rebuild. If it is still above 24,320 bytes at 1 run, stop and report the size to the controller; do not remove code to fit. Expected either way: `SVRouter` still 7,647 bytes. The review build measured the finished contract (after Task 4) at 24,301 bytes at 200 runs: only 19 bytes under the 24,320-byte stop rule. So any addition to `SVLaunchpad` after Task 4, or any Task 4 change that grows it, applies the `optimizer_runs = 1` fallback first, then rebuilds and rechecks. Note the size at 1,000,000 runs (build once before adding the keys), the size as built and the runs used in the task report; Task 6 copies them into the README.

- [ ] **Step 8: Gates**

Run gates 1 to 5 of Global Constraints, coverage now with `FOUNDRY_PROFILE=coverage`. Expected: coverage `src/SVLaunchpad.sol` at 100.00 % on all four columns. The branch pairs this task adds are each taken by a named test: a free launch and a paid one (`_pull`, steps 11.5 and 12), a first buy and none (steps 11.3 and 11.6), `test_launches_at_the_bounds_and_at_MAX_VALUATION_where_nothing_is_burned` (step 13's no-dust side), `test_a_fee_on_transfer_quote_fails_the_measured_pull_of_a_creation_fee_only_launch` (the measured pull), the daily-limit test (both sides of the day check in `_countLaunch` and `launchesToday`).

- [ ] **Step 9: Commit**

```bash
git add src/SVLaunchpad.sol src/interfaces/ISVLaunchpad.sol test/unit/SVLaunchpad.t.sol test/unit/SVLaunchpad.launch.t.sol foundry.toml
git commit -m "SVLaunchpad launch: CREATE2 token, pool at the snapped valuation, one-sided locked position, first buy through Permit2

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016RxWfZk26aLfhGaoXcrYLf"
```

---

### Task 4: `collectFees` with the measured split, tolerant delivery and `owed`, `claim`, `setPayout`, `uncollectedFees`; invariants, the full ABI pin, the storage layout

**Files:**
- Modify: `src/SVLaunchpad.sol` (imports, `using`, the dispatch in `unlockCallback`, the fees section, two views, one helper)
- Modify: `src/interfaces/ISVLaunchpad.sol` (`collectFees`, `claim`, `setPayout` under Anyone; `uncollectedFees`, `owed` in the Views)
- Modify: `test/unit/SVLaunchpad.t.sol` (fixture: `_swap`, `_feesCollectedFrom`)
- Test: `test/unit/SVLaunchpad.fees.t.sol`, `test/unit/SVLaunchpad.invariant.t.sol`, `test/unit/SVLaunchpadAbi.t.sol`

**Interfaces:**
- Consumes: Task 3's `_unlock`, `_key`, `_range`, `_launchOf`, Task 2's `_checkPayout`, `Action`, `LaunchCallback`, `_launchCallback`; v4-core `IPoolManager.modifyLiquidity` with `liquidityDelta = 0` (the poke: the caller delta is exactly the fees since the last checkpoint), `take(Currency, address, uint256)`, `StateLibrary.getPositionInfo(IPoolManager, PoolId, address owner, int24, int24, bytes32) returns (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128)`, `StateLibrary.getFeeGrowthInside(IPoolManager, PoolId, int24, int24) returns (uint256, uint256)`, `FixedPoint128.Q128`; test side `PoolSwapTest.swap(PoolKey, IPoolManager.SwapParams, PoolSwapTest.TestSettings{takeClaims, settleUsingBurn}, bytes)` (it pulls the input from the caller with `transferFrom`, so the payer approves it), forge-std `targetContract`, `targetSelector(FuzzSelector)`.
- Produces: `collectFees(address token)`, `claim(address currency, address to)`, `setPayout(address token, address payout)`, `uncollectedFees(address token) returns (PendingFees memory)`, `owed(address account, address currency) returns (uint256)`; private `_collectCallback(address token) returns (bytes memory)`, `_takeMeasured(address asset, int128 delta) returns (uint256)`, `_deliver(address asset, address to, uint256 amount)`, `_pendingFees(address token, Launch memory) returns (uint256 fees0, uint256 fees1)`. Fixture: `_swap(address token, bool buy, uint256 amountIn) returns (uint256 amountOut)`, `_feesCollectedFrom(Vm.Log[] memory) returns (uint256 tokenFees, uint256 quoteFees, uint256 tokenToPayout, uint256 quoteToPayout)`. Test-only `contract LaunchpadFeesHandler` with counters `creditingCollections()` and `claims()`, actions `buy, sell, collect, refuse, toggleTransferFee, claim, movePayout, setPayoutAsStranger, unlockCallbackAsPoolManager, secondLaunch`, and `account(uint256) returns (address)`.

**Settled here:** `setPayout` to the address already set is allowed and emits, which keeps the rule to the spec's three checks. `claim` of the launch token works like any currency: a token credited there is claimable, although the launch token never refuses a delivery. The contract's parameter names are `asset` where the interface says `currency`, so no parameter shadows the `currency()` view; selectors and the ABI are unchanged.

- [ ] **Step 1: Add the trade helpers to the fixture**

In `test/unit/SVLaunchpad.t.sol`, append after `_expectOnePermitPull`:

```solidity
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
```

- [ ] **Step 2: Write the failing fees suite**

`test/unit/SVLaunchpad.fees.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {ISVLaunchpad} from "../../src/interfaces/ISVLaunchpad.sol";
import {MockQuirkyERC20} from "../mocks/MockQuirkyERC20.sol";
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
            emit ISVLaunchpad.FeesCollected(
                token, creator, f.tokenFees, f.quoteFees, f.tokenToPayout, f.quoteToPayout
            );
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
        assertEq(address(uint160(slot2)), feeWallet, "slot 2: feeWallet");
        assertEq(uint16(slot2 >> 160), 50, "slot 2: routerFeeBps");
        assertEq(uint16(slot2 >> 176), 7_000, "slot 2: creatorShareBps");
        assertEq(uint16(slot2 >> 192), 2_000, "slot 2: firstBuyCapBps");
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
        assertEq(address(uint160(first)), creator, "slot 7: launches, creator first");
        assertEq(uint64(first >> 160), block.timestamp, "then launchedAt");
        assertEq(uint16(first >> 224), 7_000, "then creatorShareBps");
        assertEq(
            address(uint160(uint256(vm.load(lp, bytes32(uint256(launchSlot) + 2))))),
            address(q),
            "the third word is the quote"
        );
        uint256 dayWord = uint256(vm.load(lp, keccak256(abi.encode(creator, uint256(8)))));
        assertEq(uint64(dayWord), block.timestamp / 1 days, "slot 8: days, the day number");
        assertEq(uint8(dayWord >> 64), 1, "then the count");
        bytes32 owedSlot = keccak256(abi.encode(address(q), keccak256(abi.encode(creator, uint256(9)))));
        assertGt(launchpad.owed(creator, address(q)), 0, "a credited share to find");
        assertEq(uint256(vm.load(lp, owedSlot)), launchpad.owed(creator, address(q)), "slot 9: owed[account][currency]");
    }
}
```

- [ ] **Step 3: Write the failing invariant suite**

`test/unit/SVLaunchpad.invariant.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {SVLaunchpad} from "../../src/SVLaunchpad.sol";
import {ISVLaunchpad} from "../../src/interfaces/ISVLaunchpad.sol";
import {MockQuirkyERC20} from "../mocks/MockQuirkyERC20.sol";
import {SVLaunchpadTestBase} from "./SVLaunchpad.t.sol";

/// @notice Every call that touches a launch after it exists, for the invariant runner to sequence at random:
///         buys, sells, collections, claims, payout moves, the quote turning refusing, answering false or charging
///         a transfer fee, and the hostile calls that must change nothing: `unlockCallback` from the PoolManager
///         with no unlock in flight, `setPayout` from a stranger, and a second launch beside the first. Reverts are
///         expected and allowed; the counters prove the interesting paths actually ran.
contract LaunchpadFeesHandler is Test {
    SVLaunchpad internal immutable LAUNCHPAD;
    PoolSwapTest internal immutable SWAP_ROUTER;
    MockQuirkyERC20 internal immutable QUOTE;
    IPoolManager internal immutable POOL_MANAGER;
    address internal immutable TOKEN;
    address internal immutable FEE_WALLET;
    /// @dev Never refused and never owed: where claims are sent, so a claim fails only for a real reason.
    address internal immutable RESCUE;
    address[3] internal payouts;
    uint256 internal saltCounter;

    /// @notice Successful collections that credited at least one share to `owed`.
    uint256 public creditingCollections;
    /// @notice Successful claims.
    uint256 public claims;

    constructor(
        SVLaunchpad launchpad,
        PoolSwapTest swapRouter,
        MockQuirkyERC20 quote,
        address token,
        address feeWallet,
        address[3] memory payouts_
    ) {
        LAUNCHPAD = launchpad;
        SWAP_ROUTER = swapRouter;
        QUOTE = quote;
        POOL_MANAGER = launchpad.POOL_MANAGER();
        TOKEN = token;
        FEE_WALLET = feeWallet;
        RESCUE = makeAddr("rescue");
        payouts = payouts_;
        quote.approve(address(swapRouter), type(uint256).max);
        IERC20(token).approve(address(swapRouter), type(uint256).max);
    }

    function buy(uint256 amount) public {
        _swap(true, bound(amount, 1e6, 1_000e6));
    }

    function sell(uint256 amount) external {
        uint256 held = IERC20(TOKEN).balanceOf(address(this));
        if (held == 0) return;
        _swap(false, bound(amount, 1, held));
    }

    function collect() external {
        uint256 before = _owedSum();
        LAUNCHPAD.collectFees(TOKEN);
        if (_owedSum() > before) creditingCollections++;
    }

    function refuse(bool payoutSide, uint256 mode) external {
        address target = payoutSide ? LAUNCHPAD.getLaunch(TOKEN).payout : FEE_WALLET;
        QUOTE.setRefusal(target, MockQuirkyERC20.Refusal(mode % 3));
    }

    function toggleTransferFee(bool on) external {
        QUOTE.setTransferFee(on ? 100 : 0, address(0));
    }

    /// @dev Claims the first owed balance it finds, to the rescue address or to one of the owed accounts.
    function claim(uint256 to) external {
        address recipient = to % 2 == 0 ? RESCUE : account(to / 2);
        for (uint256 i = 0; i < 4; i++) {
            address claimant = account(i);
            address asset = LAUNCHPAD.owed(claimant, address(QUOTE)) > 0 ? address(QUOTE) : TOKEN;
            if (LAUNCHPAD.owed(claimant, asset) == 0) continue;
            vm.prank(claimant);
            LAUNCHPAD.claim(asset, recipient);
            claims++;
            return;
        }
    }

    function movePayout(uint256 to) external {
        address current = LAUNCHPAD.getLaunch(TOKEN).payout;
        vm.prank(current);
        LAUNCHPAD.setPayout(TOKEN, payouts[to % 3]);
    }

    /// @dev Must always revert `NotPayout`: a stranger can never move the payout.
    function setPayoutAsStranger(address to) external {
        vm.prank(makeAddr("stranger in the handler"));
        LAUNCHPAD.setPayout(TOKEN, to);
    }

    /// @dev Must always revert `UnexpectedCallback`: the PoolManager calling with no launchpad unlock in flight.
    function unlockCallbackAsPoolManager(bytes calldata data) external {
        vm.prank(address(POOL_MANAGER));
        LAUNCHPAD.unlockCallback(data);
    }

    /// @dev A second, free launch in the same quote beside the watched one; the handler holds a gate token.
    function secondLaunch() external {
        ISVLaunchpad.LaunchParams memory p;
        p.name = "Second";
        p.symbol = "TWO";
        p.quote = address(QUOTE);
        p.valuation = 5_000e6;
        p.salt = bytes32(saltCounter++);
        p.deadline = block.timestamp + 1 hours;
        ISignatureTransfer.PermitTransferFrom memory none;
        LAUNCHPAD.launch(p, none, "");
    }

    /// @notice The four accounts that can ever be owed: the three payout candidates and the fee wallet.
    function account(uint256 i) public view returns (address) {
        i = i % 4;
        return i == 3 ? FEE_WALLET : payouts[i];
    }

    function _owedSum() internal view returns (uint256 sum) {
        for (uint256 i = 0; i < 4; i++) {
            sum += LAUNCHPAD.owed(account(i), address(QUOTE)) + LAUNCHPAD.owed(account(i), TOKEN);
        }
    }

    function _swap(bool buy_, uint256 amountIn) internal {
        ISVLaunchpad.Launch memory l = LAUNCHPAD.getLaunch(TOKEN);
        bool zeroForOne = buy_ ? !l.tokenIsCurrency0 : l.tokenIsCurrency0;
        SWAP_ROUTER.swap(
            LAUNCHPAD.poolKeyOf(TOKEN),
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                // Bounded amounts, far below 2^255.
                // forge-lint: disable-next-line(unsafe-typecast)
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}

/// @notice Spec sections 4.6 and 8.1, invariant: per currency, the launchpad's balance equals the sum of `owed`,
///         through collections, failed deliveries and claims in random order, including a fee-on-transfer quote;
///         and after launch no sequence of calls changes the position's liquidity. Every run starts with a
///         share already credited to the refused payout; `afterInvariant` checks that, and a unit test drives the
///         credit-then-claim path deterministically.
contract SVLaunchpadInvariantTest is SVLaunchpadTestBase {
    LaunchpadFeesHandler internal handler;
    MockQuirkyERC20 internal q;
    address internal token;

    function setUp() public override {
        super.setUp();
        q = _quirkyQuote(0);
        token = _launchFree(address(q), USDG_MIN, true);
        address[3] memory payouts = [creator, makeAddr("payout b"), makeAddr("payout c")];
        handler = new LaunchpadFeesHandler(launchpad, swapRouter, q, token, feeWallet, payouts);
        q.mint(address(handler), 1e24);
        gate.mint(address(handler), 2);
        // Fees accrued and the payout refused before the first call of every run.
        handler.buy(100e6);
        q.setRefusal(creator, MockQuirkyERC20.Refusal.Revert);
        // Every run starts with a credited share, so its balance-equals-owed check is never vacuous.
        handler.collect();
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.sell.selector;
        selectors[2] = handler.collect.selector;
        selectors[3] = handler.refuse.selector;
        selectors[4] = handler.toggleTransferFee.selector;
        selectors[5] = handler.claim.selector;
        selectors[6] = handler.movePayout.selector;
        selectors[7] = handler.setPayoutAsStranger.selector;
        selectors[8] = handler.unlockCallbackAsPoolManager.selector;
        selectors[9] = handler.secondLaunch.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 256
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_the_launchpad_holds_exactly_the_owed_balances() public view {
        uint256 owedQuote;
        uint256 owedToken;
        for (uint256 i = 0; i < 4; i++) {
            owedQuote += launchpad.owed(handler.account(i), address(q));
            owedToken += launchpad.owed(handler.account(i), token);
        }
        assertEq(q.balanceOf(address(launchpad)), owedQuote, "quote held equals the owed sum");
        assertEq(IERC20(token).balanceOf(address(launchpad)), owedToken, "token held equals the owed sum");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 256
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_the_position_liquidity_never_changes_after_launch() public view {
        uint128 stored = launchpad.getLaunch(token).liquidity;
        assertGt(stored, 0, "the launch placed liquidity");
        assertEq(_positionLiquidity(token), stored, "the position's liquidity changed after launch");
    }

    /// @dev Runs after each invariant run: the run carried a credited share. Claims are proved deterministically
    ///      by the unit test below, not per run, so a random sequence without a claim is not a failure.
    function afterInvariant() external view {
        assertGt(handler.creditingCollections(), 0, "a collection credited a refused share to owed");
    }

    /// @dev The handler's two interesting paths, driven in a fixed order: a collection with the payout refused
    ///      credits `owed`, and a claim sends it to the rescue address; the balance equals the owed sum after each.
    function test_the_handler_credits_a_refused_share_and_claims_it_to_the_rescue_address() public {
        assertEq(handler.creditingCollections(), 1, "setUp's collection credited the refused payout");
        assertGt(launchpad.owed(creator, address(q)), 0, "the payout's quote share waits in owed");
        invariant_the_launchpad_holds_exactly_the_owed_balances();
        handler.buy(100e6);
        handler.collect();
        assertEq(handler.creditingCollections(), 2, "with the payout still refused, a second collection credits again");
        invariant_the_launchpad_holds_exactly_the_owed_balances();
        handler.claim(0);
        assertEq(handler.claims(), 1, "one successful claim, to the rescue address");
        assertEq(launchpad.owed(creator, address(q)), 0, "the creator's owed balance is gone");
        invariant_the_launchpad_holds_exactly_the_owed_balances();
    }
}
```

- [ ] **Step 4: Write the failing ABI pin**

`test/unit/SVLaunchpadAbi.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ISVLaunchpad} from "../../src/interfaces/ISVLaunchpad.sol";

/// @notice Every function of `ISVLaunchpad` against its canonical signature in spec section 4.2, so the frontend's
///         transcribed ABI and this interface cannot drift apart unnoticed.
contract SVLaunchpadAbiTest is Test {
    function _pin(bytes4 actual, string memory signature) internal pure {
        assertEq(actual, bytes4(keccak256(bytes(signature))), signature);
    }

    function test_every_function_selector_matches_the_spec_signature() public pure {
        _pin(
            ISVLaunchpad.launch.selector,
            "launch((string,string,string,address,uint256,uint256,uint256,address,bytes32,uint256),((address,uint256),uint256,uint256),bytes)"
        );
        _pin(ISVLaunchpad.collectFees.selector, "collectFees(address)");
        _pin(ISVLaunchpad.claim.selector, "claim(address,address)");
        _pin(ISVLaunchpad.setPayout.selector, "setPayout(address,address)");
        _pin(ISVLaunchpad.unlockCallback.selector, "unlockCallback(bytes)");
        _pin(ISVLaunchpad.setFeeWallet.selector, "setFeeWallet(address)");
        _pin(ISVLaunchpad.setRouterFee.selector, "setRouterFee(uint16)");
        _pin(ISVLaunchpad.setCreatorShare.selector, "setCreatorShare(uint16)");
        _pin(ISVLaunchpad.setFirstBuyCap.selector, "setFirstBuyCap(uint16)");
        _pin(ISVLaunchpad.setDailyLaunchLimit.selector, "setDailyLaunchLimit(uint8)");
        _pin(ISVLaunchpad.setLauncherGate.selector, "setLauncherGate(address)");
        _pin(ISVLaunchpad.setHook.selector, "setHook(address)");
        _pin(ISVLaunchpad.setCurrency.selector, "setCurrency(address,uint256,uint256,uint256)");
        _pin(ISVLaunchpad.getLaunch.selector, "getLaunch(address)");
        _pin(ISVLaunchpad.poolKeyOf.selector, "poolKeyOf(address)");
        _pin(ISVLaunchpad.uncollectedFees.selector, "uncollectedFees(address)");
        _pin(ISVLaunchpad.predictToken.selector, "predictToken(address,bytes32,string,string)");
        _pin(ISVLaunchpad.openingFor.selector, "openingFor(address,address,uint256)");
        _pin(ISVLaunchpad.isAllowedLauncher.selector, "isAllowedLauncher(address)");
        _pin(ISVLaunchpad.launchesToday.selector, "launchesToday(address)");
        _pin(ISVLaunchpad.currency.selector, "currency(address)");
        _pin(ISVLaunchpad.owed.selector, "owed(address,address)");
        _pin(ISVLaunchpad.launchCount.selector, "launchCount()");
        _pin(ISVLaunchpad.feeWallet.selector, "feeWallet()");
        _pin(ISVLaunchpad.routerFeeBps.selector, "routerFeeBps()");
        _pin(ISVLaunchpad.creatorShareBps.selector, "creatorShareBps()");
        _pin(ISVLaunchpad.firstBuyCapBps.selector, "firstBuyCapBps()");
        _pin(ISVLaunchpad.dailyLaunchLimit.selector, "dailyLaunchLimit()");
        _pin(ISVLaunchpad.launcherGate.selector, "launcherGate()");
        _pin(ISVLaunchpad.hook.selector, "hook()");
        _pin(ISVLaunchpad.POOL_MANAGER.selector, "POOL_MANAGER()");
        _pin(ISVLaunchpad.PERMIT2.selector, "PERMIT2()");
    }
}
```

- [ ] **Step 5: Run the three files to verify they fail**

Run: `forge test --match-path 'test/unit/SVLaunchpad.fees.t.sol'`
Expected: compilation fails with `Member "uncollectedFees" not found or not visible after argument-dependent lookup` (and `collectFees`, `owed`, `claim`, `setPayout`). The invariant and ABI files fail the same compilation.

- [ ] **Step 6: Declare this task's functions in the interface**

In `src/interfaces/ISVLaunchpad.sol`, in the `Anyone` section directly after `launch`, insert:

```solidity

    /// @notice Anyone. Collect the fees accrued to a launch's position and split them between its payout address
    ///         and the fee wallet; a share whose delivery fails is credited to `owed` instead.
    function collectFees(address token) external;

    /// @notice Pays msg.sender's whole owed balance in `currency`, credited when a fee delivery failed, to `to`;
    ///         `to` of address(0), this contract or the PoolManager reverts BadPayout. Emits nothing.
    function claim(address currency, address to) external;

    /// @notice The launch's current payout address only.
    function setPayout(address token, address payout) external;
```

In the Views section, directly after `poolKeyOf`, insert:

```solidity

    /// @notice What a collection would take now, in token and quote terms, with its split; reverts UnknownLaunch.
    function uncollectedFees(address token) external view returns (PendingFees memory);
```

and directly after `currency`, insert:

```solidity

    /// @notice What `account` can claim in `currency`: its shares whose delivery failed.
    function owed(address account, address currency) external view returns (uint256);
```

The interface now lists exactly the functions of spec 4.2, in its order.

- [ ] **Step 7: Implement collection, delivery, claims and payout**

In `src/SVLaunchpad.sol`:

(a) Add two imports directly after the `FullMath` import:

```solidity
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
```

(b) After `using TransientSlot for *;`, add:

```solidity
    using StateLibrary for IPoolManager;
```

(c) Replace the body of `unlockCallback` after its two guards, that is the two lines

```solidity
        (, LaunchCallback memory cb) = abi.decode(data, (Action, LaunchCallback));
        return _launchCallback(cb);
```

with:

```solidity
        if (abi.decode(data[:32], (Action)) == Action.Launch) {
            (, LaunchCallback memory cb) = abi.decode(data, (Action, LaunchCallback));
            return _launchCallback(cb);
        }
        (, address token) = abi.decode(data, (Action, address));
        return _collectCallback(token);
```

(d) Directly after `_emitLaunched`, add the fees section:

```solidity

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
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: 0,
                salt: bytes32(0)
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
```

(e) In the Views section, directly after `poolKeyOf`, add:

```solidity

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
```

and directly after `currency`, add:

```solidity

    /// @inheritdoc ISVLaunchpad
    function owed(address account, address asset) external view returns (uint256) {
        return _owed[account][asset];
    }
```

(f) In the Internal helpers section, directly after `_launchOf`, add:

```solidity

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
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `forge fmt && forge test --match-path 'test/unit/SVLaunchpad*' -vv`
Expected: `SVLaunchpadFeesTest`: `22 passed, 0 failed`; `SVLaunchpadInvariantTest`: `3 passed`, the two invariants with `runs: 64, calls: 16384` each and a non-zero revert count (collections with nothing accrued, buys while the transfer fee is on, and every stranger `setPayout` and PoolManager `unlockCallback`, which must revert), `afterInvariant` green on every run because setUp's collection credits a share before each run, and `test_the_handler_credits_a_refused_share_and_claims_it_to_the_rescue_address` proving the credit-then-claim path deterministically. Before this run and before the gate run, delete forge's saved invariant sequences, the directory `cache/invariant`, so a stale replayed failure cannot mask or fake a result. If an invariant fails, report its call sequence; the fix is in the contract or the handler, never a weaker assertion; `SVLaunchpadAbiTest`: `1 passed`; the Task 2 and Task 3 suites unchanged.

- [ ] **Step 9: Size re-check and gates**

Run: `forge build --sizes --skip test --skip script`. `SVLaunchpad` must be at most 24,320 bytes; if it is not at 200 runs, apply Task 3 Step 7's fallback to `optimizer_runs = 1` (with `forge clean`), and if it is still above 24,320 bytes, stop and report. Then gates 1 to 5 of Global Constraints, coverage with `FOUNDRY_PROFILE=coverage`. Expected: `src/SVLaunchpad.sol` and `src/SVLaunchToken.sol` at 100.00 % on all four columns. The branch pairs this task adds are each taken by a named test: the dispatch in `unlockCallback` (any launch and any collection), `_takeMeasured`'s zero side (`test_a_one_way_trade_pays_one_currency_and_transfers_nothing_in_the_other`), `_deliver`'s zero amount (the same test) and its refused side (the three delivery tests), `NothingToCollect`, every revert of `claim` and `setPayout`, and both currency orders in `uncollectedFees`.

- [ ] **Step 10: Commit**

```bash
git add src/SVLaunchpad.sol src/interfaces/ISVLaunchpad.sol test/unit/SVLaunchpad.t.sol test/unit/SVLaunchpad.fees.t.sol test/unit/SVLaunchpad.invariant.t.sol test/unit/SVLaunchpadAbi.t.sol foundry.toml
git commit -m "SVLaunchpad fees: zero-delta poke, measured split, tolerant delivery with owed and claim, payout, uncollectedFees

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016RxWfZk26aLfhGaoXcrYLf"
```

---

### Task 5: Fuzz suite across the valuation range, and the fork suite on Robinhood Chain

**Files:**
- Test: `test/unit/SVLaunchpad.fuzz.t.sol`
- Test: `test/fork/SVLaunchpadFork.t.sol`

**Interfaces:**
- Consumes: the fixture (`_expected`, `_dustBound`, `_params`, `_launch`, `_launchFree`, `_launchedFrom`, `_swap`, `_feesCollectedFrom`, `_slot0`, `_positionLiquidity`); v4-core `Pool.tickSpacingToMaxLiquidityPerTick(int24) returns (uint128)`, `IPoolManager.Initialize.selector`, `IPoolManager.protocolFeeController() returns (address)`; v4-periphery `IStateView.getSlot0(PoolId) returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)`, `IStateView.getPositionInfo(PoolId, address owner, int24, int24, bytes32) returns (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128)`, `IStateView.getFeeGrowthInside(PoolId, int24, int24) returns (uint256, uint256)`, `IV4Quoter.quoteExactInputSingle(QuoteExactSingleParams{poolKey, zeroForOne, exactAmount, hookData}) returns (uint256 amountOut, uint256 gasEstimate)`; the deployed `ISVRouter` at `0xc9E6b76aA834e746080b1F8Ad6943930eD5147a9` with `feeFor(address, uint256) returns (uint256 fee, bool holderRate)`, `swapExactIn(SwapParams{key, zeroForOne, amountIn, amountOutMin, hookData, deadline}, PermitTransferFrom, bytes) returns (uint256)`.
- Produces: `contract SVLaunchpadFuzzTest is SVLaunchpadTestBase`; `contract SVLaunchpadForkTest is Test`, skipped without `ROBINHOOD_RPC_URL`.

**Fuzz bounds, re-checked for `MAX_VALUATION = 1e36`:** every valuation range is `[MIN_VALUATION, MAX_VALUATION]` or `[1e10, MAX_VALUATION]` by name, so the amended constant flows through. The first-buy fuzz buys at most `V' / 5 <= 2e35` raw units, well inside `int128` (about 1.7e38), which the swap's `amountSpecified` and the pool's deltas require; the fee-split fuzz trades at most `1e12` raw USDG. The creator is minted `1e42` of the 18-decimal quote, above any first buy.

**Settled here:** the first-buy curve fuzz starts at a valuation of `1e10` raw units instead of `MIN_VALUATION`: `V'` is an integer, and below `1e10` its own rounding alone can exceed a relative `1e-10` of it, which would make the spec's `1e-9` bound measure the test's arithmetic rather than the pool's. The opening and dust fuzz cover the whole `[MIN_VALUATION, MAX_VALUATION]` range as the spec says. The fork suite trades through the deployed SVRouter, which forwards to the deployed Universal Router, so one trade exercises both.

- [ ] **Step 1: Write the fuzz suite**

`test/unit/SVLaunchpad.fuzz.t.sol`:

```solidity
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
        assertGe(e.snapped * 10_202, valuation * 10_000, "V' x 1.0202 >= V");
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
```

- [ ] **Step 2: Run the fuzz suite**

Run: `forge test --match-path 'test/unit/SVLaunchpad.fuzz.t.sol' -vv`
Expected: `4 passed, 0 failed`, each at 256 runs. A failure is a finding against spec section 3: report the counterexample from the log (valuation, order, amount) to the controller before changing anything; do not widen a bound.

- [ ] **Step 3: Pin the fork block**

The public RPC serves only recent state (README: a pinned block was refused after about fifteen minutes once). Read the head:

```sh
cast block-number --rpc-url https://rpc.mainnet.chain.robinhood.com
```

Put that number minus 100 into `FORK_BLOCK` below with the date in its comment. `75_187_000` is the head of 29 Sep 2026 when this plan was written; a run later than about an hour after the pin needs `ROBINHOOD_FORK_BLOCK=<recent block>` or an archive endpoint in `ROBINHOOD_RPC_URL`.

- [ ] **Step 4: Write the fork suite**

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
    /// @dev Robinhood Chain (id 4663), 29 Sep 2026. Re-pin per the plan's Task 5 Step 3 before running.
    uint256 internal constant FORK_BLOCK = 75_187_000;

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

        launchpad = new SVLaunchpad(IPoolManager(POOL_MANAGER), ISignatureTransfer(PERMIT2), owner, feeWallet, SUITS_NFT);
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
        token = launchpad.launch(p, permit, signature);
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

    /// @dev The launch transaction's one `Initialize` log from the PoolManager names the launch pool.
    function _assertInitializeLog(Vm.Log[] memory logs, PoolKey memory key) internal pure {
        uint256 seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != POOL_MANAGER || logs[i].topics[0] != IPoolManager.Initialize.selector) continue;
            seen++;
            assertEq(logs[i].topics[1], PoolId.unwrap(key.toId()), "Initialize.id is the launch pool");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), Currency.unwrap(key.currency0), "currency0");
            assertEq(address(uint160(uint256(logs[i].topics[3]))), Currency.unwrap(key.currency1), "currency1");
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

    /// @dev The pool opened exactly at the snapped tick on the real PoolManager, holding L, at a 1 % LP fee; logs
    ///      the protocol fee facts spec section 12 asks for.
    function _assertOpened(address token) internal view {
        ISVLaunchpad.Launch memory l = launchpad.getLaunch(token);
        PoolId id = launchpad.poolKeyOf(token).toId();
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = STATE_VIEW.getSlot0(id);
        assertEq(tick, l.openTick, "the real pool opened at the snapped tick");
        assertEq(price, TickMath.getSqrtPriceAtTick(l.openTick), "exactly at its price");
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
        _assertInitializeLog(vm.getRecordedLogs(), key);
        _assertOpened(token);

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
        _assertInitializeLog(logs, key);
        _assertOpened(token);
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
```

- [ ] **Step 5: Run the fork suite without and with the RPC**

Run: `ROBINHOOD_RPC_URL= forge test --match-path 'test/fork/*'`
Expected: `SVLaunchpadForkTest` and `SVRouterForkTest` report skipped.

Run: `ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-path 'test/fork/SVLaunchpadFork.t.sol' -vv` (add `ROBINHOOD_FORK_BLOCK=<recent block>` when the pin has aged out).
Expected: `2 passed, 0 failed`, with `forked block`, `pool protocolFee` and `PoolManager protocolFeeController` in the log. Record the two protocol facts in the task report; Task 6 copies them into the README. If `deal did not fund USDG` fails, apply the PoolManager-prank fallback from the contract's `@dev`. If the StateView comparison fails, stop and report: it means the deployed PoolManager's storage differs from v4.0.0 and `uncollectedFees` must not ship as is (spec section 12).

- [ ] **Step 6: Gates**

Run gates 1 to 5 of Global Constraints, and gate 6.

- [ ] **Step 7: Commit**

```bash
git add test/unit/SVLaunchpad.fuzz.t.sol test/fork/SVLaunchpadFork.t.sol
git commit -m "Launchpad fuzz across the valuation range and fork suite: USDG and NVDA launches, SVRouter trades, StateView fees

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016RxWfZk26aLfhGaoXcrYLf"
```

---

### Task 6: `script/DeployLaunchpad.s.sol`, the per-currency bounds config and its conversion, README section, `.env.example`

**Files:**
- Create: `script/DeployLaunchpad.s.sol`
- Create: `script/config/launch-currencies.example.json`
- Create: `test/mocks/MockChainlinkAggregator.sol`
- Test: `test/unit/DeployLaunchpad.t.sol`
- Modify: `foundry.toml` (the one `fs_permissions` entry)
- Modify: `README.md` (title line, a new `SVLaunchpad` section before `## Layout`, rows in Layout and Environment variables)
- Modify: `.env.example` (append the launchpad inputs)

**Interfaces:**
- Consumes: `SVLaunchpad(IPoolManager, ISignatureTransfer, address owner_, address feeWallet_, address launcherGate_)`, `setCurrency`, `transferOwnership`, the settings views; OZ `IERC20Metadata.decimals()`; forge-std `vm.envAddress`, `vm.envOr(string, address)`, `vm.envOr(string, bool)`, `vm.readFile`, `vm.keyExistsJson`, `vm.parseJsonUint`, `vm.parseJsonString`, `vm.parseJsonAddress`, `vm.parseUint`, `vm.toString`, `vm.readCallers`, `vm.startBroadcast`, `vm.stopBroadcast`; Chainlink's `decimals()` and `latestRoundData()` on the row's proxy.
- Produces: `contract DeployLaunchpad is Script` with `struct Row {address quote; string symbol; uint8 decimals; string priceSource; address chainlinkProxy; uint8 chainlinkDecimals; uint256 referenceUsdPrice;}`, `struct Config {uint256 minUsd; uint256 maxUsd; uint256 creationFee; Row[] rows;}`, `run() returns (SVLaunchpad launchpad)`, `parseConfig(string memory json) public view returns (Config memory)`, `priceOf(Row memory row) public view returns (uint256 answer, uint8 feedDecimals)`, `bounds(uint256 minUsd, uint256 maxUsd, uint8 quoteDecimals, uint256 answer, uint8 feedDecimals) public pure returns (uint256 minValuation, uint256 maxValuation)`; `interface IChainlinkFeed`; `contract MockChainlinkAggregator` with `constructor(uint8 decimals_)`, `set(int256 answer, uint256 updatedAt)`, `decimals()`, `latestRoundData()`.
- The config schema, canonical and shared with the frontend generator `scripts/launch/currency-config.mts` (decided by the main session, 29 Sep 2026), written by the generator to `script/config/launch-currencies.json`:

  ```
  {
    "minUsd": <integer>,
    "maxUsd": <integer>,
    "creationFee": "<raw integer string>",
    "currencies": [
      {
        "address": "<address>",
        "symbol": "<symbol>",
        "decimals": <integer>,
        "priceSource": "chainlink" | "pinned" | "reference",
        "chainlinkProxy": "<address, the zero address when none>",
        "chainlinkDecimals": <integer, 0 when none>,
        "referenceUsdPrice": "<integer with 8 decimals, \"0\" = not filled>"
      }
    ]
  }
  ```

**Settled here:** the script prices each row by its `priceSource`: `pinned` is USD 1 (USDG); `chainlink` reads the proxy's `latestRoundData` and cross-checks `chainlinkDecimals` against the feed's own `decimals()`; `reference` takes `referenceUsdPrice` at 8 decimals, refuses `"0"` naming the symbol, and refuses a price outside USD 0.01 to USD 100,000 per token. It refuses a config whose `minUsd` is not below `maxUsd`, a row whose converted minimum exceeds its maximum, a row outside `1e8` to `1e36` raw units, a feed whose `updatedAt` lies in the future, and a row whose `decimals` differ from the token on chain. It reads the PoolManager and Permit2 addresses from `POOL_MANAGER` and `PERMIT2` when set, defaulting to the chain constants, so the address guard of spec 8.3 has an input to guard; `.env` already sets `PERMIT2` for the router script. `creationFee` is one raw amount applied to every row, `"0"` today, as spec 8.3 says. The file lives under `script/config/` because the one `fs_permissions` entry of spec 8.3 is `./script/config`.

- [ ] **Step 1: Write the failing script test and its mock**

`test/mocks/MockChainlinkAggregator.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice A Chainlink price feed with a settable answer and update time, for the deploy script's tests only.
contract MockChainlinkAggregator {
    uint8 public immutable decimals;
    int256 internal answer_;
    uint256 internal updatedAt_;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function set(int256 answer, uint256 updatedAt) external {
        answer_ = answer;
        updatedAt_ = updatedAt;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer_, updatedAt_, updatedAt_, 1);
    }
}
```

`test/unit/DeployLaunchpad.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployLaunchpad} from "../../script/DeployLaunchpad.s.sol";
import {MockChainlinkAggregator} from "../mocks/MockChainlinkAggregator.sol";

/// @notice The deploy script's pure parts (spec section 8.3): the canonical config shape, the three price sources
///         with every refusal, and the USD to raw-unit conversion. `run()` needs Robinhood Chain and is exercised by
///         Kobe's dry run on a fork.
contract DeployLaunchpadTest is Test {
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    DeployLaunchpad internal script;
    MockChainlinkAggregator internal feed;

    function setUp() public {
        vm.warp(1_790_000_000);
        script = new DeployLaunchpad();
        feed = new MockChainlinkAggregator(8);
        feed.set(250e8, block.timestamp - 1 hours);
    }

    /// @dev Exactly what the frontend generator writes, one row of each price source.
    function _generatorOutput() internal view returns (string memory) {
        return string.concat(
            '{"minUsd":5000,"maxUsd":10000000,"creationFee":"0","currencies":[',
            '{"address":"0x5fc5360d0400a0fd4f2af552add042d716f1d168","symbol":"USDG","decimals":6,',
            '"priceSource":"pinned","chainlinkProxy":"0x0000000000000000000000000000000000000000",',
            '"chainlinkDecimals":0,"referenceUsdPrice":"0"},',
            '{"address":"0xaf3d76f1834a1d425780943c99ea8a608f8a93f9","symbol":"AAPL","decimals":18,',
            '"priceSource":"chainlink","chainlinkProxy":"',
            vm.toString(address(feed)),
            '","chainlinkDecimals":8,"referenceUsdPrice":"0"},',
            '{"address":"0x05a3d1cd21d0c88145e82600e62e7e496e0f222b","symbol":"AMC","decimals":18,',
            '"priceSource":"reference","chainlinkProxy":"0x0000000000000000000000000000000000000000",',
            '"chainlinkDecimals":0,"referenceUsdPrice":"300000000"}]}'
        );
    }

    function test_parses_the_generator_output() public view {
        DeployLaunchpad.Config memory c = script.parseConfig(_generatorOutput());
        assertEq(c.minUsd, 5_000, "minUsd");
        assertEq(c.maxUsd, 10_000_000, "maxUsd");
        assertEq(c.creationFee, 0, "creationFee from its string");
        assertEq(c.rows.length, 3, "three rows");
        assertEq(c.rows[0].quote, USDG, "USDG address");
        assertEq(c.rows[0].decimals, 6, "USDG decimals");
        assertEq(c.rows[0].priceSource, "pinned", "USDG is pinned");
        assertEq(c.rows[0].chainlinkProxy, address(0), "the zero address means no proxy");
        assertEq(c.rows[1].symbol, "AAPL", "symbol");
        assertEq(c.rows[1].priceSource, "chainlink", "AAPL has a feed");
        assertEq(c.rows[1].chainlinkProxy, address(feed), "the proxy");
        assertEq(c.rows[1].chainlinkDecimals, 8, "the feed decimals");
        assertEq(c.rows[1].referenceUsdPrice, 0, "\"0\" reads as not filled");
        assertEq(c.rows[2].priceSource, "reference", "AMC is priced by reference");
        assertEq(c.rows[2].referenceUsdPrice, 3e8, "USD 3 as an 8-decimal integer");
    }

    /// @dev Reads through the one fs_permissions entry, so it also proves the permission.
    function test_the_example_config_in_script_config_parses() public view {
        DeployLaunchpad.Config memory c =
            script.parseConfig(vm.readFile("script/config/launch-currencies.example.json"));
        assertEq(c.rows.length, 3, "three example rows");
        assertEq(c.rows[0].priceSource, "pinned", "USDG pinned");
        assertEq(c.rows[1].chainlinkProxy, 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0, "AAPL's Chainlink proxy");
        assertEq(c.rows[2].referenceUsdPrice, 0, "AMC's reference price not filled yet");
    }

    function test_parseConfig_refuses_a_minUsd_not_below_maxUsd() public {
        vm.expectRevert(bytes("minUsd must be below maxUsd"));
        script.parseConfig('{"minUsd":5000,"maxUsd":5000,"creationFee":"0","currencies":[]}');
    }

    function test_priceOf_prices_each_source() public view {
        DeployLaunchpad.Config memory c = script.parseConfig(_generatorOutput());
        (uint256 answer, uint8 feedDecimals) = script.priceOf(c.rows[0]);
        assertEq(answer, 1, "pinned is USD 1");
        assertEq(feedDecimals, 0, "with no decimals");
        (answer, feedDecimals) = script.priceOf(c.rows[1]);
        assertEq(answer, 250e8, "the feed's answer");
        assertEq(feedDecimals, 8, "the feed's decimals");
        (answer, feedDecimals) = script.priceOf(c.rows[2]);
        assertEq(answer, 3e8, "the reference price");
        assertEq(feedDecimals, 8, "at 8 decimals");
    }

    function test_priceOf_refuses_a_bad_feed() public {
        DeployLaunchpad.Row memory row = script.parseConfig(_generatorOutput()).rows[1];
        feed.set(250e8, block.timestamp - 3 days - 1);
        vm.expectRevert(bytes("AAPL: the feed is older than 3 days"));
        script.priceOf(row);
        feed.set(250e8, block.timestamp + 1);
        vm.expectRevert(bytes("AAPL: the feed's updatedAt is in the future"));
        script.priceOf(row);
        feed.set(0, block.timestamp);
        vm.expectRevert(bytes("AAPL: the feed answer is not positive"));
        script.priceOf(row);
        feed.set(250e8, block.timestamp);
        row.chainlinkDecimals = 18;
        vm.expectRevert(bytes("AAPL: chainlinkDecimals differ from the feed's decimals()"));
        script.priceOf(row);
        row.chainlinkProxy = address(0);
        vm.expectRevert(bytes("AAPL: priceSource chainlink without a chainlinkProxy"));
        script.priceOf(row);
        row.priceSource = "oracle";
        vm.expectRevert(bytes("AAPL: unknown priceSource"));
        script.priceOf(row);
    }

    function test_priceOf_refuses_an_unfilled_or_implausible_reference_price() public {
        DeployLaunchpad.Row memory row = script.parseConfig(_generatorOutput()).rows[2];
        row.referenceUsdPrice = 0;
        vm.expectRevert(bytes("AMC: referenceUsdPrice is not filled in"));
        script.priceOf(row);
        row.referenceUsdPrice = 1e6 - 1;
        vm.expectRevert(bytes("AMC: referenceUsdPrice outside USD 0.01 to 100,000 per token"));
        script.priceOf(row);
        row.referenceUsdPrice = 1e13 + 1;
        vm.expectRevert(bytes("AMC: referenceUsdPrice outside USD 0.01 to 100,000 per token"));
        script.priceOf(row);
        row.referenceUsdPrice = 1e6;
        (uint256 answer,) = script.priceOf(row);
        assertEq(answer, 1e6, "USD 0.01 itself is accepted");
        row.referenceUsdPrice = 1e13;
        (answer,) = script.priceOf(row);
        assertEq(answer, 1e13, "USD 100,000 itself is accepted");
    }

    function test_bounds_convert_the_usd_range_to_raw_units_rounded_down() public view {
        (uint256 minValuation, uint256 maxValuation) = script.bounds(5_000, 10_000_000, 6, 1, 0);
        assertEq(minValuation, 5_000e6, "USDG minimum");
        assertEq(maxValuation, 10_000_000e6, "USDG maximum");
        (minValuation, maxValuation) = script.bounds(5_000, 10_000_000, 18, 250e8, 8);
        assertEq(minValuation, 20e18, "USD 5,000 of a USD 250 stock is 20 tokens");
        assertEq(maxValuation, 40_000e18, "USD 10,000,000 is 40,000 tokens");
        (minValuation,) = script.bounds(5_000, 10_000_000, 18, 3e8, 8);
        assertEq(minValuation, 1_666_666_666_666_666_666_666, "rounded down");
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `forge test --match-path 'test/unit/DeployLaunchpad.t.sol'`
Expected: compilation fails with `Source "../../script/DeployLaunchpad.s.sol" not found`.

- [ ] **Step 3: Allow the script to read its config**

In `foundry.toml`, replace the two lines

```toml
# No file-system access for tests or scripts: nothing here reads or writes files.
fs_permissions = []
```

with

```toml
# One read-only permission: the launchpad deploy script reads its per-currency config (spec section 8.3).
# Nothing reads anything else, and nothing writes.
fs_permissions = [{ access = "read", path = "./script/config" }]
```

- [ ] **Step 4: Write the script and the example config**

`script/DeployLaunchpad.s.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {SVLaunchpad} from "../src/SVLaunchpad.sol";

/// @notice The two Chainlink reads the script makes; the proxies on Robinhood Chain answer both.
interface IChainlinkFeed {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Deploys SVLaunchpad on Robinhood Chain and allows every currency of
///         script/config/launch-currencies.json with its USD bounds converted to raw units (spec section 8.3).
/// @dev Not run before Kobe's review. The deployer key is never in the environment: pass it to forge with
///      --account, --ledger or --interactive. Dry run first on a local anvil fork of chain 4663, then:
///
///        forge script script/DeployLaunchpad.s.sol --rpc-url robinhood --account <name> --broadcast
///
///      The broadcaster deploys with itself as owner, allows every currency, then hands ownership to OWNER, who
///      must call acceptOwnership (Ownable2Step). The script refuses any chain but 4663 and a PoolManager or
///      Permit2 other than the chain's unless ALLOW_OTHER_ADDRESSES=true is set on purpose. Every row is priced
///      and checked before anything is broadcast.
contract DeployLaunchpad is Script {
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    address internal constant ROBINHOOD_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    string internal constant CONFIG_PATH = "script/config/launch-currencies.json";
    /// @dev The app's own staleness window for Chainlink prices.
    uint256 internal constant MAX_FEED_AGE = 3 days;
    uint8 internal constant REFERENCE_DECIMALS = 8;
    /// @dev USD 0.01 and USD 100,000 per token at 8 decimals: a reference price outside is a typo.
    uint256 internal constant MIN_REFERENCE_PRICE = 1e6;
    uint256 internal constant MAX_REFERENCE_PRICE = 1e13;
    /// @dev SVLaunchpad's internal MIN_VALUATION and MAX_VALUATION (spec section 4.3).
    uint256 internal constant MIN_VALUATION = 1e8;
    uint256 internal constant MAX_VALUATION = 1e36;

    /// @notice One currency of the config.
    struct Row {
        address quote;
        string symbol;
        uint8 decimals;
        string priceSource; // "chainlink", "pinned" or "reference"
        address chainlinkProxy; // the zero address when none
        uint8 chainlinkDecimals; // 0 when none
        uint256 referenceUsdPrice; // 8 decimals; 0 when not filled
    }

    /// @notice The whole config.
    struct Config {
        uint256 minUsd;
        uint256 maxUsd;
        uint256 creationFee;
        Row[] rows;
    }

    function run() external returns (SVLaunchpad launchpad) {
        address owner = vm.envAddress("OWNER");
        address feeWallet = vm.envAddress("FEE_WALLET");
        address launcherGate = vm.envAddress("LAUNCHER_GATE");
        address poolManager = vm.envOr("POOL_MANAGER", ROBINHOOD_POOL_MANAGER);
        address permit2 = vm.envOr("PERMIT2", CANONICAL_PERMIT2);

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
        require(poolManager.code.length != 0, "POOL_MANAGER has no code on this chain");
        require(permit2.code.length != 0, "PERMIT2 has no code on this chain");
        if (launcherGate != address(0)) require(launcherGate.code.length != 0, "LAUNCHER_GATE has no code");

        Config memory config = parseConfig(vm.readFile(CONFIG_PATH));
        (uint256[] memory mins, uint256[] memory maxs) = _allBounds(config);

        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();
        launchpad = new SVLaunchpad(
            IPoolManager(poolManager), ISignatureTransfer(permit2), broadcaster, feeWallet, launcherGate
        );
        for (uint256 i = 0; i < config.rows.length; i++) {
            launchpad.setCurrency(config.rows[i].quote, mins[i], maxs[i], config.creationFee);
        }
        if (owner != broadcaster) launchpad.transferOwnership(owner);
        vm.stopBroadcast();

        _print(launchpad, config, mins, maxs, owner);
    }

    /// @notice The canonical config written by the frontend's generator.
    function parseConfig(string memory json) public view returns (Config memory c) {
        c.minUsd = vm.parseJsonUint(json, ".minUsd");
        c.maxUsd = vm.parseJsonUint(json, ".maxUsd");
        require(c.minUsd < c.maxUsd, "minUsd must be below maxUsd");
        c.creationFee = vm.parseUint(vm.parseJsonString(json, ".creationFee"));
        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".currencies[", vm.toString(n), "]"))) {
            n++;
        }
        c.rows = new Row[](n);
        for (uint256 i = 0; i < n; i++) {
            c.rows[i] = _parseRow(json, string.concat(".currencies[", vm.toString(i), "]"));
        }
    }

    /// @notice A row's USD price per whole token as an integer `answer` with `feedDecimals` decimals.
    function priceOf(Row memory row) public view returns (uint256 answer, uint8 feedDecimals) {
        bytes32 source = keccak256(bytes(row.priceSource));
        if (source == keccak256("pinned")) return (1, 0);
        if (source == keccak256("chainlink")) {
            require(
                row.chainlinkProxy != address(0),
                string.concat(row.symbol, ": priceSource chainlink without a chainlinkProxy")
            );
            IChainlinkFeed feed = IChainlinkFeed(row.chainlinkProxy);
            require(
                feed.decimals() == row.chainlinkDecimals,
                string.concat(row.symbol, ": chainlinkDecimals differ from the feed's decimals()")
            );
            (, int256 a,, uint256 updatedAt,) = feed.latestRoundData();
            require(a > 0, string.concat(row.symbol, ": the feed answer is not positive"));
            require(updatedAt <= block.timestamp, string.concat(row.symbol, ": the feed's updatedAt is in the future"));
            require(
                block.timestamp - updatedAt <= MAX_FEED_AGE, string.concat(row.symbol, ": the feed is older than 3 days")
            );
            // `a` was checked positive just above, so the cast to uint256 is exact.
            // forge-lint: disable-next-line(unsafe-typecast)
            return (uint256(a), row.chainlinkDecimals);
        }
        if (source == keccak256("reference")) {
            require(row.referenceUsdPrice > 0, string.concat(row.symbol, ": referenceUsdPrice is not filled in"));
            require(
                row.referenceUsdPrice >= MIN_REFERENCE_PRICE && row.referenceUsdPrice <= MAX_REFERENCE_PRICE,
                string.concat(row.symbol, ": referenceUsdPrice outside USD 0.01 to 100,000 per token")
            );
            return (row.referenceUsdPrice, REFERENCE_DECIMALS);
        }
        revert(string.concat(row.symbol, ": unknown priceSource"));
    }

    /// @notice Spec section 8.3, in integers, rounded down:
    ///         `bound = usd * 10^quoteDecimals * 10^feedDecimals / answer`.
    function bounds(uint256 minUsd, uint256 maxUsd, uint8 quoteDecimals, uint256 answer, uint8 feedDecimals)
        public
        pure
        returns (uint256 minValuation, uint256 maxValuation)
    {
        uint256 scale = 10 ** (uint256(quoteDecimals) + feedDecimals);
        minValuation = minUsd * scale / answer;
        maxValuation = maxUsd * scale / answer;
    }

    function _parseRow(string memory json, string memory at) internal pure returns (Row memory row) {
        row.quote = vm.parseJsonAddress(json, string.concat(at, ".address"));
        row.symbol = vm.parseJsonString(json, string.concat(at, ".symbol"));
        // ERC-20 and Chainlink decimals fit uint8 by definition; the script checks both against the chain.
        // forge-lint: disable-next-line(unsafe-typecast)
        row.decimals = uint8(vm.parseJsonUint(json, string.concat(at, ".decimals")));
        row.priceSource = vm.parseJsonString(json, string.concat(at, ".priceSource"));
        row.chainlinkProxy = vm.parseJsonAddress(json, string.concat(at, ".chainlinkProxy"));
        // forge-lint: disable-next-line(unsafe-typecast)
        row.chainlinkDecimals = uint8(vm.parseJsonUint(json, string.concat(at, ".chainlinkDecimals")));
        row.referenceUsdPrice = vm.parseUint(vm.parseJsonString(json, string.concat(at, ".referenceUsdPrice")));
    }

    /// @dev Every row priced, converted and checked before anything is broadcast, so a bad row stops the run
    ///      with nothing deployed.
    function _allBounds(Config memory config) internal view returns (uint256[] memory mins, uint256[] memory maxs) {
        mins = new uint256[](config.rows.length);
        maxs = new uint256[](config.rows.length);
        for (uint256 i = 0; i < config.rows.length; i++) {
            Row memory row = config.rows[i];
            require(
                IERC20Metadata(row.quote).decimals() == row.decimals,
                string.concat(row.symbol, ": decimals differ from the token on chain")
            );
            (uint256 answer, uint8 feedDecimals) = priceOf(row);
            (mins[i], maxs[i]) = bounds(config.minUsd, config.maxUsd, row.decimals, answer, feedDecimals);
            require(mins[i] <= maxs[i], string.concat(row.symbol, ": converted minimum above the maximum"));
            require(
                mins[i] >= MIN_VALUATION && maxs[i] <= MAX_VALUATION,
                string.concat(row.symbol, ": bounds outside 1e8 to 1e36 raw units")
            );
        }
    }

    function _print(
        SVLaunchpad launchpad,
        Config memory config,
        uint256[] memory mins,
        uint256[] memory maxs,
        address owner
    ) internal view {
        console.log("SVLaunchpad deployed at:", address(launchpad));
        for (uint256 i = 0; i < config.rows.length; i++) {
            (uint256 answer, uint8 feedDecimals) = priceOf(config.rows[i]);
            uint256 scale = 10 ** (uint256(config.rows[i].decimals) + feedDecimals);
            console.log(config.rows[i].symbol, config.rows[i].priceSource);
            console.log("  USD per token", answer, "with decimals", feedDecimals);
            console.log("  min raw", mins[i], "USD", mins[i] * answer / scale);
            console.log("  max raw", maxs[i], "USD", maxs[i] * answer / scale);
        }
        console.log("  owner now:      ", launchpad.owner());
        console.log("  pending owner:  ", launchpad.pendingOwner());
        console.log("  intended owner: ", owner);
        console.log("  fee wallet:     ", launchpad.feeWallet());
        console.log("  router fee bps: ", launchpad.routerFeeBps());
        console.log("  creator share:  ", launchpad.creatorShareBps());
        console.log("  first-buy cap:  ", launchpad.firstBuyCapBps());
        console.log("  daily limit:    ", launchpad.dailyLaunchLimit());
        console.log("  launcher gate:  ", launchpad.launcherGate());
        console.log("  hook:           ", launchpad.hook());
        console.log("  creation fee:   ", config.creationFee);
        console.log("  currencies:     ", config.rows.length);
    }
}
```

`script/config/launch-currencies.example.json` (the canonical schema with one row of each price source; the file the script reads, `launch-currencies.json`, is written by the frontend generator and filled by Kobe):

```json
{
  "minUsd": 5000,
  "maxUsd": 10000000,
  "creationFee": "0",
  "currencies": [
    {
      "address": "0x5fc5360d0400a0fd4f2af552add042d716f1d168",
      "symbol": "USDG",
      "decimals": 6,
      "priceSource": "pinned",
      "chainlinkProxy": "0x0000000000000000000000000000000000000000",
      "chainlinkDecimals": 0,
      "referenceUsdPrice": "0"
    },
    {
      "address": "0xaf3d76f1834a1d425780943c99ea8a608f8a93f9",
      "symbol": "AAPL",
      "decimals": 18,
      "priceSource": "chainlink",
      "chainlinkProxy": "0x6b22a786baa607d76728168703a39ea9c99f2cd0",
      "chainlinkDecimals": 8,
      "referenceUsdPrice": "0"
    },
    {
      "address": "0x05a3d1cd21d0c88145e82600e62e7e496e0f222b",
      "symbol": "AMC",
      "decimals": 18,
      "priceSource": "reference",
      "chainlinkProxy": "0x0000000000000000000000000000000000000000",
      "chainlinkDecimals": 0,
      "referenceUsdPrice": "0"
    }
  ]
}
```

- [ ] **Step 5: Run the script test to verify it passes**

Run: `forge fmt && forge test --match-path 'test/unit/DeployLaunchpad.t.sol' -vv`
Expected: `7 passed, 0 failed`. If forge refuses to read `creationFee` or `referenceUsdPrice` as a string because it infers another type from the content, stop and report the exact forge error to the controller: the schema is shared with the frontend generator and stays as written, so the fix belongs in `parseConfig` and `_parseRow` alone.

- [ ] **Step 6: README and `.env.example`**

In `README.md`, change the first line from `# SVRouter` to `# SuitVentures contracts: SVRouter and SVLaunchpad`, and insert this section directly before `## Layout`. The five angle-bracket cells of its table are measurements this plan cannot know in advance: replace each with the figure the named step printed, which the Task 3 and Task 5 reports carry; none may be committed in angle brackets.

~~~markdown
## SVLaunchpad

The MaxLong Markets instant launchpad. One transaction, signed by a holder of the Suits NFT, deploys a token of
one billion supply with no owner, opens its Uniswap v4 pool at the valuation the creator picks, and places the
whole supply in one position from that price to the end of the price range. The launchpad owns the position and
has no code that can take liquidity out of it. The creator may buy first with their own money, up to 20 % of the
supply. Anyone can collect the trading fees: 70 % go to the launch's payout address and 30 % to the fee wallet.
A share the currency refuses to deliver waits in the contract until its owner claims it.

- Spec (binding): frontend repo, `docs/superpowers/specs/2026-09-28-instant-launchpad-design.md`, sections 3 and 4
- Plan: [`docs/superpowers/plans/2026-09-29-instant-launchpad-contracts.md`](docs/superpowers/plans/2026-09-29-instant-launchpad-contracts.md)

**How to review.** Read the spec's sections 3 and 4, then `src/interfaces/ISVLaunchpad.sol`, then
`src/SVLaunchpad.sol` from `launch` down; the step numbers in its comments are the spec's. Then the tests in this
order: `SVLaunchpad.launch.t.sol`, `SVLaunchpad.fees.t.sol`, `SVLaunchpad.invariant.t.sol`,
`SVLaunchpad.fuzz.t.sol`, `test/fork/SVLaunchpadFork.t.sol`.

**Run it yourself:**

```sh
forge build --sizes --skip test --skip script
forge test --no-match-path 'test/fork/*'
FOUNDRY_PROFILE=coverage forge coverage --report summary --no-match-path 'test/fork/*'
ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-path 'test/fork/SVLaunchpadFork.t.sol' -vv
```

The size check skips tests and scripts because the PoolManager the tests deploy is larger than the limit. The
coverage profile clears the per-file compiler setting, which coverage builds cannot use.

| Fact | Value |
|---|---|
| `SVLaunchpad` runtime size at 1,000,000 optimizer runs | <bytes, Task 3 Step 7> |
| `SVLaunchpad` runtime size as built | <bytes and optimizer runs, Task 3 Step 7> |
| Gas of a launch with a first buy | <gas, Task 3 Step 6 log> |
| Deployed pool protocol fee at the fork block | <value and block, Task 5 Step 5 log> |
| PoolManager protocol fee controller | <address, Task 5 Step 5 log> |

**Currencies.** The deploy script reads `script/config/launch-currencies.json`. The frontend script
`scripts/launch/currency-config.mts` writes it from `quotes.json`; `script/config/launch-currencies.example.json`
shows the shape. Each row names its `priceSource`:

| priceSource | Price used | Refused when |
|---|---|---|
| `pinned` | USD 1, for USDG | never |
| `chainlink` | the proxy's latest answer | older than 3 days, dated in the future, not above zero, or `chainlinkDecimals` not the feed's |
| `reference` | `referenceUsdPrice`, an integer with 8 decimals: `"2500000000"` is USD 25 | `"0"`, that is not filled in, or outside USD 0.01 to 100,000 per token |

Fill `referenceUsdPrice` on every `reference` row before deploying; the script names each row it refuses. Bounds
are `minUsd` and `maxUsd` converted to raw units at that price, rounded down, and must lie between `1e8` and
`1e36` raw units. The printout shows each row's price per token with its decimals, its raw bounds and their USD
value, then the settings read back.

`creationFee` is one raw amount applied to every currency. It is `"0"` today. Once it is not zero it means very
different money in different currencies: `"1000000"` is USD 1 of USDG, which has 6 decimals, but a millionth of a
millionth of a token in an 18-decimal stock. A non-zero creation fee therefore needs a value per currency, set
with `setCurrency`, not this single field.

**Deploy, after Kobe's review.** Dry run against a local anvil fork of chain 4663, then:

```sh
forge script script/DeployLaunchpad.s.sol --rpc-url robinhood --account <keystore name> --broadcast
```

The broadcaster deploys with itself as owner, allows every currency, then transfers ownership to `OWNER`. When
`OWNER` is another key, it must call `acceptOwnership`. Verify through Sourcify with the constructor arguments
PoolManager, Permit2, the broadcaster, `FEE_WALLET` and `LAUNCHER_GATE`, and with the optimizer runs the launch
profile in `foundry.toml` sets:

```sh
forge verify-contract <address> src/SVLaunchpad.sol:SVLaunchpad --chain-id 4663 --verifier sourcify \
  --optimizer-runs <runs from foundry.toml> \
  --constructor-args "$(cast abi-encode 'constructor(address,address,address,address,address)' \
    0x8366a39CC670B4001A1121B8F6A443A643e40951 0x000000000022D473030F116dDEE9F6B43aC78BA3 \
    <broadcaster> "$FEE_WALLET" "$LAUNCHER_GATE")"
```
~~~

In the `## Layout` table add these rows after the `src/interfaces/ISVRouter.sol` row:

```markdown
| `src/SVLaunchpad.sol` | the instant launchpad |
| `src/SVLaunchToken.sol` | the token every launch deploys |
| `src/interfaces/ISVLaunchpad.sol` | the launchpad's structs, events, errors, external functions (spec section 4.2) |
| `script/DeployLaunchpad.s.sol` | deploys the launchpad and allows the config's currencies; not run before review |
| `script/config/` | the launchpad's currency config; the only path any script may read |
```

In the `## Environment variables` table add these rows after the `ALLOW_OTHER_ADDRESSES` row:

```markdown
| `LAUNCHER_GATE` | launchpad deploy script | the ERC-721 whose holders may launch: the Suits NFT; zero lets anyone launch |
| `POOL_MANAGER` | launchpad deploy script | optional; `0x8366a39CC670B4001A1121B8F6A443A643e40951` when unset |
```

Append to `.env.example`:

```
# Inputs of script/DeployLaunchpad.s.sol, in addition to OWNER, FEE_WALLET, PERMIT2 and ALLOW_OTHER_ADDRESSES
# above. The ERC-721 whose holders may launch: the Suits NFT on Robinhood Chain. Zero lets anyone launch.
LAUNCHER_GATE=0x05C2174aa494BBDf72AEeab0cA3C10216D33B297
# Optional. The Uniswap v4 PoolManager; unset means the chain's. The script refuses another address unless
# ALLOW_OTHER_ADDRESSES=true.
# POOL_MANAGER=0x8366a39CC670B4001A1121B8F6A443A643e40951
```

- [ ] **Step 7: Gates**

Run gates 1 to 5 of Global Constraints. Expected: all green; `script/DeployLaunchpad.s.sol` appears in the coverage table below 100 %, like `script/Deploy.s.sol`, and is outside the `src/` bar. `test_the_example_config_in_script_config_parses` passing is the proof that the one `fs_permissions` entry works.

- [ ] **Step 8: Commit**

```bash
git add script/DeployLaunchpad.s.sol script/config/launch-currencies.example.json test/mocks/MockChainlinkAggregator.sol test/unit/DeployLaunchpad.t.sol foundry.toml README.md .env.example
git commit -m "DeployLaunchpad: chain and address guards, currency config priced by source, USD to raw bounds, ownership handover, README

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016RxWfZk26aLfhGaoXcrYLf"
```

---


## After Kobe's review

Kobe does every step below himself; no agent deploys, broadcasts or reads `.env`.

1. Review the branch `feat/instant-launchpad` task by task against the spec, and merge it into `main` when satisfied.
2. Generate `script/config/launch-currencies.json` with the frontend's `scripts/launch/currency-config.mts`, fill the `referenceUsdPrice` of every `reference` row (29 today), confirm the DEFAULT bounds of USD 5,000 and USD 10,000,000 with MAXLONG, and commit the file (spec section 9 step 1).
3. Dry run against a local anvil fork of chain 4663 and read the printed bounds and settings (spec section 9 step 2): `anvil --fork-url "$ROBINHOOD_RPC_URL"` in one terminal, then `forge script script/DeployLaunchpad.s.sol --rpc-url http://127.0.0.1:8545 --account <keystore name> --broadcast`.
4. Deploy with `--rpc-url robinhood --broadcast` from the owner key, `LAUNCHER_GATE` the Suits NFT, verify through Sourcify, and record the address and block in this README and the workspace README (spec section 9 step 3).
5. From `OWNER`, call `acceptOwnership` if the deployer was another key, and read the settings back: owner `OWNER`, router fee 50, creator share 7,000, first-buy cap 2,000, daily limit 5, hook zero, gate the Suits NFT, 54 currencies (spec section 9 step 4).
6. Hand the address to the frontend as `NEXT_PUBLIC_LAUNCHPAD_ADDRESS` and continue with spec section 9 steps 5 to 8: the migration, the Vercel settings, the rehearsal launches, and ownership and fee wallet to MAXLONG's Safe at handover.
