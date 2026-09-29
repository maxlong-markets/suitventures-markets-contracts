# SuitVentures contracts: SVRouter and SVLaunchpad

The LongMarkets trade router on Robinhood Chain (chain id 4663). One contract, `SVRouter`, is the only way the
app trades: it pulls the input token from the user through Permit2, keeps the router fee for the SuitVentures fee
wallet, forwards an exact-input Uniswap v4 swap to the current Universal Router with the user as the recipient of
the output, and emits one `Trade` event. It never holds a token after a swap and never grants an allowance.

- Spec (binding): [`docs/superpowers/specs/2026-09-17-svrouter-design.md`](docs/superpowers/specs/2026-09-17-svrouter-design.md)
- Plan: [`docs/superpowers/plans/2026-09-17-svrouter.md`](docs/superpowers/plans/2026-09-17-svrouter.md)

## How to review

Read in this order. Times are for a careful pass.

1. **The design (15 min):** `docs/superpowers/specs/2026-09-17-svrouter-design.md`. Sections 3 to 5 are the requirements; 6a lists the implementation choices made during the build; 7 lists the accepted risks, three of which are decisions for you (below).
2. **The contract (45 min):** `src/SVRouter.sol`, top to bottom, against the spec rule each line implements.

   | Spec rule | Where |
   |---|---|
   | The fee can never exceed 0.5 %; deploy values 50 and 0 | `MAX_FEE_BPS` line 41, constructor lines 88 to 102, `setFees` bounds line 209 |
   | Universal Router and Permit2 are fixed at deploy | immutables lines 55 and 58; the deploy script refuses any address but the spec's unless told otherwise |
   | Checks before any funds move: deadline, non-zero amount, permit matches the input token and amount | lines 128, 129, 135 |
   | Permit2 pulls exactly `amountIn` into the router | line 138 |
   | Fee on the input, rounded down, holder rate when a Suits NFT is held; a bad NFT address can never block a trade | `feeFor` lines 182 to 189, static call with a 100,000 gas allowance at line 185 |
   | Fee to the fee wallet, net to the Universal Router, no allowance ever granted | lines 151 to 153 |
   | One Universal Router call: exact-input single swap, settle the exact net, take to the user | `_executeSwap` lines 263 to 290, action bytes from the libraries at line 270 |
   | Output measured as the user's balance delta; below the minimum reverts | lines 157 to 163 |
   | One `Trade` event with gross input, fee, output and the rate used | line 166 |
   | Owner can change the wallet, lower or raise the fee within the cap, set the NFT, sweep a stray token; never renounce | lines 199 to 238 |
   | Reentrancy | `nonReentrant` on `swapExactIn` line 122 |

3. **What the unit suite proves (30 min):** `test/unit/SVRouter.t.sol` is grouped by concern (constructor, setters, ownership, `feeFor`, trades in both directions, every revert, holder rates, the four wrong-NFT cases, `sweep`); `SVRouter.fuzz.t.sol` fuzzes the fee arithmetic and a full trade; `SVRouter.smoke.t.sol` is the harness demonstration. The mock router (`test/mocks/MockUniversalRouter.sol`) decodes the real command and action encodings and records every field, so an encoding regression fails a named test.
4. **What the fork suite proves (15 min):** `test/fork/SVRouterFork.t.sol` runs the real Permit2, the real Universal Router and the three real pools at a pinned block: buys and sells on a Pons pool in both currency orders, a dust buy on the LONG AI/NVDA pool, a holder paying no fee, the two revert paths, and an oversized swap reverting with nothing left in the Universal Router. The V4 Quoter and the router agree to the wei on every trade.
5. **Coverage:** `docs/review/2026-09-17-coverage.md`, produced by an independent run.

**Decisions that are yours:**

