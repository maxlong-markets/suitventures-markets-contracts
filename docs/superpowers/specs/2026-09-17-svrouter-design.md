# SVRouter: design

Date: 2026-09-17. Status: for Kobe's review after the build. Source of truth for the requirements: the workspace README, section 3 (Fees, Access), section 4 (Contracts written for this project), section 5 (M2 definition of done), decisions D6, D20, D28, D33, D34, D38.

## 1. What it is

One contract, `SVRouter`, on Robinhood Chain (chain id 4663). It is the only way the LongMarkets app trades: it pulls the input token from the user through Permit2, keeps the router fee for the SuitVentures fee wallet, forwards an exact-input Uniswap v4 swap to the current Universal Router with the user as recipient, and emits one `Trade` event. It never holds the token being bought and never keeps an allowance. Same path for every listed pool (LONG, Pons, Uniswap): no bonding-curve path, no native ETH path (every quote asset is an ERC20: Robinhood stock tokens and USDG).

Not in scope for M2: exact-output swaps (the app quotes with the V4 Quoter and always executes exact input), multi-hop routes, a pause switch, fee allocation (manual, off-chain), any pool-level hook.

## 2. Chain facts the design uses

| Item | Value |
|---|---|
| Universal Router (current, D38) | `0x06afBA43fd06227fA663b0dAeCF536F6eaA6BF99`, `poolManager()` = `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| V4 Quoter (off-chain quotes only) | `0x8dc178efb8111bb0973dd9d722ebeff267c98f94` |
| Test pool, LONG: AI / NVDA | id `0x8b7f6b0cc404947b4c5d32b02353b82d432c98d61497a07f2a42f4ed5a3c19ee`; currency0 = AI `0x68082B7EA5eE83cA3BD992f038ef02c0180b9Ba3`, currency1 = NVDA `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC`, fee `8388608` (dynamic flag), tickSpacing 200, hooks `0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544` (Doppler); tiny liquidity (about 0.014 NVDA) so fork tests trade dust |
| Test pool, Pons: MARIO / NVDA | id `0xfad0b2c67dd7750f4f9392361ea1567db57b87ac015bfc519960089e73df2f15`; currency0 = MARIO `0x7a492b0A2d630b94791Af846C1842Db9e623420c`, currency1 = NVDA, fee 0, tickSpacing 200, hooks `0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044` (MemeHook, afterSwap only, 1 % hook fee); 42 NVDA of liquidity |
| Test pool, Pons, reversed order: microduck / NVDA | id `0xcde4d35e341901bc0308c2ffc789448ccd0f238a59597fe702e6710484b9c370`; currency0 = NVDA, currency1 = microduck `0xD5f1afEA47b1A9eab414D2ee740cF1d6d039E725`, fee 0, tickSpacing 200, hooks MemeHook; 464 NVDA of liquidity |
| Suits NFT | address TBD (README section 2); the router takes it as a settable address, zero means no perk |
| Fee wallet, build phase | Kobe's EOA (README section 6); production: MAXLONG's Safe, set by the owner |

Robinhood Chain runs the Cancun EVM (v4 core's transient storage is live there). Public RPC `https://rpc.mainnet.chain.robinhood.com`, block 65,176,754 on 17 Sep 2026.

## 3. Interface

```solidity
struct SwapParams {
    PoolKey key;          // currency0 < currency1, fee, tickSpacing, hooks, as the indexer stores them
    bool zeroForOne;      // true: pay currency0 and receive currency1
    uint128 amountIn;     // pulled from the user, fee included
    uint128 amountOutMin; // the app's quote minus slippage; the swap reverts below it
    bytes hookData;       // empty for every listed pool today
    uint256 deadline;     // unix seconds; the router reverts after it, before pulling funds
}

function swapExactIn(
    SwapParams calldata p,
    ISignatureTransfer.PermitTransferFrom calldata permit, // token == tokenIn, amount >= p.amountIn
    bytes calldata signature
) external returns (uint256 amountOut);

event Trade(address indexed user, bytes32 indexed poolId, address indexed tokenIn, address tokenOut,
            uint256 amountIn, uint256 fee, uint256 amountOut, bool holderRate);

// Owner only (Ownable2Step; owner = Kobe's EOA at deploy, MAXLONG's Safe at M5)
function setFeeWallet(address wallet) external;                 // non-zero
function setFees(uint16 feeBps, uint16 holderFeeBps) external;  // feeBps <= 50, holderFeeBps <= feeBps
function setSuitsNft(address nft) external;                      // zero disables the perk
function sweep(address token, address to, uint256 amount) external; // tokens sent here by mistake; the router holds nothing by design

// Views
function feeWallet() external view returns (address);
function feeBps() external view returns (uint16);          // 50 at deploy
function holderFeeBps() external view returns (uint16);    // 0 at deploy
function suitsNft() external view returns (address);
function feeFor(address user, uint256 amountIn) external view returns (uint256 fee, bool holderRate);
function MAX_FEE_BPS() external pure returns (uint16);     // 50
```

