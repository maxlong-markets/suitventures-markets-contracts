# Security review: SVRouter, SVLaunchpad, SVLaunchToken

This is the developer's own review of the contracts in this repository, written up on 27 Oct 2026. It is
not an external audit. Both contracts are deployed and immutable, so nothing in `src/` was changed by this review.
Every finding that would need a source change is written up with a recommendation instead.

| Contract | Address on Robinhood Chain (4663) | Deployed |
|---|---|---|
| `SVRouter` | [`0xc9E6b76aA834e746080b1F8Ad6943930eD5147a9`](https://robinhoodchain.blockscout.com/address/0xc9E6b76aA834e746080b1F8Ad6943930eD5147a9) | 18 Sep 2026, `feeBps` 50, `holderFeeBps` 0 |
| `SVLaunchpad` | [`0x7885AFbda28F5a4d5c6Cc4230975c983d6c7aA0d`](https://robinhoodchain.blockscout.com/address/0x7885AFbda28F5a4d5c6Cc4230975c983d6c7aA0d) | 29 Sep 2026 |
| `SVLaunchToken` | one per launch, deployed by the launchpad with CREATE2 | per launch |

## 1. Scope

**Read, line by line:** `src/SVRouter.sol` (298 lines), `src/SVLaunchpad.sol` (842), `src/SVLaunchToken.sol` (25),
`src/interfaces/ISVRouter.sol`, `src/interfaces/ISVLaunchpad.sol`, `script/Deploy.s.sol`,
`script/DeployLaunchpad.s.sol`, `script/config/`, `foundry.toml`, `remappings.txt`, `.gitmodules` and the submodule
pins. These were checked against the binding specs: [`docs/superpowers/specs/2026-09-17-svrouter-design.md`](docs/superpowers/specs/2026-09-17-svrouter-design.md)
and sections 3 and 4 of the instant-launchpad design in the frontend repo
([`docs/superpowers/specs/2026-09-28-instant-launchpad-design.md`](https://github.com/maxlong-markets/suitventures-markets-frontend/blob/main/docs/superpowers/specs/2026-09-28-instant-launchpad-design.md)).

**Ran (27 Oct 2026, forge 1.4.0-nightly, solc 0.8.26, Cancun):**

| Command | Result |
|---|---|
| `forge build --sizes --skip test --skip script` | clean. Runtime sizes: `SVLaunchpad` 24,289 bytes (287 under EIP-170's 24,576), `SVRouter` 7,647, `SVLaunchToken` 1,969 |
| `forge test --no-match-path 'test/fork/*'` | 183 passed, 0 failed, 0 skipped, in 12 suites. Fuzz at 256 runs; the two invariants at 64 runs x 256 depth (16,384 calls each) |
| `FOUNDRY_PROFILE=coverage forge coverage --report summary --no-match-path 'test/fork/*'` | 100 % lines, statements, branches and functions on `src/SVRouter.sol` (71/71, 87/87, 11/11, 10/10), `src/SVLaunchpad.sol` (298/298, 376/376, 50/50, 46/46) and `src/SVLaunchToken.sol` |
| `forge fmt --check` | clean |
| `forge lint src script` | no findings (the only lint warnings in the repo are unchecked `transfer` calls inside a test that exercises a deliberately quirky mock token) |
| the three commands above, again in a fresh clone with no `.env` | same results, so CI does not depend on local state |
| grep of every tracked file for keys, secrets and RPC credentials | none. `.env` is git-ignored; `.env.example` holds placeholders only |

**Not run:** the 11 fork tests (`test/fork/`). They need a Robinhood Chain RPC and passed at the time each
contract was built (SVRouter 9/9 at block 65,241,000, 17 Sep 2026; SVLaunchpad 2/2 at block 75,238,414,
29 Sep 2026). The deployed bytecode was not compared with a local build in this review.

## 2. Threat model

**Assets.** The user's input tokens during a swap. The output a user is owed. The router fee. The launched
token's whole supply, locked in a launchpad-owned Uniswap v4 position. The trading fees that position earns,
split between the launch's payout address and the fee wallet. Credited `owed` balances waiting to be claimed.

**Actors.**

| Actor | Can | Trusted for |
|---|---|---|
| User / trader | call `swapExactIn` with any pool key, any tokens, any `hookData` | nothing; the router protects them with their own minimum |
| Creator | call `launch` when the launcher gate allows them; pick name, symbol, quote, valuation, first buy, payout, salt | nothing |
| Payout address | move its own payout with `setPayout`, `claim` its credited shares | nothing |
| Anyone | call `collectFees` for any launch, initialise any v4 pool key, send tokens to either contract | nothing |
| Owner (Ownable2Step) | set fees within hard caps, the fee wallet, the Suits NFT, the launcher gate, the hook, the currency allowlist and its bounds, `sweep` on the router | not to harm users; this is the main trust assumption. At review time the owner of both contracts is the developer's EOA; the transfer to the client's wallet is the pending handoff step |
| Fee wallet | receive fees | to accept the tokens it is sent |
| Hostile token, quote, hook or NFT | revert, burn gas, return junk, re-enter, charge transfer fees, rebase | nothing. A quote reaches the launchpad only through the owner's allowlist; a hook only through `setHook`; the NFT only through `setSuitsNft` or `setLauncherGate` |
| Bot / front-runner | watch for a launch and act before it lands; buy in the block after a launch | nothing. Robinhood Chain's sequencer does not publish pending transactions |

**Trust boundaries.** Permit2 (canonical, `0x000000000022D473030F116dDEE9F6B43aC78BA3`) enforces signatures, nonces
and permit deadlines. The Universal Router (`0x06AfBA43…bf99`, fingerprinted as the 2.1.1 build) and the v4
PoolManager (`0x8366a39C…0951`) are trusted to behave as their released sources do. Both are immutables in the
contracts and are checked against constants in the deploy scripts. Everything else is untrusted.

## 3. Controls in place

### SVRouter

| Control | Where | What it prevents |
|---|---|---|
| `nonReentrant` on the only state-changing user entry point | `swapExactIn`, `SVRouter.sol:122-126` | re-entry from the input or output token, the pool's hook or the NFT during a trade |
| Deadline and non-zero amount checked before anything moves | `:128-129` | stale trades; a zero swap |
| The permit must name the input token and cover `amountIn`; Permit2 is called with `owner = msg.sender` | `:135-141` | using a permit for another token; anyone but the signer redeeming a signature (no relayer path exists) |
| Signature transfer, exact `requestedAmount`, no allowance ever granted | `:136-141`, `:152-153` | lingering approvals: a permit for more than `amountIn` moves only `amountIn` and the nonce is spent |
| Fee hard cap `MAX_FEE_BPS = 50` (0.5 %), the holder rate never above the regular rate | `:41`, `setFees` `:208-213` | an owner charging more than 0.5 % |
| Fee rounds down; a zero fee is not transferred | `feeFor` `:190`, `:152` | the user overpaying by a unit; tokens that revert on zero-value transfers blocking small trades |
| `SETTLE` pays exactly `net` with `payerIsUser = false`, not the open delta | `_executeSwap` `:283` | a partial fill (liquidity exhausted, or an input-side hook delta) leaving input inside the Universal Router where anyone could sweep it: the PoolManager rejects the unlock with `CurrencyNotSettled` and the whole call reverts |
| `TAKE` sends the whole output credit straight to the user | `:284` | the router holding output, and per-wallet caps on the bought token tripping on an intermediary |
| Command and action bytes come from the pinned `universal-router` and `v4-periphery` libraries | `:267-270` | a hand-written encoding drifting from the deployed router |
| Output measured as the user's balance delta, checked against `amountOutMin` | `:157`, `:162-163` | a hook fee or a fee-on-transfer output token silently reducing what arrives below the minimum |
| Holder check is a raw `staticcall` with a 100,000-gas allowance and a strict one-word reply | `:48`, `:185-187` | a codeless, reverting, short-reply or gas-burning NFT blocking trades; it can only cost the holder rate |
| Fee-on-transfer and rebasing input tokens fail closed | `:151-153` | the router funding a trade with less than `amountIn`: the transfers of `fee + net` exceed what arrived and revert |
| Universal Router and Permit2 are immutables, non-zero at construction | `:55`, `:58`, `:88-93` | an owner redirecting trades to another router |
| `Ownable2Step`; `renounceOwnership` reverts; `sweep` and `setFeeWallet` refuse the zero address | `:33`, `:237-239`, `:229-233`, `:199-203` | a mistyped owner transfer; an ownerless router; burning a sweep or the fee |

### SVLaunchpad and SVLaunchToken

| Control | Where | What it prevents |
|---|---|---|
| `nonReentrant` on `launch`, `collectFees`, `claim` | `SVLaunchpad.sol:228`, `:466`, `:488` | re-entry from a quote token, the hook or a payout address |
| `unlockCallback` accepts only the PoolManager and only while the launchpad's own unlock is in flight (transient flag at an ERC-7201 slot) | `:272-274`, `_unlock` `:325-329` | anyone, including the PoolManager on someone else's unlock, reaching the position code |
| Every cheap check before any transfer; the payment before the deployment | `launch` `:230-252` | wasted deployment gas; partial state on a failed check |
| The pull is measured: the balance must rise by exactly `firstBuy + creationFee` | `_pull` `:314-321` | a fee-on-transfer quote paying part of a launch out of other people's credited `owed` balances |
| CREATE2 salt is `keccak256(creator, salt)` | `:254`, `_salt` `:830-834` | anyone landing a token at another creator's predicted address |
| The position is owned by the launchpad and no code path decreases its liquidity: the only two `modifyLiquidity` calls add the supply once and poke with a zero delta | `:354-363`, `:516-522`; `invariant_the_position_liquidity_never_changes_after_launch` | withdrawal of the locked supply by anyone, the owner included |
| The quote side of the mint is never settled, and the first buy settles exactly `net` | `:345-349`, `:376` | a mint that charges quote, or a partial first buy passing silently: either ends in `CurrencyNotSettled` |
| The first buy is atomic with pool creation, capped at `firstBuyCapBps` of supply and floored by the creator's `minFirstBuyTokens` | `_launchCallback` `:369-372` | a sandwich between initialisation and the first buy; an outsized creator allocation; a first buy worse than the form previewed |
| Dust the pool did not take is burned in the same transaction | `:417-418` | the launchpad holding any of the launched token |
| `SVLaunchToken` has no owner, no mint after construction, no pause, no blocklist, no fee, no hooks | `SVLaunchToken.sol:14-25` | an issuer-side rug through the token itself |
| Collected fees are measured on arrival; the split uses the share fixed at launch; the fee wallet takes the rounding dust | `_takeMeasured` `:532-539`, `:473-480`, `:424` | a fee-on-transfer quote over-paying out of `owed`; the owner changing the share of existing launches |
| Each share is delivered by a tolerant low-level transfer; a refused share is credited to `owed` and claimable to any address | `_deliver` `:544-552`, `claim` `:488-495` | a blocklisted payout freezing the fee wallet's share, a hostile fee wallet freezing creators, a recipient the token refuses losing its share. `invariant_the_launchpad_holds_exactly_the_owed_balances` checks the accounting |
| Only the current payout can move the payout; zero, the launchpad and the PoolManager are refused | `setPayout` `:500-509`, `_checkPayout` `:824-826` | a creator's stale key, or a mistake, redirecting fees to an address that could never spend them |
| `setHook` refuses a codeless hook, one v4 rejects for a static fee, both remove-liquidity flags and all four returns-delta flags | `:78-81`, `:612-621` | a hook that freezes `collectFees` (the poke is a zero-delta remove) or skims the mint, the collection or any trade, the first buy included |
| Currency bounds live inside `[1e8, 1e36]` raw units | `setCurrency` `:628-644`, `:62-64` | a launch failing on price or liquidity arithmetic in either currency order |
| Router fee on the first buy capped at 0.5 %, as SVRouter's | `:60`, `setRouterFee` `:570-574` | an owner over-charging the first buy |
| Launcher gate fails closed with a 100,000-gas raw `staticcall`; zero gate means open | `isAllowedLauncher` `:687-693` | a broken gate letting everyone launch |
| Per-wallet daily launch limit; name, symbol and URI length bounds | `_countLaunch` `:284-292`, `_checkText` `:295-301` | spam from one wallet; oversized strings in events and storage |
| `Ownable2Step`; `renounceOwnership` reverts; no `sweep` | `:39`, `:648-650` | an ownerless launchpad; any owner-controlled transfer out of the launchpad |

### Deploy scripts and configuration

| Control | Where | What it prevents |
|---|---|---|
| Refuse any chain but 4663 | `Deploy.s.sol:28`, `DeployLaunchpad.s.sol:74` | broadcasting to the wrong network |
| Universal Router, PoolManager and Permit2 must equal the chain's constants unless `ALLOW_OTHER_ADDRESSES=true`; each must have code | `Deploy.s.sol:29-40`, `DeployLaunchpad.s.sol:77-88` | a mistyped or malicious counterparty address |
| Zero `OWNER` refused (the `.env.example` placeholder) | `DeployLaunchpad.s.sol:76`; `SVRouter` constructor `_nonZero` `:89` | the broadcaster staying owner, or an ownerless deploy |
| Every currency row is priced and checked before anything is broadcast: on-chain decimals, Chainlink staleness (3 days), future timestamps, non-positive answers, reference-price plausibility (USD 0.01 to 100,000), duplicates, bounds inside `[1e8, 1e36]` | `DeployLaunchpad.s.sol:93`, `:110-227` | a half-configured launchpad or a typo in a bound |
| The deployer key never sits in the environment (`--account`, `--ledger`, `--interactive`) | both scripts' NatSpec; `.env.example` | a key leaking through `.env` or shell history |
| One read-only filesystem permission, `./script/config` | `foundry.toml` `fs_permissions` | scripts or tests reading anything else (including `.env` through cheatcodes) |
| Dependencies are git submodules pinned by commit; `auto_detect_remappings = false` | `.gitmodules`, `foundry.lock`, `remappings.txt` | an unpinned dependency, or two copies of a Uniswap type resolving differently |

## 4. Findings

Severity follows the usual scale: Critical (funds can be taken), High (funds can be frozen or taken under
realistic conditions), Medium (a trusted party can harm users, or users can be harmed under narrow conditions),
Low (a limited or self-inflicted harm), Informational (no harm; noted so a reader can see it was considered).
No Critical or High issue was found.

| ID | Severity | Title | Where | What could go wrong | Status |
|---|---|---|---|---|---|
| SV-01 | Medium | Owner is a single EOA with live launch-time powers | both contracts, owner setters; `SVLaunchpad.setHook` `:612`, `setCurrency` `:628` | A compromised owner key cannot touch locked positions, `owed` balances or users' funds beyond the capped fee. It can set a hook (within the flag filter) for future launches, such as a `beforeSwap` hook that reverts sells, which would make new pools one-way. It can also allowlist a hostile quote, redirect the fee wallet, or set the launcher gate to zero. Existing launches keep the hook in their pool key and are unaffected | Open. Complete the pending Ownable2Step transfer to the client's multisig, and put `setHook` and `setCurrency` behind a timelock in any future version. Mitigations live today: the frontend refuses to launch while `hook()` is not zero, and the hook is in every pool key, so it is visible |
| SV-02 | Low | Launch front-run griefing by pre-initialising the pool | `SVLaunchpad.launch` `:260` | Anyone who learns a pending launch's token address can initialise that v4 pool key first, which makes the launch revert with `PoolAlreadyInitialized`. The creator loses gas only. The address depends on a random 32-byte salt carried in the transaction, and the sequencer does not publish pending transactions | Accepted (spec 4.10). The form retries with a new salt, which gives a new address and key |
| SV-03 | Low | A launch carries no expected values for the creator share, hook or creation fee | `launch` `:238-252`, `:424` | An owner change that lands just before a launch applies to it. The creation fee has no on-chain cap. The creator is protected by the exact Permit2 amount the app signs (an increased fee makes the pull revert `PermitMismatch`) and by `minFirstBuyTokens`. An integrator that signs a larger permit than needed is not protected | Accepted (README accepted-risk table). Integrators must sign the exact `firstBuy + creationFee`. A v2 could take expected values as parameters |
| SV-04 | Low | A fee wallet that refuses a token stops trades or paid launches in that token | `SVRouter.sol:152`; `SVLaunchpad._finishLaunch` `:415` | If the fee wallet is blocklisted by an input token or quote, every router trade selling that token, and every paid launch in that quote, reverts until the owner calls `setFeeWallet` | Accepted. No funds at risk, recoverable by the owner; fee collection is unaffected because it uses tolerant delivery |
| SV-05 | Low | Holder rate is a spot balance check | `SVRouter.feeFor` `:182-191` | With an NFT configured and `holderFeeBps = 0`, a wallet that borrows a Suits NFT for one transaction pays no fee | Accepted (spec section 7, Decision Log D34). Inactive at review time: per the Decision Log (9 Oct 2026), `suitsNft()` reads as zero, so everyone pays 0.5 % |
| SV-06 | Low | A quote that pauses, blocklists or misbehaves freezes collections in that quote | `collectFees` `:466-483` | A paused quote, or one that blocklists the launchpad or PoolManager, makes the `take` inside the unlock revert, so neither currency of any launch in that quote can be collected. A gas-burning or reply-bombing quote can do the same | Accepted. Quotes come only from the owner's allowlist (tokenized stocks and USDG). The fork suite showed NVDA carries no transfer allowlist or blocklist |
| SV-07 | Informational | Permit2 signature is not bound to the swap parameters (no witness) | `swapExactIn` `:136-141`, `_pull` `:315-320` | A signed permit authorises a token amount to this contract, not a specific pool or minimum | Accepted. Permit2 is called with `owner = msg.sender`, so only the signer can redeem it, and pool, minimum and deadline are the signer's own call parameters |
| SV-08 | Informational | Gas-starved holder or gate check | `SVRouter.feeFor` `:185`, `SVLaunchpad.isAllowedLauncher` `:690` | A caller who supplies too little gas can make the 100,000-gas `staticcall` fail, paying the normal rate or being refused as a launcher | Accepted. Only the caller's own transaction is affected |
| SV-09 | Informational | Forcing shares into `owed` by starving `_deliver` of gas | `_deliver` `:544-552` | An attacker could try to make a delivery fail with out-of-gas so the share is credited instead of sent. EIP-150 leaves the caller only 1/64 of the gas, too little for the 20,000-gas storage write that crediting needs, so the whole collection reverts instead. A payout contract that cannot call `claim` would strand any share credited to it | Accepted. Not exploitable for the allowlisted quotes; creators should use an EOA or a Safe as payout |
| SV-10 | Informational | First-buy cap and sniping | `_launchCallback` `:370-371` | The 20 % cap bounds only the in-launch buy; the creator or a bot can buy more in the next block. No anti-snipe hook is set (`hook` is zero) | Accepted design. A future anti-snipe hook must pass the `setHook` filter (spec 4.9) |
| SV-11 | Informational | `Trade` and `Launched` events are not proof of a listed pool | `SVRouter.sol:166` | Anyone can route a self-made pool with self-made tokens through the router and emit `Trade` | Accepted (spec section 7). Anything that indexes these events must filter by known pools, which the chain reader does |
| SV-12 | Informational | Tokens sent to the launchpad by mistake are unrecoverable | `SVLaunchpad` (no `sweep`) | A stray transfer to the launchpad stays there | Accepted. No owner-controlled transfer exists by design; this keeps "balance equals the sum of `owed`" exact. The router has `sweep` because it holds nothing between transactions |
| SV-13 | Informational | `SVLaunchpad` sits 287 bytes under EIP-170 | `foundry.toml` compiler restriction | Any feature added to the launchpad will not fit at 200 runs | Noted. The deployed contract is immutable; a successor would need a split (for example the token's creation code behind a factory) |
| SV-14 | Informational | The router deploy script has no test | `script/Deploy.s.sol` (0 % coverage) | Its chain-id and address guards were exercised only by the real deployment of 18 Sep 2026. It does not check a zero `OWNER` itself; the `SVRouter` constructor does | Accepted. The router is deployed. A test would have to set the same process-wide environment variables (`OWNER`, `FEE_WALLET`) as the launchpad script's test, and `vm.setEnv` is shared by tests running in parallel, so adding one risks a flaky suite |
| SV-15 | Informational | No external audit | whole repo | A bug in the launch or collection path would not have been caught by an independent party | Open. Commission an audit before the launchpad carries significant value. Today's evidence: 100 % coverage on `src/`, fuzz and invariant suites, fork tests against the deployed Permit2, Universal Router and PoolManager, and an internal review on 29 Sep 2026 that added the remove-liquidity and swap-delta flags to `setHook`'s refusal list |

Nothing was fixed in this commit. Every candidate defect was either in deployed source, where the brief allows
only a write-up, or turned out not to be exploitable on inspection.

## 5. Reporting

Report a vulnerability privately through a GitHub security advisory on
https://github.com/maxlong-markets/suitventures-markets-contracts/security/advisories/new; please do not open a
public issue.