- D34 as written gives a Suits NFT holder 0 % with a spot balance check, so an NFT borrowed for one transaction pays no fee. Keep at 0 %, or set a smaller discount with `setFees` after deploy.
- `sweep` (line 229) exists for tokens sent to the router by mistake. Strike it if you would rather the router had no owner-controlled transfer at all.
- Exact input only: the app quotes exact-output requests with the Quoter and executes exact input. Confirm that is acceptable for M2.
- The static call's 100,000 gas allowance (line 48): generous for any ERC721, including proxied ones; a hostile NFT set by the owner is the only thing it guards against.

**Run it yourself:**

```
forge build --sizes
forge test                                   # unit suite; the fork file reports skipped
forge coverage --report summary              # src/SVRouter.sol must read 100 % on all four columns
ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-path 'test/fork/*' -vv
```

The public RPC serves only recent state, and the window varies (a pinned block was refused after about fifteen minutes once), so if the pinned block has aged out, add `ROBINHOOD_FORK_BLOCK=<a recent block>`; the failure is loud, never silent. Continuous runs need an archive endpoint (an Alchemy Robinhood Chain URL works) in `ROBINHOOD_RPC_URL`.

**Two facts the fork suite established (17 Sep 2026):** NVDA moves freely through Permit2, the router and the Universal Router, so the Robinhood stock token carries no transfer allowlist or blocklist (the README's M2 open item); and LONG tokens from the Doppler template report an unlimited Permit2 allowance for every holder, so the app never needs an approval transaction for them (the other listed assets need the one-time Permit2 approval).

**Not done on purpose:** no deployment, no Blockscout verification, no GitHub remote, no frontend wiring. All of that starts after your review.

## SVLaunchpad

The MaxLong Markets instant launchpad. One transaction, signed by a holder of the Suits NFT, deploys a token of
one billion supply with no owner, opens its Uniswap v4 pool at the valuation the creator picks, and places the
whole supply in one position from that price to the end of the price range. The launchpad owns the position and
has no code that can take liquidity out of it. The creator may buy first with their own money, up to 20 % of the
supply. Anyone can collect the trading fees: 70 % go to the launch's payout address and 30 % to the fee wallet.
A share the currency refuses to deliver waits in the contract until its owner claims it.

- Binding spec: frontend repo, `docs/superpowers/specs/2026-09-28-instant-launchpad-design.md`, sections 3 and 4
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
ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com ROBINHOOD_FORK_BLOCK=<a recent block> \
  forge test --match-path 'test/fork/SVLaunchpadFork.t.sol' -vv
```

The size check skips tests and scripts because the PoolManager the tests deploy is larger than the limit. The
coverage profile clears the per-file compiler setting, which coverage builds cannot use.

Set `ROBINHOOD_FORK_BLOCK` to a recent block for the fork run. The public node keeps state for only about an hour,
so the block pinned in the fork test ages out soon after it is set. `cast block-number --rpc-url robinhood` prints
the head; a block a few hundred below it works.

| Fact | Value |
|---|---|
| `SVLaunchpad` runtime size at 1,000,000 optimizer runs | 31,328 bytes, over the 24,576-byte limit |
| `SVLaunchpad` runtime size as built | 24,289 bytes at 200 optimizer runs, 287 under the limit; the stop rule is 24,448 bytes, 128 under |
| `SVLaunchToken` runtime size | 1,969 bytes as built at 200 runs, 2,558 bytes at 1,000,000 runs |
| `SVRouter` runtime size | 7,647 bytes, unchanged |
| Gas of a launch with a first buy | 1,138,477 in the unit suite, normal build |
| Fork run | 2 of 2 passed at block 75,238,414 on the public node |
| Quoter against the launched pool on the fork | exact to the unit |
| `uncollectedFees` against StateView on the fork | equal |
| Deployed pool protocol fee at the fork block | 0 at block 75,238,414 |
| PoolManager protocol fee controller | `0x6d0009504D129CF5002Dba61D9Ae8575AA79314c` |

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

**Deploy, after Kobe's review.** Dry run first against a local anvil fork of chain 4663. In one terminal:

```sh
anvil --fork-url "$ROBINHOOD_RPC_URL" --chain-id 4663
```

In another, the same command the real deploy uses, pointed at anvil:

```sh
forge script script/DeployLaunchpad.s.sol --rpc-url http://127.0.0.1:8545 --account <keystore name> --broadcast
```

Read the printed bounds and settings. When they are right, deploy for real. `--slow` sends each transaction only
after the one before it is mined, so a failed transaction stops the run before the next one is sent:

```sh
forge script script/DeployLaunchpad.s.sol --rpc-url robinhood --account <keystore name> --broadcast --slow
```

The broadcaster deploys with itself as owner, allows every currency, then transfers ownership to `OWNER`. When
`OWNER` is another key, it must call `acceptOwnership`. The script refuses a zero `OWNER`, which is the
placeholder in `.env.example`, so the broadcaster can never stay owner by mistake.

Verify through Sourcify with the constructor arguments PoolManager, Permit2, the broadcaster, `FEE_WALLET` and
`LAUNCHER_GATE`, and with the optimizer runs the launch profile in `foundry.toml` sets, 200:

```sh
forge verify-contract <address> src/SVLaunchpad.sol:SVLaunchpad --chain-id 4663 --verifier sourcify \
  --optimizer-runs 200 \
  --constructor-args "$(cast abi-encode 'constructor(address,address,address,address,address)' \
    0x8366a39CC670B4001A1121B8F6A443A643e40951 0x000000000022D473030F116dDEE9F6B43aC78BA3 \
    <broadcaster> "$FEE_WALLET" "$LAUNCHER_GATE")"
```

**Accepted risks, for MAXLONG's sign-off.** None of these is a bug; each is a choice the contract makes on
purpose, and MAXLONG should agree to each before launch.

| Risk | What it means | What limits it |
|---|---|---|
| Hook set by the owner | Every launch made while a hook is set gets that hook in its pool for good; a pool never changes its hook | Move ownership to MAXLONG's Safe early. The frontend refuses to launch while `hook()` is not zero. `setHook` refuses any hook with a remove-liquidity flag, which could block fee collection, or a returns-delta flag, which could change what a trade or the position pays |
| No on-chain bound at launch | A launch takes the creator share and hook in force when it lands. The launch call carries no expected values for them | The creator is protected only by what the form reads just before signing |
| A quote that pauses or blocklists | If a currency pauses transfers or blocklists the launchpad, collection freezes for both currencies of every launch in that currency | Only currencies the owner allows can be used, so the allowlist is trusted |
| A hostile quote | A quote that burns gas or sends a huge reply can make a collection revert | The same trusted allowlist |
| Rounding dust | Each collection rounds the creator's share down, and the remainder goes to the fee wallet | Less than one raw unit per currency per collection |
| No external audit | The contracts are reviewed and tested here, not audited by an outside firm | 100 % coverage on `src/`, fuzz, invariant and fork tests |

## Layout

| Path | What it is |
|---|---|
| `src/SVRouter.sol` | the contract |
| `src/interfaces/ISVRouter.sol` | `SwapParams`, events, errors, external functions (spec section 3) |
| `src/SVLaunchpad.sol` | the instant launchpad |
| `src/SVLaunchToken.sol` | the token every launch deploys |
| `src/interfaces/ISVLaunchpad.sol` | the launchpad's structs, events, errors, external functions (spec section 4.2) |
| `script/DeployLaunchpad.s.sol` | deploys the launchpad and allows the config's currencies; not run before review |
| `script/config/` | the launchpad's currency config; the only path any script may read |
| `script/Deploy.s.sol` | deploys from environment variables, prints the address; not run before review |
| `test/unit/` | unit tests, no network: the real Permit2 bytecode, mocks for the Universal Router and the tokens |
| `test/fork/` | fork tests against Robinhood Chain, skipped when `ROBINHOOD_RPC_URL` is unset |
| `test/mocks/` | `MockERC20`, `MockERC721`, `MockUniversalRouter` (decodes the real command and action encodings) |
| `test/utils/Permit2Signer.sol` | EIP-712 signing of `PermitTransferFrom` with `vm.sign` |
| `lib/` | dependencies as git submodules, pinned by commit (table below, also in `foundry.lock`) |

## Build, test, coverage, fork

Foundry is the only tool (forge 1.4 nightly on the build machine). Solidity 0.8.26 on the Cancun EVM is pinned
in `foundry.toml`; forge downloads the compiler.

```sh
forge build --sizes
forge test                          # unit suite, no network
forge coverage --report summary     # bar: 100 % lines, statements, branches, functions on src/SVRouter.sol
forge fmt --check
forge lint

# fork suite: the three real pools through the real Permit2 and Universal Router at a pinned block
ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-path 'test/fork/*' -vv
```

## Environment variables

Copy `.env.example` to `.env` (git-ignored). Placeholders only in the example; never commit a real key or wallet.

| Variable | Used by | Meaning |
|---|---|---|
| `ROBINHOOD_RPC_URL` | `foundry.toml` alias `robinhood`, fork tests | Robinhood Chain RPC; the public endpoint needs no key |
| `OWNER` | deploy script | `Ownable2Step` owner: Kobe's EOA at deploy, MAXLONG's Safe once it accepts at M5 |
| `FEE_WALLET` | deploy script | receives the router fee |
| `SUITS_NFT` | deploy script | the Suits NFT; zero or unset disables the holder perk (address TBD) |
| `UNIVERSAL_ROUTER` | deploy script | `0x06AfBA43Fd06227fA663b0DAecF536f6EaA6bf99`, the current Universal Router (D38) |
| `PERMIT2` | deploy script | `0x000000000022D473030F116dDEE9F6B43aC78BA3`, the canonical Permit2 |
| `ALLOW_OTHER_ADDRESSES` | deploy script | `true` lets the script deploy against a router or Permit2 other than the two constants above; unset otherwise |
| `LAUNCHER_GATE` | launchpad deploy script | the ERC-721 whose holders may launch: the Suits NFT; zero lets anyone launch |
| `POOL_MANAGER` | launchpad deploy script | optional; `0x8366a39CC670B4001A1121B8F6A443A643e40951` when unset |

The deployer key is never an environment variable: pass it to forge with `--account`, `--ledger` or
`--interactive`.

## Deploy and verify (after Kobe's review, not before)

```sh
forge script script/Deploy.s.sol --rpc-url robinhood --account <keystore name> --broadcast \
  --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api
```

The script refuses to run unless `block.chainid == 4663`, and unless `UNIVERSAL_ROUTER` and `PERMIT2` are the
spec's constants; set `ALLOW_OTHER_ADDRESSES=true` to deploy against other addresses on purpose.

To verify an already deployed address on Blockscout:

```sh
forge verify-contract <address> src/SVRouter.sol:SVRouter --chain-id 4663 \
  --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api \
  --constructor-args "$(cast abi-encode 'constructor(address,address,address,address,address)' \
    "$OWNER" "$FEE_WALLET" "$UNIVERSAL_ROUTER" "$PERMIT2" "$SUITS_NFT")"
```

## How the Universal Router call is built

`swapExactIn` makes one call, `execute(commands, inputs, deadline)`, with `commands = [Commands.V4_SWAP]` and
`inputs = [abi.encode(actions, params)]` where `actions = [SWAP_EXACT_IN_SINGLE, SETTLE, TAKE]`:

| Action | Params | Meaning |
|---|---|---|
| `SWAP_EXACT_IN_SINGLE` | `IV4Router.ExactInputSingleParams{poolKey, zeroForOne, amountIn = amountIn - fee, amountOutMinimum = amountOutMin, minHopPriceX36 = 0, hookData}` | the swap; `minHopPriceX36 = 0` switches the router's optional per-hop price floor off, `amountOutMin` is the bound |
| `SETTLE` | `(currencyIn, net, payerIsUser = false)` | pay exactly the net amount from the tokens the Universal Router already holds, which the router sent it; if the pool consumed less (a partial fill), the PoolManager rejects the unlock and the whole call reverts, so no input is ever left inside the Universal Router |
| `TAKE` | `(currencyOut, user, OPEN_DELTA)` | send the whole output credit straight to the user |

The command byte and the action bytes are the constants of the installed `universal-router` (`Commands.sol`) and
`v4-periphery` (`Actions.sol`, `ActionConstants.sol`) libraries; nothing is hand-written.

The dependency versions were chosen against the chain, not the calendar. The Universal Router deployed at
`0x06AfBA43Fd06227fA663b0DAecF536f6EaA6bf99` was fingerprinted on 17 Sep 2026 (block 65,188,720):

- its bytecode contains the selectors of `executeSigned`, `signedRouteContext` (added in universal-router 2.1.1)
  and of `V4TooLittleReceivedPerHop`, `V4TooLittleReceivedPerHopSingle`, `InvalidHopPriceLength` (added to
  v4-periphery on 2026-03-17 together with the `minHopPriceX36` field), and does not contain
  `V4ExactOutputUnfilled` (added 2026-08-03) or the 2.2.0 permissioned-router surface;
- a read-only `eth_call` of `execute` with a six-field `ExactInputSingleParams` (`amountOutMinimum = uint128.max`)
  on the MARIO/NVDA pool reverted with `V4TooLittleReceived(uint128.max, 200335378)`, that is, the router decoded
  the struct and ran the swap; the same call with the older five-field struct reverted with empty data.

So the deployed router is a 2.1.1 build and the libraries are pinned to what 2.1.1 was released with.

## Dependencies

Git submodules under `lib/`, pinned by commit (`foundry.lock` holds the same pins). `auto_detect_remappings` is
off, so only `remappings.txt` applies and every Uniswap type resolves to one copy, the root submodule, even
though the dependencies carry their own nested `lib/` trees.

| Library | Ref | Commit | Why this one |
|---|---|---|---|
| `foundry-rs/forge-std` | `v1.9.7` | `77041d2ce690e692d6e03cc812b57d1ddaa4d505` | latest v1.9 |
| `OpenZeppelin/openzeppelin-contracts` | `v5.7.0` | `cab19933c33c2ad1d4c7a84864a3601dddfd16f3` | latest v5 (`Ownable2Step`, `ReentrancyGuard`, `SafeERC20`, `IERC721`) |
| `Uniswap/v4-core` | `v4.0.0` | `e50237c43811bd9b526eff40f26772152a42daba` | the release tag (`PoolKey`, `Currency`, `PoolId`). v4-periphery's own pin is `59d3ecf5`, whose only source change since is the build-dependency refactor #964 (two structs moved to `types/PoolOperation.sol`), which nothing here imports |
| `Uniswap/v4-periphery` | commit | `3231810e39b8c4d569b9d66907fa4ef8cd2cec22` | the commit universal-router 2.1.1 pins (2026-03-17); six-field `ExactInputSingleParams`, no later changes |
| `Uniswap/universal-router` | `2.1.1` | `999d561c3ad58fb5cab91b602911f3c75591a9c7` | the release the deployed router matches (see above); `Commands.V4_SWAP`, `IUniversalRouter` |
| `Uniswap/permit2` | main | `cc56ad0f3439c502c246fc5cfcc3db92bb8b7219` | the commit the Universal Router pins; the contract sources are those of the deployment tag, later commits only touched interface pragmas, docs and test utilities |

### Permit2 in the unit tests

Permit2's sources pin `solc 0.8.17` exactly and cannot be compiled by the 0.8.26 this project pins, so the unit
tests use the real Permit2 the way Uniswap's own periphery tests do: `lib/permit2/test/utils/DeployPermit2.sol`
etches the deployed bytecode at the canonical address `0x000000000022D473030F116dDEE9F6B43aC78BA3`. Signatures,
nonces and deadlines are therefore enforced by the production code, and the fork tests talk to the same address.
