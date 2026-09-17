// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Offline stand-in for the Universal Router's V4_SWAP path. Unit tests only.
/// @dev It decodes `execute` calldata the way the real router does (one V4_SWAP command whose input is
///      `abi.encode(actions, params)`), records every decoded field in `lastSwapParams()`, and reverts unless the
///      encoding is the one SVRouter must produce: actions SWAP_EXACT_IN_SINGLE, SETTLE, TAKE in that order;
///      `minHopPriceX36 == 0`; SETTLE of the input currency for exactly the swap's `amountIn` (the net amount)
///      with `payerIsUser == false`; TAKE of the output currency for OPEN_DELTA to the user, a third party that
///      is neither zero, nor the caller, nor this contract. It then checks that the caller transferred exactly
///      the swap's `amountIn` of the input token to it beforehand, as SVRouter does, and pays the TAKE recipient
///      by minting the configured output. It keeps the input it received, so a test can assert "net in the mock
///      router"; `settled(token)` is the running total, which lets several swaps run against one instance.
///
///      Unlike the real router it does not enforce `amountOutMinimum`: that leaves SVRouter's own
///      `InsufficientOutput` check reachable. Use `setRevert` to simulate the real router's revert instead.
///      `setOutput` and `setRevert` are sticky: they apply to every following call until changed; clear a revert
///      with empty data.
///
///      Warning: the `received` accounting (`balanceOf(this) - settled[tokenIn]`) assumes that the configured
///      output token is not the input token and that nothing transfers the input token to this contract outside
///      a swap. Either would make a later call see a wrong `received` amount.
contract MockUniversalRouter {
    /// @notice Every field of the last accepted swap, as decoded from the calldata.
    struct RecordedSwap {
        PoolKey key;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
        address settleCurrency;
        uint256 settleAmount;
        bool settlePayerIsUser;
        address takeCurrency;
        address takeRecipient;
        uint256 takeAmount;
    }

    error BadCommands(bytes commands);
    error BadInputs(uint256 count);
    error BadActions(bytes actions);
    error BadMinHopPrice(uint256 minHopPriceX36);
    error SettleAmountZero();
    error BadSettle(address currency, uint256 amount, bool payerIsUser);
    error BadTake(address currency, address recipient, uint256 amount);
    error WrongAmountIn(uint256 expected, uint256 received);
    error OutputNotConfigured(address tokenOut, address configured);

    address private immutable POOL_MANAGER;

    /// @notice What `execute` pays the TAKE recipient: this token, this amount.
    address public outputToken;
    uint256 public outputAmount;

    /// @notice When non-empty, `execute` reverts with exactly this data.
    bytes public revertData;

    /// @notice The last accepted `execute` call, as received.
    bytes public lastCommands;
    bytes[] private _lastInputs;
    uint256 public lastDeadline;
    RecordedSwap private _lastSwapParams;

    /// @notice Input token amounts consumed by previous swaps, per token.
    mapping(address token => uint256 amount) public settled;

    constructor(address poolManagerPlaceholder) {
        POOL_MANAGER = poolManagerPlaceholder;
    }

    /// @notice Mirrors the real router's `poolManager()` getter; a placeholder address, never called.
    function poolManager() external view returns (address) {
        return POOL_MANAGER;
    }

    function setOutput(address tokenOut, uint256 amount) external {
        outputToken = tokenOut;
        outputAmount = amount;
    }

    function setRevert(bytes calldata data) external {
        revertData = data;
    }

    function lastInputs() external view returns (bytes[] memory) {
        return _lastInputs;
    }

    function lastSwapParams() external view returns (RecordedSwap memory) {
        return _lastSwapParams;
    }

    /// @notice Same signature as `IUniversalRouter.execute`.
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external {
        if (revertData.length != 0) {
            bytes memory data = revertData;
            assembly ("memory-safe") {
                revert(add(data, 0x20), mload(data))
            }
        }

        lastCommands = commands;
        delete _lastInputs;
        for (uint256 i = 0; i < inputs.length; i++) {
            _lastInputs.push(inputs[i]);
        }
        lastDeadline = deadline;

        // Exactly one command, V4_SWAP, with exactly one input.
        if (commands.length != 1 || uint8(commands[0]) != Commands.V4_SWAP) revert BadCommands(commands);
        if (inputs.length != 1) revert BadInputs(inputs.length);

        RecordedSwap memory s = _decode(inputs[0]);
        _lastSwapParams = s;
        _check(s);
        _settleAndPay(s);
    }

    /// @dev The input is abi.encode(actions, params): three actions in this order, each with its params.
    function _decode(bytes calldata input) private pure returns (RecordedSwap memory s) {
        (bytes memory actions, bytes[] memory params) = abi.decode(input, (bytes, bytes[]));
        if (
            actions.length != 3 || params.length != 3 || uint8(actions[0]) != Actions.SWAP_EXACT_IN_SINGLE
                || uint8(actions[1]) != Actions.SETTLE || uint8(actions[2]) != Actions.TAKE
        ) revert BadActions(actions);

        IV4Router.ExactInputSingleParams memory swap = abi.decode(params[0], (IV4Router.ExactInputSingleParams));
        s.key = swap.poolKey;
        s.zeroForOne = swap.zeroForOne;
        s.amountIn = swap.amountIn;
        s.amountOutMinimum = swap.amountOutMinimum;
        s.minHopPriceX36 = swap.minHopPriceX36;
        s.hookData = swap.hookData;
        (s.settleCurrency, s.settleAmount, s.settlePayerIsUser) = abi.decode(params[1], (address, uint256, bool));
        (s.takeCurrency, s.takeRecipient, s.takeAmount) = abi.decode(params[2], (address, address, uint256));
    }

    /// @dev The fields that carry the user's protection must be exactly what SVRouter is specified to send.
    function _check(RecordedSwap memory s) private view {
        (address tokenIn, address tokenOut) = _tokens(s);

        // SWAP_EXACT_IN_SINGLE: the per-hop price floor is off; amountOutMinimum is the user's bound.
        if (s.minHopPriceX36 != 0) revert BadMinHopPrice(s.minHopPriceX36);

        // SETTLE: the input currency, exactly the net amount (not the open delta), paid by the router itself.
        // Zero gets its own error: the real router reads a zero settle amount as OPEN_DELTA, the whole open
        // debt, which is the encoding the security review rejected.
        if (s.settleAmount == 0) revert SettleAmountZero();
        if (s.settleCurrency != tokenIn || s.settleAmount != s.amountIn || s.settlePayerIsUser) {
            revert BadSettle(s.settleCurrency, s.settleAmount, s.settlePayerIsUser);
        }

        // TAKE: the output currency, the open delta, to the user: a third party, never the caller or this mock.
        if (
            s.takeCurrency != tokenOut || s.takeAmount != ActionConstants.OPEN_DELTA || s.takeRecipient == address(0)
                || s.takeRecipient == msg.sender || s.takeRecipient == address(this)
        ) revert BadTake(s.takeCurrency, s.takeRecipient, s.takeAmount);
    }

    /// @dev Settle: the caller must have sent exactly the swap's amountIn of the input token before calling.
    ///      Take: pay the configured output to the recipient.
    function _settleAndPay(RecordedSwap memory s) private {
        (address tokenIn, address tokenOut) = _tokens(s);

        uint256 received = IERC20(tokenIn).balanceOf(address(this)) - settled[tokenIn];
        if (received != s.amountIn) revert WrongAmountIn(s.amountIn, received);
        settled[tokenIn] += received;

        if (tokenOut != outputToken) revert OutputNotConfigured(tokenOut, outputToken);
        MockERC20(tokenOut).mint(s.takeRecipient, outputAmount);
    }

    function _tokens(RecordedSwap memory s) private pure returns (address tokenIn, address tokenOut) {
        (tokenIn, tokenOut) = s.zeroForOne
            ? (Currency.unwrap(s.key.currency0), Currency.unwrap(s.key.currency1))
            : (Currency.unwrap(s.key.currency1), Currency.unwrap(s.key.currency0));
    }
}
