// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {IUniversalRouter} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {ISVRouter} from "./interfaces/ISVRouter.sol";

/// @title SVRouter
/// @notice The LongMarkets trade router on Robinhood Chain. One call, `swapExactIn`, does the whole trade: pull
///         the input token from the user through Permit2, keep the router fee for the SuitVentures fee wallet,
///         and forward an exact-input Uniswap v4 swap to the Universal Router with the user as the recipient of
///         the output. The router never holds a token after a swap and never grants an allowance to anyone.
/// @dev Design: docs/superpowers/specs/2026-09-17-svrouter-design.md. Sections 3 to 5 of that document are the
///      requirements; the comments in this file say why each line is there.
///
///      Out of scope on purpose: native ETH on either side of a pool (every listed quote asset is an ERC20),
///      exact-output swaps, multi-hop routes, a pause switch. A key that names the zero currency fails safely:
///      SafeERC20 refuses to transfer through an address without code.
contract SVRouter is ISVRouter, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------------------------------------

    /// @inheritdoc ISVRouter
    uint16 public constant MAX_FEE_BPS = 50;

    /// @dev Basis points denominator: 10_000 bps is 100 %.
    uint256 private constant BPS = 10_000;

    // -------------------------------------------------------------------------------------------------------
    // Immutables: the two contracts this router talks to, fixed at deploy
    // -------------------------------------------------------------------------------------------------------

    /// @notice The Uniswap Universal Router that executes the v4 swap (spec section 2, decision D38).
    IUniversalRouter public immutable UNIVERSAL_ROUTER;

    /// @notice Permit2, which pulls the input token from the user against the user's signature.
    ISignatureTransfer public immutable PERMIT2;

    // -------------------------------------------------------------------------------------------------------
    // Storage: the fee settings share one slot, the NFT address takes the next one
    // -------------------------------------------------------------------------------------------------------

    /// @inheritdoc ISVRouter
    address public feeWallet;

    /// @inheritdoc ISVRouter
    uint16 public feeBps;

    /// @inheritdoc ISVRouter
    uint16 public holderFeeBps;

    /// @inheritdoc ISVRouter
    address public suitsNft;

    // -------------------------------------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------------------------------------

    /// @param owner_ The Ownable2Step owner: Kobe's EOA at deploy, MAXLONG's Safe once it accepts at M5.
    /// @param feeWallet_ Receives the router fee.
    /// @param universalRouter_ The current Universal Router (spec section 2).
    /// @param permit2_ The canonical Permit2.
    /// @param suitsNft_ The Suits NFT; zero disables the holder rate until `setSuitsNft` names one.
    /// @dev Deploy values: `feeBps` = 50 (the cap), `holderFeeBps` = 0. The owner is checked inside the
    ///      `Ownable` constructor argument because `Ownable`'s constructor runs before this body and would
    ///      otherwise revert with its own error instead of `ZeroAddress()`.
    constructor(address owner_, address feeWallet_, address universalRouter_, address permit2_, address suitsNft_)
        Ownable(_nonZero(owner_))
    {
        if (feeWallet_ == address(0) || universalRouter_ == address(0) || permit2_ == address(0)) {
            revert ZeroAddress();
        }
        UNIVERSAL_ROUTER = IUniversalRouter(universalRouter_);
        PERMIT2 = ISignatureTransfer(permit2_);
        feeWallet = feeWallet_;
        feeBps = MAX_FEE_BPS;
        holderFeeBps = 0;
        suitsNft = suitsNft_;
        emit FeeWalletChanged(feeWallet_);
        emit FeesChanged(MAX_FEE_BPS, 0);
        emit SuitsNftChanged(suitsNft_);
    }

    // -------------------------------------------------------------------------------------------------------
    // The swap
    // -------------------------------------------------------------------------------------------------------

    /// @inheritdoc ISVRouter
    /// @dev Spec section 4, in this order:
    ///      1. deadline and amount checks, before anything moves;
    ///      2. the permit must name the input token and cover `amountIn`, then Permit2 pulls exactly `amountIn`
    ///         into this contract (Permit2 enforces the signature, the nonce and the permit's own deadline);
    ///      3. the fee is split off and sent to the fee wallet, the rest is sent to the Universal Router, which
    ///         will pay the pool from its own balance;
    ///      4. one Universal Router call, built and made by `_executeSwap`: swap exact input, settle the input,
    ///         take the output to the user;
    ///      5. `amountOut` is the user's balance difference, so a hook fee taken from the output is counted, and
    ///         the minimum is enforced here as well as inside the Universal Router;
    ///      6. emit `Trade`.
    ///      `nonReentrant` closes the door on re-entry from the tokens, the hook or the NFT during the call.
    function swapExactIn(
        SwapParams calldata p,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) external nonReentrant returns (uint256 amountOut) {
        // 1. Cheap checks first, before any token moves.
        if (block.timestamp > p.deadline) revert Expired();
        if (p.amountIn == 0) revert ZeroAmount();
        address tokenIn = Currency.unwrap(p.zeroForOne ? p.key.currency0 : p.key.currency1);
        address tokenOut = Currency.unwrap(p.zeroForOne ? p.key.currency1 : p.key.currency0);

        // 2. The permit must be for this token and cover the amount; Permit2 checks the rest and pulls the
        //    tokens from the caller into this contract.
        if (permit.permitted.token != tokenIn || permit.permitted.amount < p.amountIn) revert PermitMismatch();
        PERMIT2.permitTransferFrom(
            permit,
            ISignatureTransfer.SignatureTransferDetails({to: address(this), requestedAmount: p.amountIn}),
            msg.sender,
            signature
        );

        // 3. Fee first, in the input token. The rest is the swap's input. The fee is at most 0.5 % of amountIn,
        //    so `net` can never underflow and is never zero. A zero fee (holder rate at 0 bps, or a tiny
        //    amountIn that rounds to 0) is not transferred at all: some tokens revert on zero-value transfers.
        (uint256 fee, bool holderRate) = feeFor(msg.sender, p.amountIn);
        // The cast cannot truncate: fee <= amountIn / 200 and amountIn is a uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 net = p.amountIn - uint128(fee);
        if (fee != 0) IERC20(tokenIn).safeTransfer(feeWallet, fee);
        IERC20(tokenIn).safeTransfer(address(UNIVERSAL_ROUTER), net);

        // 4. One Universal Router call. The output goes straight to the caller: this router never holds it, so
        //    a per-wallet cap on the token being bought cannot trip on an intermediary.
        uint256 balanceBefore = IERC20(tokenOut).balanceOf(msg.sender);
        _executeSwap(p, net, msg.sender);

        // 5. What the caller actually received: measured, not trusted. The Universal Router enforces the same
        //    minimum on the raw swap output; this check also covers anything a hook takes on the way out.
        amountOut = IERC20(tokenOut).balanceOf(msg.sender) - balanceBefore;
        if (amountOut < p.amountOutMin) revert InsufficientOutput(amountOut, p.amountOutMin);

        // 6. One event per trade, with the values the indexer needs.
        emit Trade(msg.sender, PoolId.unwrap(p.key.toId()), tokenIn, tokenOut, p.amountIn, fee, amountOut, holderRate);
    }

    // -------------------------------------------------------------------------------------------------------
    // The fee
    // -------------------------------------------------------------------------------------------------------

    /// @inheritdoc ISVRouter
    /// @dev The single fee rule, used by `swapExactIn` and readable by the app for its quote. The holder rate
    ///      applies when an NFT is configured and the user holds at least one. Rounds down.
    function feeFor(address user, uint256 amountIn) public view returns (uint256 fee, bool holderRate) {
        address nft = suitsNft;
        holderRate = nft != address(0) && IERC721(nft).balanceOf(user) > 0;
        uint256 bps = holderRate ? holderFeeBps : feeBps;
        fee = amountIn * bps / BPS;
    }

    // -------------------------------------------------------------------------------------------------------
    // Owner settings (Ownable2Step: a transfer takes effect only when the new owner accepts)
    // -------------------------------------------------------------------------------------------------------

    /// @inheritdoc ISVRouter
    /// @dev Zero is refused so the fee can never be burned by mistake.
    function setFeeWallet(address wallet) external onlyOwner {
        if (wallet == address(0)) revert ZeroAddress();
        feeWallet = wallet;
        emit FeeWalletChanged(wallet);
    }

    /// @inheritdoc ISVRouter
    /// @dev Any pair within the cap is accepted, so the fee can be lowered and raised again, but never above
    ///      `MAX_FEE_BPS`, and the holder rate can never exceed the regular rate.
    function setFees(uint16 newFeeBps, uint16 newHolderFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS || newHolderFeeBps > newFeeBps) revert FeeTooHigh();
        feeBps = newFeeBps;
        holderFeeBps = newHolderFeeBps;
        emit FeesChanged(newFeeBps, newHolderFeeBps);
    }

    /// @inheritdoc ISVRouter
    /// @dev The Suits NFT address is not known yet (spec section 2); zero keeps the perk off. An address without
    ///      code would make every swap revert at `balanceOf`, which the owner can correct with another call.
    function setSuitsNft(address nft) external onlyOwner {
        suitsNft = nft;
        emit SuitsNftChanged(nft);
    }

    /// @inheritdoc ISVRouter
    /// @dev The router's balances are unchanged by a swap, so anything here arrived by mistake.
    function sweep(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }

    // -------------------------------------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------------------------------------

    /// @dev Builds and makes the Universal Router call for one exact-input single-pool v4 swap. The command byte
    ///      and the action bytes come from the installed `universal-router` and `v4-periphery` libraries, never
    ///      from hand-written constants, so they match the deployed router by construction.
    ///
    ///      commands = [V4_SWAP]; inputs = [abi.encode(actions, params)] with
    ///        SWAP_EXACT_IN_SINGLE: swap `net` of currencyIn for at least `amountOutMin` of currencyOut in the
    ///                              pool of `p.key`, passing `hookData` through. `minHopPriceX36 = 0` switches
    ///                              the router's optional per-hop price floor off; `amountOutMin` is the bound.
    ///        SETTLE:               pay the swap's whole input debt (OPEN_DELTA) from the tokens the Universal
    ///                              Router already holds (payerIsUser = false), which this contract sent it.
    ///        TAKE:                 send the swap's whole output credit (OPEN_DELTA) to `recipient`, the user.
    ///      The call itself lives here rather than in `swapExactIn` only to keep that function's live variables
    ///      within what the legacy code generator allows (via-IR is off by design).
    function _executeSwap(SwapParams calldata p, uint128 net, address recipient) private {
        (Currency currencyIn, Currency currencyOut) =
            p.zeroForOne ? (p.key.currency0, p.key.currency1) : (p.key.currency1, p.key.currency0);

        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));

        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE), uint8(Actions.TAKE));

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: p.key,
                zeroForOne: p.zeroForOne,
                amountIn: net,
                amountOutMinimum: p.amountOutMin,
                minHopPriceX36: 0,
                hookData: p.hookData
            })
        );
        params[1] = abi.encode(currencyIn, ActionConstants.OPEN_DELTA, false);
        params[2] = abi.encode(currencyOut, recipient, ActionConstants.OPEN_DELTA);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        UNIVERSAL_ROUTER.execute(commands, inputs, p.deadline);
    }

    /// @dev Reverts with `ZeroAddress()` for the zero address, otherwise returns the input unchanged. Used in the
    ///      constructor's `Ownable` argument, which is evaluated before any base constructor runs.
    function _nonZero(address account) private pure returns (address) {
        if (account == address(0)) revert ZeroAddress();
        return account;
    }
}
