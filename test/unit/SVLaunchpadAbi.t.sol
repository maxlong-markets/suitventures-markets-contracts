// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ISVLaunchpad} from "../../src/interfaces/ISVLaunchpad.sol";

/// @notice Every function of `ISVLaunchpad` against its canonical signature in spec section 4.2, so the frontend's
///         transcribed ABI and this interface cannot drift apart unnoticed.
contract SVLaunchpadAbiTest is Test {
    function _pin(bytes4 actual, string memory signature) internal pure {
        assertEq(actual, bytes4(keccak256(bytes(signature))), signature);
    }

    function test_every_function_selector_matches_the_spec_signature() public pure {
        _pin(
            ISVLaunchpad.launch.selector,
            "launch((string,string,string,address,uint256,uint256,uint256,address,bytes32,uint256),((address,uint256),uint256,uint256),bytes)"
        );
        _pin(ISVLaunchpad.collectFees.selector, "collectFees(address)");
        _pin(ISVLaunchpad.claim.selector, "claim(address,address)");
        _pin(ISVLaunchpad.setPayout.selector, "setPayout(address,address)");
        _pin(ISVLaunchpad.unlockCallback.selector, "unlockCallback(bytes)");
        _pin(ISVLaunchpad.setFeeWallet.selector, "setFeeWallet(address)");
        _pin(ISVLaunchpad.setRouterFee.selector, "setRouterFee(uint16)");
        _pin(ISVLaunchpad.setCreatorShare.selector, "setCreatorShare(uint16)");
        _pin(ISVLaunchpad.setFirstBuyCap.selector, "setFirstBuyCap(uint16)");
        _pin(ISVLaunchpad.setDailyLaunchLimit.selector, "setDailyLaunchLimit(uint8)");
        _pin(ISVLaunchpad.setLauncherGate.selector, "setLauncherGate(address)");
        _pin(ISVLaunchpad.setHook.selector, "setHook(address)");
        _pin(ISVLaunchpad.setCurrency.selector, "setCurrency(address,uint256,uint256,uint256)");
        _pin(ISVLaunchpad.getLaunch.selector, "getLaunch(address)");
        _pin(ISVLaunchpad.poolKeyOf.selector, "poolKeyOf(address)");
        _pin(ISVLaunchpad.uncollectedFees.selector, "uncollectedFees(address)");
        _pin(ISVLaunchpad.predictToken.selector, "predictToken(address,bytes32,string,string)");
        _pin(ISVLaunchpad.openingFor.selector, "openingFor(address,address,uint256)");
        _pin(ISVLaunchpad.isAllowedLauncher.selector, "isAllowedLauncher(address)");
        _pin(ISVLaunchpad.launchesToday.selector, "launchesToday(address)");
        _pin(ISVLaunchpad.currency.selector, "currency(address)");
        _pin(ISVLaunchpad.owed.selector, "owed(address,address)");
        _pin(ISVLaunchpad.launchCount.selector, "launchCount()");
        _pin(ISVLaunchpad.feeWallet.selector, "feeWallet()");
        _pin(ISVLaunchpad.routerFeeBps.selector, "routerFeeBps()");
        _pin(ISVLaunchpad.creatorShareBps.selector, "creatorShareBps()");
        _pin(ISVLaunchpad.firstBuyCapBps.selector, "firstBuyCapBps()");
        _pin(ISVLaunchpad.dailyLaunchLimit.selector, "dailyLaunchLimit()");
        _pin(ISVLaunchpad.launcherGate.selector, "launcherGate()");
        _pin(ISVLaunchpad.hook.selector, "hook()");
        _pin(ISVLaunchpad.POOL_MANAGER.selector, "POOL_MANAGER()");
        _pin(ISVLaunchpad.PERMIT2.selector, "PERMIT2()");
    }
}
