// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

/// @title ISVRouter
/// @notice The LongMarkets trade router on Robinhood Chain: one exact-input Uniswap v4 swap per call, paid
///         through Permit2, with the SuitVentures router fee taken from the input token first.
/// @dev Spec: docs/superpowers/specs/2026-09-17-svrouter-design.md, section 3. Names, types and parameter order
///      follow that section.
interface ISVRouter {
    /// @notice Everything the app knows about one trade.
    struct SwapParams {
        PoolKey key; // currency0 < currency1, fee, tickSpacing, hooks, as the indexer stores them
        bool zeroForOne; // true: pay currency0 and receive currency1
        uint128 amountIn; // pulled from the user, fee included
        uint128 amountOutMin; // the app's quote minus slippage; the swap reverts below it
        bytes hookData; // empty for every listed pool today
        uint256 deadline; // unix seconds; the router reverts after it, before pulling funds
    }

    /// @notice One trade, emitted once per successful `swapExactIn`.
    /// @param user Who paid and who received the output.
    /// @param poolId `keccak256(abi.encode(key))`, the id the indexer uses.
    /// @param tokenIn The token the user paid, fee included in `amountIn`.
    /// @param tokenOut The token the user received.
    /// @param amountIn What was pulled from the user.
    /// @param fee The part of `amountIn` that went to the fee wallet.
    /// @param amountOut What the user actually received, measured by balance difference.
    /// @param holderRate True when the Suits NFT holder rate applied.
    event Trade(
        address indexed user,
        bytes32 indexed poolId,
        address indexed tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 fee,
        uint256 amountOut,
        bool holderRate
    );

    /// @notice The fee wallet was set (also emitted once at deploy with the initial value).
    event FeeWalletChanged(address indexed wallet);

    /// @notice The fee rates were set (also emitted once at deploy with the initial values).
    event FeesChanged(uint16 feeBps, uint16 holderFeeBps);

    /// @notice The Suits NFT address was set; zero means no holder perk (also emitted once at deploy).
    event SuitsNftChanged(address indexed nft);

    /// @notice `block.timestamp` is past the trade's deadline.
    error Expired();
    /// @notice `amountIn` is zero.
    error ZeroAmount();
    /// @notice An address that must be non-zero is zero.
    error ZeroAddress();
    /// @notice The Permit2 message is for another token or for less than `amountIn`.
    error PermitMismatch();
    /// @notice `feeBps` above `MAX_FEE_BPS`, or `holderFeeBps` above `feeBps`.
    error FeeTooHigh();
    /// @notice The user received less than `amountOutMin`.
    error InsufficientOutput(uint256 received, uint256 minimum);

    /// @notice Trade `p.amountIn` of the input token for as much output as the pool gives, at least
    ///         `p.amountOutMin`, with the output sent straight to the caller.
    /// @param p The trade.
    /// @param permit The Permit2 message the caller signed: `permitted.token` must be the input token and
    ///               `permitted.amount` at least `p.amountIn`; the spender is this router.
    /// @param signature The caller's EIP-712 signature over `permit`.
    /// @return amountOut What the caller received.
    function swapExactIn(
        SwapParams calldata p,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) external returns (uint256 amountOut);

    /// @notice Owner only. Sets the wallet that receives the fee; non-zero.
    function setFeeWallet(address wallet) external;

    /// @notice Owner only. Sets both rates in basis points; `feeBps <= MAX_FEE_BPS` and `holderFeeBps <= feeBps`.
    function setFees(uint16 feeBps, uint16 holderFeeBps) external;

    /// @notice Owner only. Sets the Suits NFT whose holders pay `holderFeeBps`; zero disables the perk.
    function setSuitsNft(address nft) external;

    /// @notice Owner only. Moves tokens sent to the router by mistake; the router holds nothing by design.
    function sweep(address token, address to, uint256 amount) external;

    /// @notice The wallet that receives the fee.
    function feeWallet() external view returns (address);

    /// @notice The fee in basis points for everyone else; 50 at deploy.
    function feeBps() external view returns (uint16);

    /// @notice The fee in basis points for Suits NFT holders; 0 at deploy.
    function holderFeeBps() external view returns (uint16);

    /// @notice The Suits NFT; zero means the holder rate is off.
    function suitsNft() external view returns (address);

    /// @notice The fee `user` would pay on `amountIn`, and whether the holder rate applies.
    function feeFor(address user, uint256 amountIn) external view returns (uint256 fee, bool holderRate);

    /// @notice The hard cap on `feeBps`: 50, that is 0.5 %.
    // The name is fixed by the spec (section 3).
    // forge-lint: disable-next-line(mixed-case-function)
    function MAX_FEE_BPS() external pure returns (uint16);
}
