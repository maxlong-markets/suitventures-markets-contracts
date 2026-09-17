# SVRouter

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

The public RPC keeps about 50,000 blocks of state, so if the pinned block has aged out, add `ROBINHOOD_FORK_BLOCK=<a recent block>`; the failure is loud, never silent.

**Not done on purpose:** no deployment, no Blockscout verification, no GitHub remote, no frontend wiring. All of that starts after your review.

## Layout

| Path | What it is |
|---|---|
| `src/SVRouter.sol` | the contract |
| `src/interfaces/ISVRouter.sol` | `SwapParams`, events, errors, external functions (spec section 3) |
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
