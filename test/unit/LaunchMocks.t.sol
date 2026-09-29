// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {MockQuirkyERC20} from "../mocks/MockQuirkyERC20.sol";
import {MockRevertingGate} from "../mocks/MockRevertingGate.sol";
import {MockGasBurningGate} from "../mocks/MockGasBurningGate.sol";

/// @notice The test doubles do exactly what the launchpad suites rely on; a double that silently does something
///         else would make a passing launchpad test prove nothing.
contract LaunchMocksTest is Test {
    MockQuirkyERC20 internal quirky;
    address internal alice;
    address internal bob;

    function setUp() public {
        quirky = new MockQuirkyERC20("Quirky USD", "QUSD", 6);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        quirky.mint(address(this), 1_000_000);
    }

    function test_a_plain_transfer_moves_the_amount_and_returns_true() public {
        assertTrue(quirky.transfer(bob, 10_000), "returns true");
        assertEq(quirky.balanceOf(bob), 10_000, "bob received the amount");
        assertEq(quirky.decimals(), 6, "decimals as constructed");
    }

    function test_a_revert_refusal_reverts_with_Refused() public {
        quirky.setRefusal(bob, MockQuirkyERC20.Refusal.Revert);
        vm.expectRevert(abi.encodeWithSelector(MockQuirkyERC20.Refused.selector, bob));
        quirky.transfer(bob, 1);
    }

    function test_a_false_refusal_returns_false_and_moves_nothing() public {
        quirky.setRefusal(bob, MockQuirkyERC20.Refusal.ReturnFalse);
        (bool ok, bytes memory reply) = address(quirky).call(abi.encodeCall(quirky.transfer, (bob, 1)));
        assertTrue(ok, "the call itself succeeds");
        assertEq(reply, abi.encode(false), "and answers false");
        assertEq(quirky.balanceOf(bob), 0, "nothing moved");
    }

    function test_no_return_data_moves_the_amount_and_answers_nothing() public {
        quirky.setNoReturnData(true);
        (bool ok, bytes memory reply) = address(quirky).call(abi.encodeCall(quirky.transfer, (bob, 7)));
        assertTrue(ok, "the call succeeds");
        assertEq(reply.length, 0, "with no return data");
        assertEq(quirky.balanceOf(bob), 7, "and the amount moved");
    }

    function test_a_transfer_fee_on_every_transfer_burns_its_share() public {
        quirky.setTransferFee(100, address(0));
        quirky.transfer(bob, 10_000);
        assertEq(quirky.balanceOf(bob), 9_900, "1 % burned on the way");
        assertEq(quirky.totalSupply(), 1_000_000 - 100, "the fee left the supply");
    }

    function test_a_transfer_fee_limited_to_one_recipient_spares_everyone_else() public {
        quirky.setTransferFee(100, bob);
        quirky.transfer(alice, 10_000);
        quirky.transfer(bob, 10_000);
        assertEq(quirky.balanceOf(alice), 10_000, "alice is not taxed");
        assertEq(quirky.balanceOf(bob), 9_900, "bob is");
    }

    /// @dev Permit2 and the PoolManager's test router pull with `transferFrom`; a refusal is about `transfer` only.
    function test_transferFrom_ignores_refusals() public {
        quirky.setRefusal(bob, MockQuirkyERC20.Refusal.Revert);
        quirky.approve(alice, 5);
        vm.prank(alice);
        quirky.transferFrom(address(this), bob, 5);
        assertEq(quirky.balanceOf(bob), 5, "transferFrom delivered to a refused address");
    }

    function test_the_reverting_gate_reverts_and_the_gas_burning_gate_runs_out_of_gas() public {
        MockRevertingGate reverting = new MockRevertingGate();
        MockGasBurningGate burning = new MockGasBurningGate();
        vm.expectRevert(MockRevertingGate.GateIsUnwell.selector);
        reverting.balanceOf(alice);
        (bool ok,) = address(burning).staticcall{gas: 100_000}(abi.encodeCall(IERC721.balanceOf, (alice)));
        assertFalse(ok, "the gas-burning gate never answers within 100,000 gas");
    }
}