Custom errors: `Expired()`, `ZeroAmount()`, `ZeroAddress()`, `PermitMismatch()`, `FeeTooHigh()`, `InsufficientOutput(uint256 received, uint256 minimum)`.

## 4. Behaviour of `swapExactIn`

1. `block.timestamp > p.deadline` reverts `Expired()`; `p.amountIn == 0` reverts `ZeroAmount()`. `tokenIn` and `tokenOut` come from the key and `zeroForOne`.
2. `permit.permitted.token != tokenIn` or `permit.permitted.amount < p.amountIn` reverts `PermitMismatch()`. Then `permit2.permitTransferFrom(permit, {to: address(this), requestedAmount: p.amountIn}, msg.sender, signature)` pulls exactly `amountIn` into the router (Permit2 enforces the signature, nonce and deadline).
3. `fee = amountIn * bps / 10_000`, where `bps = holderFeeBps` if `suitsNft != address(0)` and a `try IERC721(suitsNft).balanceOf(msg.sender)` succeeds with a value above zero, else `feeBps`; a reverting or codeless NFT address therefore costs the holder rate, never the trade (amended 17 Sep 2026). Rounds down. `fee` goes to `feeWallet` with `SafeERC20.safeTransfer`; `amountIn - fee` goes to the Universal Router the same way.
4. One Universal Router call: `execute(commands = [V4_SWAP], inputs = [abi.encode(actions, params)], p.deadline)` with actions `SWAP_EXACT_IN_SINGLE(key, zeroForOne, amountIn - fee, amountOutMin, minHopPriceX36 = 0, hookData)` (the deployed router speaks v4-periphery's six-field `ExactInputSingleParams`; zero disables the per-hop price check, verified against the live bytecode on 17 Sep 2026), `SETTLE(tokenIn, amountIn - fee, payerIsUser = false)` (the router pays the exact net amount from the tokens it now holds; if the pool consumes less, for example when its liquidity runs out, the PoolManager rejects the unlock and the whole call reverts, so no input can be stranded in the Universal Router; amended 17 Sep 2026 after the security review, which showed that settling the open delta would have left a partial fill's remainder behind), `TAKE(tokenOut, recipient = msg.sender, OPEN_DELTA)` (output goes straight to the user; the router never holds it, so LONG's early per-wallet caps cannot trip on an intermediary). The command and action bytes are taken from the installed `universal-router` and `v4-periphery` libraries, never hand-written.
5. `amountOut` is the user's `tokenOut` balance after minus before the call (the hook may take its fee from the output, which the Quoter already reflects). `amountOut < p.amountOutMin` reverts `InsufficientOutput` (the Universal Router enforces the same bound; this is the belt to its braces).
6. Emit `Trade(msg.sender, key.toId(), tokenIn, tokenOut, amountIn, fee, amountOut, holderRate)` and return `amountOut`.
7. `nonReentrant` on the function; no state other than the fee settings and the NFT address; no allowances granted by the router to anyone; the router's balance of both tokens is what it was before the call (asserted in tests).

Sell-side fees arrive in the token being sold (the README's Fees table says so); nothing in the router converts them.

## 5. Ownership and fees

`Ownable2Step` (OpenZeppelin v5): the deployer names the owner in the constructor; transfer at M5 needs the Safe to accept. `MAX_FEE_BPS = 50` is a constant: `setFees` accepts any pair with `feeBps <= 50` and `holderFeeBps <= feeBps`, so the fee can be lowered and raised again but never above 0.5 %. Deploy values 50 and 0. Every setter emits an event (`FeeWalletChanged`, `FeesChanged`, `SuitsNftChanged`). Constructor: `(address owner, address feeWallet, address universalRouter, address permit2, address suitsNft)`; zero `owner`, `feeWallet`, `universalRouter` or `permit2` reverts `ZeroAddress()`; `suitsNft` may be zero.

## 6. Tests and acceptance

- Unit tests run with no network: real Permit2 compiled from its repository, a `MockUniversalRouter` that decodes the router's calldata, moves the input it was given, pays the recipient in `tokenOut` (with a configurable output and a configurable revert), a `MockERC20` and a `MockERC721`. They cover every line, statement, branch and function of `SVRouter.sol` (`forge coverage`, 100 % on that file; the mocks and scripts are excluded from the bar), including: fee rounding, holder and non-holder rates, zero NFT address, every revert, every event with exact values, `Ownable2Step` transfer, fuzzed amounts and bps, both `zeroForOne` directions, the balance-delta measurement with a hook-style output shortfall, and that the router's balances are unchanged after a swap.
- Fork tests run against Robinhood Chain at a pinned block through `ROBINHOOD_RPC_URL`: real Permit2 signatures from a test key, the real Universal Router, the three pools above in both directions, a holder (mock NFT minted to the user) and a non-holder, asserting the fee in the fee wallet, the user's output at or above the Quoter's quote minus slippage, the `Trade` event, and a revert on an impossible `amountOutMin`. They are skipped, not failed, when the RPC variable is unset.
- The deploy script takes owner, fee wallet and NFT from the environment, prints the address, and verifies on Blockscout (`https://robinhoodchain.blockscout.com/api`). Deployment itself waits for Kobe's review.
- Static checks: `forge fmt --check`, `forge build --sizes`, and Slither if it is installed.

## 6a. Implementation notes for the review (17 Sep 2026)

- A zero fee (holder rate 0 bps) is not transferred at all; the fee wallet sees no zero-value transfer.
- The constructor emits `FeeWalletChanged`, `FeesChanged` and `SuitsNftChanged` with the initial values, so indexers see the deploy state.
- The Universal Router call lives in an internal `_executeSwap` (stack depth without via-IR).
- Dependencies pinned: universal-router 2.1.1, v4-periphery 3231810e, permit2 cc56ad0f, OpenZeppelin 5.7.0; unit tests etch Permit2's real bytecode at its canonical address (its sources pin solc 0.8.17).

## 7. Risks and open items

- Robinhood stock tokens are assumed to carry no transfer allowlist or blocklist (README open item, M2); the fork tests through Permit2, the router and the Universal Router are the check.
- The Suits NFT discount is proposed at 0 % (D34) and its address is TBD; the router treats the NFT as settable and the rate as configurable within the cap, so neither blocks the build.
- `sweep` exists only for tokens sent to the router by mistake; the router holds nothing after a swap. It requires a non-zero `to` and emits `Swept`. Kobe may strike it in review.
- `renounceOwnership` is overridden to revert: a router with no owner could never change its fee wallet again.
- The holder rate is a spot `balanceOf` check with no lock-up, so at 0 bps anyone who borrows a Suits NFT for one transaction pays no fee. This follows D34 as written; whether that is acceptable, or the discount should be smaller than 100 %, is Kobe's and the client's call.
- Because the settle is exact, a hook that charges a delta on the input side would make every trade on that pool revert rather than partially fill. None of the listed hooks does (MemeHook is afterSwap-only on the output; Doppler's dynamic fee is an LP fee inside the swap); the fork tests prove it on the three pools.
- The Suits NFT guard tolerates a codeless address, a reverting `balanceOf` and a malformed reply (low-level static call, reply must be exactly 32 bytes); any of those costs the holder rate, never the trade.
- Fee-on-transfer or rebasing input tokens are unsupported: the router receives less than `amountIn`, cannot cover the settle, and the call reverts.
- `Trade` events are user-triggerable with any pool key and any tokens (a self-made pool with self-made tokens), so anything that indexes them must filter by known pools rather than trust the fields.
- Exact-output ("I want exactly N tokens") is out of scope; the app derives the input amount from a Quoter exact-output quote and executes exact input.
