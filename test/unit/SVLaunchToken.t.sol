// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SVLaunchToken} from "../../src/SVLaunchToken.sol";
import {ISVLaunchpad} from "../../src/interfaces/ISVLaunchpad.sol";

/// @notice The launch token (spec section 4.1), the event and error ABI of spec section 4.2 against its canonical
///         signatures, and the `solmate/` remapping that lets the unit suites deploy a local PoolManager.
contract SVLaunchTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    address internal recipient;

    function setUp() public {
        recipient = makeAddr("launchpad");
    }

    function test_constructor_mints_the_whole_supply_once_to_the_recipient_with_18_decimals() public {
        SVLaunchToken token = new SVLaunchToken("Launch Token", "LT", recipient);
        assertEq(token.name(), "Launch Token", "name");
        assertEq(token.symbol(), "LT", "symbol");
        assertEq(token.decimals(), 18, "18 decimals");
        assertEq(token.SUPPLY(), SUPPLY, "SUPPLY is one billion tokens");
        assertEq(token.totalSupply(), SUPPLY, "the whole supply exists");
        assertEq(token.balanceOf(recipient), SUPPLY, "and the recipient holds all of it");
    }

    function test_burn_reduces_the_supply_and_the_holder_balance() public {
        SVLaunchToken token = new SVLaunchToken("Launch Token", "LT", recipient);
        vm.prank(recipient);
        token.burn(1e18);
        assertEq(token.totalSupply(), SUPPLY - 1e18, "supply after the burn");
        assertEq(token.balanceOf(recipient), SUPPLY - 1e18, "balance after the burn");
    }

    /// @dev No owner, no mint, no pause: a call to any such selector finds no function and no fallback.
    function test_the_token_has_no_mint_owner_or_pause_entry_point() public {
        SVLaunchToken token = new SVLaunchToken("Launch Token", "LT", recipient);
        bytes4[4] memory forbidden = [
            bytes4(keccak256("mint(address,uint256)")),
            bytes4(keccak256("owner()")),
            bytes4(keccak256("pause()")),
            bytes4(keccak256("transferOwnership(address)"))
        ];
        for (uint256 i = 0; i < forbidden.length; i++) {
            (bool ok,) = address(token).call(abi.encodePacked(forbidden[i], abi.encode(recipient, uint256(1))));
            assertFalse(ok, "the token answered a selector it must not have");
        }
    }

    /// @dev The remapping added in this task: without `solmate/`, `PoolManager.sol` cannot resolve `Owned.sol`.
    function test_a_local_pool_manager_and_the_core_swap_router_deploy() public {
        IPoolManager manager = IPoolManager(address(new PoolManager(address(this))));
        PoolSwapTest router = new PoolSwapTest(manager);
        assertGt(address(manager).code.length, 0, "the PoolManager compiled and deployed");
        assertGt(address(router).code.length, 0, "the core's swap test router deployed");
    }

    /// @dev The three activity events the reader indexes; the frontend pins the same three topic0 values.
    function test_the_activity_event_topics_match_the_spec_signatures() public pure {
        assertEq(
            ISVLaunchpad.Launched.selector,
            keccak256(
                "Launched(address,address,address,(bytes32,address,address,bool,int24,uint256,uint128,uint256,uint256,uint256,uint256,uint256,uint16,string,string,string))"
            ),
            "Launched"
        );
        assertEq(
            ISVLaunchpad.FeesCollected.selector,
            keccak256("FeesCollected(address,address,uint256,uint256,uint256,uint256)"),
            "FeesCollected"
        );
        assertEq(
            ISVLaunchpad.PayoutChanged.selector, keccak256("PayoutChanged(address,address,address)"), "PayoutChanged"
        );
    }

    function test_the_setting_event_topics_match_the_spec_signatures() public pure {
        assertEq(ISVLaunchpad.FeeWalletChanged.selector, keccak256("FeeWalletChanged(address)"), "FeeWalletChanged");
        assertEq(ISVLaunchpad.RouterFeeChanged.selector, keccak256("RouterFeeChanged(uint16)"), "RouterFeeChanged");
        assertEq(
            ISVLaunchpad.CreatorShareChanged.selector, keccak256("CreatorShareChanged(uint16)"), "CreatorShareChanged"
        );
        assertEq(
            ISVLaunchpad.FirstBuyCapChanged.selector, keccak256("FirstBuyCapChanged(uint16)"), "FirstBuyCapChanged"
        );
        assertEq(
            ISVLaunchpad.DailyLaunchLimitChanged.selector,
            keccak256("DailyLaunchLimitChanged(uint8)"),
            "DailyLaunchLimitChanged"
        );
        assertEq(
            ISVLaunchpad.LauncherGateChanged.selector, keccak256("LauncherGateChanged(address)"), "LauncherGateChanged"
        );
        assertEq(ISVLaunchpad.HookChanged.selector, keccak256("HookChanged(address)"), "HookChanged");
        assertEq(
            ISVLaunchpad.CurrencyChanged.selector,
            keccak256("CurrencyChanged(address,uint256,uint256,uint256)"),
            "CurrencyChanged"
        );
    }

    /// @dev The frontend decodes reverts by name from its own ABI; a wrong parameter list here would change the
    ///      selector it sees.
    function test_the_error_selectors_match_the_spec_signatures() public pure {
        assertEq(ISVLaunchpad.ZeroAddress.selector, bytes4(keccak256("ZeroAddress()")), "ZeroAddress");
        assertEq(ISVLaunchpad.RenounceDisabled.selector, bytes4(keccak256("RenounceDisabled()")), "RenounceDisabled");
        assertEq(ISVLaunchpad.Expired.selector, bytes4(keccak256("Expired()")), "Expired");
        assertEq(
            ISVLaunchpad.NotAllowedToLaunch.selector, bytes4(keccak256("NotAllowedToLaunch()")), "NotAllowedToLaunch"
        );
        assertEq(ISVLaunchpad.DailyLimitReached.selector, bytes4(keccak256("DailyLimitReached()")), "DailyLimitReached");
        assertEq(ISVLaunchpad.BadName.selector, bytes4(keccak256("BadName()")), "BadName");
        assertEq(ISVLaunchpad.BadSymbol.selector, bytes4(keccak256("BadSymbol()")), "BadSymbol");
        assertEq(ISVLaunchpad.UriTooLong.selector, bytes4(keccak256("UriTooLong()")), "UriTooLong");
        assertEq(
            ISVLaunchpad.CurrencyNotAllowed.selector, bytes4(keccak256("CurrencyNotAllowed()")), "CurrencyNotAllowed"
        );
        assertEq(
            ISVLaunchpad.ValuationOutOfRange.selector,
            bytes4(keccak256("ValuationOutOfRange(uint256,uint256,uint256)")),
            "ValuationOutOfRange"
        );
        assertEq(ISVLaunchpad.PermitMismatch.selector, bytes4(keccak256("PermitMismatch()")), "PermitMismatch");
        assertEq(
            ISVLaunchpad.FirstBuyTooLarge.selector,
            bytes4(keccak256("FirstBuyTooLarge(uint256,uint256)")),
            "FirstBuyTooLarge"
        );
        assertEq(
            ISVLaunchpad.FirstBuyTooSmall.selector,
            bytes4(keccak256("FirstBuyTooSmall(uint256,uint256)")),
            "FirstBuyTooSmall"
        );
        assertEq(ISVLaunchpad.BadPayout.selector, bytes4(keccak256("BadPayout()")), "BadPayout");
        assertEq(ISVLaunchpad.FeeTooHigh.selector, bytes4(keccak256("FeeTooHigh()")), "FeeTooHigh");
        assertEq(ISVLaunchpad.BpsTooHigh.selector, bytes4(keccak256("BpsTooHigh()")), "BpsTooHigh");
        assertEq(ISVLaunchpad.BoundsOutOfRange.selector, bytes4(keccak256("BoundsOutOfRange()")), "BoundsOutOfRange");
        assertEq(ISVLaunchpad.HookNotAllowed.selector, bytes4(keccak256("HookNotAllowed()")), "HookNotAllowed");
        assertEq(ISVLaunchpad.UnknownLaunch.selector, bytes4(keccak256("UnknownLaunch()")), "UnknownLaunch");
        assertEq(ISVLaunchpad.NotPayout.selector, bytes4(keccak256("NotPayout()")), "NotPayout");
        assertEq(ISVLaunchpad.NothingToCollect.selector, bytes4(keccak256("NothingToCollect()")), "NothingToCollect");
        assertEq(ISVLaunchpad.NothingOwed.selector, bytes4(keccak256("NothingOwed()")), "NothingOwed");
        assertEq(ISVLaunchpad.NotPoolManager.selector, bytes4(keccak256("NotPoolManager()")), "NotPoolManager");
        assertEq(
            ISVLaunchpad.UnexpectedCallback.selector, bytes4(keccak256("UnexpectedCallback()")), "UnexpectedCallback"
        );
    }
}
