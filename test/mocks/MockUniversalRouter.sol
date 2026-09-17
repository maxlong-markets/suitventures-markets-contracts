// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Offline stand-in for the Universal Router's V4_SWAP path. Unit tests only.
/// @dev It decodes `execute` calldata exactly the way the real router does (one V4_SWAP command whose input is
///      `abi.encode(actions, params)`), checks that the actions are SWAP_EXACT_IN_SINGLE, SETTLE, TAKE with the
///      settle and take parameters SVRouter must produce, checks that the caller transferred exactly the swap's
///      `amountIn` of the input token to it beforehand (as SVRouter does), and pays the recipient named in TAKE
///      by minting the configured output. It keeps the input it received, so a test can assert "net in the mock
///      router"; `settled(token)` is the running total, which lets several swaps run against one instance.
///
///      Unlike the real router it does not enforce `amountOutMinimum`: that leaves SVRouter's own
///      `InsufficientOutput` check reachable. Use `setRevert` to simulate the real router's revert instead.
///      `setOutput` and `setRevert` are sticky: they apply to every following call until changed; clear a revert
///      with empty data.
contract MockUniversalRouter {
    error BadCommands(bytes commands);
    error BadInputs(uint256 count);
    error BadActions(bytes actions);
    error BadSettle(address currency, uint256 amount, bool payerIsUser);
    error BadTake(address currency, address recipient, uint256 amount);
    error WrongAmountIn(uint256 expected, uint256 received);
    error OutputNotConfigured(address tokenOut, address configured);

    address private immutable POOL_MANAGER;

    /// @notice What the next `execute` pays the TAKE recipient: this token, this amount.
    address public outputToken;
    uint256 public outputAmount;

    /// @notice When non-empty, `execute` reverts with exactly this data.
    bytes public revertData;

    /// @notice The last successful `execute` call, as received.
    bytes public lastCommands;
    bytes[] private _lastInputs;
    uint256 public lastDeadline;

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

        // The input is abi.encode(actions, params): three actions in this order.
        (bytes memory actions, bytes[] memory params) = abi.decode(inputs[0], (bytes, bytes[]));
        if (
            actions.length != 3 || params.length != 3 || uint8(actions[0]) != Actions.SWAP_EXACT_IN_SINGLE
                || uint8(actions[1]) != Actions.SETTLE || uint8(actions[2]) != Actions.TAKE
        ) revert BadActions(actions);

        // SWAP_EXACT_IN_SINGLE: the pool and the direction give the two tokens.
        IV4Router.ExactInputSingleParams memory swap = abi.decode(params[0], (IV4Router.ExactInputSingleParams));
        (address tokenIn, address tokenOut) = swap.zeroForOne
            ? (Currency.unwrap(swap.poolKey.currency0), Currency.unwrap(swap.poolKey.currency1))
            : (Currency.unwrap(swap.poolKey.currency1), Currency.unwrap(swap.poolKey.currency0));

        // SETTLE: the input currency, the open delta, paid by the router itself (not by the caller).
        (address settleCurrency, uint256 settleAmount, bool payerIsUser) =
            abi.decode(params[1], (address, uint256, bool));
        if (settleCurrency != tokenIn || settleAmount != ActionConstants.OPEN_DELTA || payerIsUser) {
            revert BadSettle(settleCurrency, settleAmount, payerIsUser);
        }

        // TAKE: the output currency, the open delta, to a real third party (the user), never to the caller
        // or to this contract.
        (address takeCurrency, address recipient, uint256 takeAmount) =
            abi.decode(params[2], (address, address, uint256));
        if (
            takeCurrency != tokenOut || takeAmount != ActionConstants.OPEN_DELTA || recipient == address(0)
                || recipient == msg.sender || recipient == address(this)
        ) revert BadTake(takeCurrency, recipient, takeAmount);

        // Settle: the caller must have sent exactly the swap's amountIn of the input token before calling.
        uint256 received = IERC20(tokenIn).balanceOf(address(this)) - settled[tokenIn];
        if (received != swap.amountIn) revert WrongAmountIn(swap.amountIn, received);
        settled[tokenIn] += received;

        // Take: pay the configured output to the recipient.
        if (tokenOut != outputToken) revert OutputNotConfigured(tokenOut, outputToken);
        MockERC20(tokenOut).mint(recipient, outputAmount);
    }
}
