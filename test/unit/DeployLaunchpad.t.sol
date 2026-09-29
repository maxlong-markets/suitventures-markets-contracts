// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployLaunchpad} from "../../script/DeployLaunchpad.s.sol";
import {MockChainlinkAggregator} from "../mocks/MockChainlinkAggregator.sol";

/// @notice The deploy script's pure parts (spec section 8.3): the canonical config shape, the three price sources
///         with every refusal, and the USD to raw-unit conversion. `run()` needs Robinhood Chain and is exercised by
///         Kobe's dry run on a fork.
contract DeployLaunchpadTest is Test {
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    DeployLaunchpad internal script;
    MockChainlinkAggregator internal feed;

    function setUp() public {
        vm.warp(1_790_000_000);
        script = new DeployLaunchpad();
        feed = new MockChainlinkAggregator(8);
        feed.set(250e8, block.timestamp - 1 hours);
    }

    /// @dev Exactly what the frontend generator writes, one row of each price source.
    function _generatorOutput() internal view returns (string memory) {
        return string.concat(
            '{"minUsd":5000,"maxUsd":10000000,"creationFee":"0","currencies":[',
            '{"address":"0x5fc5360d0400a0fd4f2af552add042d716f1d168","symbol":"USDG","decimals":6,',
            '"priceSource":"pinned","chainlinkProxy":"0x0000000000000000000000000000000000000000",',
            '"chainlinkDecimals":0,"referenceUsdPrice":"0"},',
            '{"address":"0xaf3d76f1834a1d425780943c99ea8a608f8a93f9","symbol":"AAPL","decimals":18,',
            '"priceSource":"chainlink","chainlinkProxy":"',
            vm.toString(address(feed)),
            '","chainlinkDecimals":8,"referenceUsdPrice":"0"},',
            '{"address":"0x05a3d1cd21d0c88145e82600e62e7e496e0f222b","symbol":"AMC","decimals":18,',
            '"priceSource":"reference","chainlinkProxy":"0x0000000000000000000000000000000000000000",',
            '"chainlinkDecimals":0,"referenceUsdPrice":"300000000"}]}'
        );
    }

    function test_parses_the_generator_output() public view {
        DeployLaunchpad.Config memory c = script.parseConfig(_generatorOutput());
        assertEq(c.minUsd, 5_000, "minUsd");
        assertEq(c.maxUsd, 10_000_000, "maxUsd");
        assertEq(c.creationFee, 0, "creationFee from its string");
        assertEq(c.rows.length, 3, "three rows");
        assertEq(c.rows[0].quote, USDG, "USDG address");
        assertEq(c.rows[0].decimals, 6, "USDG decimals");
        assertEq(c.rows[0].priceSource, "pinned", "USDG is pinned");
        assertEq(c.rows[0].chainlinkProxy, address(0), "the zero address means no proxy");
        assertEq(c.rows[1].symbol, "AAPL", "symbol");
        assertEq(c.rows[1].priceSource, "chainlink", "AAPL has a feed");
        assertEq(c.rows[1].chainlinkProxy, address(feed), "the proxy");
        assertEq(c.rows[1].chainlinkDecimals, 8, "the feed decimals");
        assertEq(c.rows[1].referenceUsdPrice, 0, "\"0\" reads as not filled");
        assertEq(c.rows[2].priceSource, "reference", "AMC is priced by reference");
        assertEq(c.rows[2].referenceUsdPrice, 3e8, "USD 3 as an 8-decimal integer");
    }

    /// @dev Reads through the one fs_permissions entry, so it also proves the permission.
    function test_the_example_config_in_script_config_parses() public view {
        // Reads only the example config, under the one read-only fs_permissions entry `./script/config`.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile("script/config/launch-currencies.example.json");
        DeployLaunchpad.Config memory c = script.parseConfig(json);
        assertEq(c.rows.length, 3, "three example rows");
        assertEq(c.rows[0].priceSource, "pinned", "USDG pinned");
        assertEq(c.rows[1].chainlinkProxy, 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0, "AAPL's Chainlink proxy");
        assertEq(c.rows[2].referenceUsdPrice, 0, "AMC's reference price not filled yet");
    }

    function test_parseConfig_refuses_a_minUsd_not_below_maxUsd() public {
        vm.expectRevert(bytes("minUsd must be below maxUsd"));
        script.parseConfig('{"minUsd":5000,"maxUsd":5000,"creationFee":"0","currencies":[]}');
    }

    function test_priceOf_prices_each_source() public view {
        DeployLaunchpad.Config memory c = script.parseConfig(_generatorOutput());
        (uint256 answer, uint8 feedDecimals) = script.priceOf(c.rows[0]);
        assertEq(answer, 1, "pinned is USD 1");
        assertEq(feedDecimals, 0, "with no decimals");
        (answer, feedDecimals) = script.priceOf(c.rows[1]);
        assertEq(answer, 250e8, "the feed's answer");
        assertEq(feedDecimals, 8, "the feed's decimals");
        (answer, feedDecimals) = script.priceOf(c.rows[2]);
        assertEq(answer, 3e8, "the reference price");
        assertEq(feedDecimals, 8, "at 8 decimals");
    }

    function test_priceOf_refuses_a_bad_feed() public {
        DeployLaunchpad.Row memory row = script.parseConfig(_generatorOutput()).rows[1];
        feed.set(250e8, block.timestamp - 3 days - 1);
        vm.expectRevert(bytes("AAPL: the feed is older than 3 days"));
        script.priceOf(row);
        feed.set(250e8, block.timestamp + 1);
        vm.expectRevert(bytes("AAPL: the feed's updatedAt is in the future"));
        script.priceOf(row);
        feed.set(0, block.timestamp);
        vm.expectRevert(bytes("AAPL: the feed answer is not positive"));
        script.priceOf(row);
        feed.set(250e8, block.timestamp);
        row.chainlinkDecimals = 18;
        vm.expectRevert(bytes("AAPL: chainlinkDecimals differ from the feed's decimals()"));
        script.priceOf(row);
        row.chainlinkProxy = address(0);
        vm.expectRevert(bytes("AAPL: priceSource chainlink without a chainlinkProxy"));
        script.priceOf(row);
        row.priceSource = "oracle";
        vm.expectRevert(bytes("AAPL: unknown priceSource"));
        script.priceOf(row);
    }

    function test_priceOf_refuses_an_unfilled_or_implausible_reference_price() public {
        DeployLaunchpad.Row memory row = script.parseConfig(_generatorOutput()).rows[2];
        row.referenceUsdPrice = 0;
        vm.expectRevert(bytes("AMC: referenceUsdPrice is not filled in"));
        script.priceOf(row);
        row.referenceUsdPrice = 1e6 - 1;
        vm.expectRevert(bytes("AMC: referenceUsdPrice outside USD 0.01 to 100,000 per token"));
        script.priceOf(row);
        row.referenceUsdPrice = 1e13 + 1;
        vm.expectRevert(bytes("AMC: referenceUsdPrice outside USD 0.01 to 100,000 per token"));
        script.priceOf(row);
        row.referenceUsdPrice = 1e6;
        (uint256 answer,) = script.priceOf(row);
        assertEq(answer, 1e6, "USD 0.01 itself is accepted");
        row.referenceUsdPrice = 1e13;
        (answer,) = script.priceOf(row);
        assertEq(answer, 1e13, "USD 100,000 itself is accepted");
    }

    function test_bounds_convert_the_usd_range_to_raw_units_rounded_down() public view {
        (uint256 minValuation, uint256 maxValuation) = script.bounds(5_000, 10_000_000, 6, 1, 0);
        assertEq(minValuation, 5_000e6, "USDG minimum");
        assertEq(maxValuation, 10_000_000e6, "USDG maximum");
        (minValuation, maxValuation) = script.bounds(5_000, 10_000_000, 18, 250e8, 8);
        assertEq(minValuation, 20e18, "USD 5,000 of a USD 250 stock is 20 tokens");
        assertEq(maxValuation, 40_000e18, "USD 10,000,000 is 40,000 tokens");
        (minValuation,) = script.bounds(5_000, 10_000_000, 18, 3e8, 8);
        assertEq(minValuation, 1_666_666_666_666_666_666_666, "rounded down");
    }
}
