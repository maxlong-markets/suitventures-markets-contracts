# Deploying, verifying and fork-testing

Operational detail moved out of the [README](../README.md). Both contracts are already deployed (SVRouter on
18 Sep 2026, SVLaunchpad on 29 Sep 2026). This page records how that was done and how to repeat it on a fork or
for a successor contract.

## Environment variables

Copy `.env.example` to `.env` (git-ignored). The example holds placeholders only; never commit a real key or wallet.

| Variable | Used by | Meaning |
|---|---|---|
| `ROBINHOOD_RPC_URL` | `foundry.toml` alias `robinhood`, fork tests | Robinhood Chain RPC; the public endpoint needs no key |
| `ROBINHOOD_FORK_BLOCK` | fork tests | optional; the block to fork at instead of the pinned one |
| `OWNER` | both deploy scripts | the `Ownable2Step` owner: the developer's EOA at deploy, the client's wallet once it accepts |
| `FEE_WALLET` | both deploy scripts | receives the router fee, the creation fee and the platform's fee share |
| `SUITS_NFT` | `Deploy.s.sol` | the Suits NFT for the router's holder rate; zero or unset disables it |
| `UNIVERSAL_ROUTER` | `Deploy.s.sol` | `0x06AfBA43Fd06227fA663b0DAecF536f6EaA6bf99`, the current Universal Router (D38) |
| `PERMIT2` | both deploy scripts | `0x000000000022D473030F116dDEE9F6B43aC78BA3`, the canonical Permit2 |
| `ALLOW_OTHER_ADDRESSES` | both deploy scripts | `true` lets a script deploy against a router, PoolManager or Permit2 other than the constants; unset otherwise |
| `LAUNCHER_GATE` | `DeployLaunchpad.s.sol` | the ERC-721 whose holders may launch (the Suits NFT at deploy); zero lets anyone launch |
| `POOL_MANAGER` | `DeployLaunchpad.s.sol` | optional; `0x8366a39CC670B4001A1121B8F6A443A643e40951` when unset |

The deployer key is never an environment variable: pass it to forge with `--account`, `--ledger` or
`--interactive`.

## SVRouter

```sh
forge script script/Deploy.s.sol --rpc-url robinhood --account <keystore name> --broadcast \
  --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api
```

The script refuses to run unless `block.chainid == 4663`, and unless `UNIVERSAL_ROUTER` and `PERMIT2` are the
spec's constants and have code; set `ALLOW_OTHER_ADDRESSES=true` to deploy against other addresses on purpose.

To verify an already deployed address on Blockscout (SVRouter compiles at the default 1,000,000 optimizer runs):

```sh
forge verify-contract <address> src/SVRouter.sol:SVRouter --chain-id 4663 \
  --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api \
  --constructor-args "$(cast abi-encode 'constructor(address,address,address,address,address)' \
    "$OWNER" "$FEE_WALLET" "$UNIVERSAL_ROUTER" "$PERMIT2" "$SUITS_NFT")"
```

## SVLaunchpad

### Currencies

The deploy script reads `script/config/launch-currencies.json` (54 currencies). The frontend script
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

### Dry run, deploy, verify

Dry run first against a local anvil fork of chain 4663. In one terminal:

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

Launched tokens (`SVLaunchToken`) also verify with `--optimizer-runs 200`.

## Fork tests

```sh
ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-path 'test/fork/SVRouterFork.t.sol' -vv
ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com ROBINHOOD_FORK_BLOCK=<a recent block> \
  forge test --match-path 'test/fork/SVLaunchpadFork.t.sol' -vv
```

Both files skip when `ROBINHOOD_RPC_URL` is unset. The public node keeps state for only about an hour (a pinned
block was refused after about fifteen minutes once), so the block pinned in a fork test ages out soon after it is
set. `cast block-number --rpc-url robinhood` prints the head; a block a few hundred below it works. The failure is
loud, never silent. Continuous runs need an archive endpoint (an Alchemy Robinhood Chain URL works) in
`ROBINHOOD_RPC_URL`.

What the fork suites established:

| Fact | Value |
|---|---|
| SVRouter fork run | 9 of 9 passed at block 65,241,000 (17 Sep 2026); the V4 Quoter and the router agree to the wei on every trade |
| NVDA through Permit2, the router and the Universal Router | moves freely, so the Robinhood stock token carries no transfer allowlist or blocklist |
| LONG tokens (Doppler template) | report an unlimited Permit2 allowance for every holder, so the app needs no approval transaction for them; other assets need the one-time Permit2 approval |
| `InsufficientOutput` on the real router | never engages: the Universal Router reverts first with `V4TooLittleReceived`, so the router's own check is a backstop |
| SVLaunchpad fork run | 2 of 2 passed at block 75,238,414 (29 Sep 2026) |
| Quoter against a launched pool | exact to the unit |
| `uncollectedFees` against StateView | equal, so the deployed PoolManager's storage matches the v4.0.0 layout `StateLibrary` reads |
| Pool protocol fee at that block | 0; protocol fee controller `0x6d0009504D129CF5002Dba61D9Ae8575AA79314c` |
