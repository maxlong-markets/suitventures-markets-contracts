# SVRouter

The LongMarkets trade router on Robinhood Chain (chain id 4663). One contract, `SVRouter`, is the only way the
app trades: it pulls the input token from the user through Permit2, keeps the router fee for the SuitVentures fee
wallet, forwards an exact-input Uniswap v4 swap to the current Universal Router with the user as the recipient of
the output, and emits one `Trade` event. It never holds a token after a swap and never grants an allowance.

- Spec (binding): [`docs/superpowers/specs/2026-09-17-svrouter-design.md`](docs/superpowers/specs/2026-09-17-svrouter-design.md)
- Plan: [`docs/superpowers/plans/2026-09-17-svrouter.md`](docs/superpowers/plans/2026-09-17-svrouter.md)

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
| `UNIVERSAL_ROUTER` | deploy script | `0x06afBA43fd06227fA663b0dAeCF536F6eaA6BF99`, the current Universal Router (D38) |
| `PERMIT2` | deploy script | `0x000000000022D473030F116dDEE9F6B43aC78BA3`, the canonical Permit2 |

The deployer key is never an environment variable: pass it to forge with `--account`, `--ledger` or
`--interactive`.

## Deploy and verify (after Kobe's review, not before)

```sh
forge script script/Deploy.s.sol --rpc-url robinhood --account <keystore name> --broadcast \
  --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api
```

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
| `SETTLE` | `(currencyIn, OPEN_DELTA, payerIsUser = false)` | pay the whole input debt from the tokens the Universal Router already holds, which the router sent it |
| `TAKE` | `(currencyOut, user, OPEN_DELTA)` | send the whole output credit straight to the user |

The command byte and the action bytes are the constants of the installed `universal-router` (`Commands.sol`) and
`v4-periphery` (`Actions.sol`, `ActionConstants.sol`) libraries; nothing is hand-written.

The dependency versions were chosen against the chain, not the calendar. The Universal Router deployed at
`0x06afBA43fd06227fA663b0dAeCF536F6eaA6BF99` was fingerprinted on 17 Sep 2026 (block 65,188,720):

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
