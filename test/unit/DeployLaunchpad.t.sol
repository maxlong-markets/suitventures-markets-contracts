// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployLaunchpad} from "../../script/DeployLaunchpad.s.sol";
import {MockChainlinkAggregator} from "../mocks/MockChainlinkAggregator.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Exposes the script's internal pre-broadcast check to the tests.
contract DeployLaunchpadHarness is DeployLaunchpad {
    function allBounds(Config memory config) external view returns (uint256[] memory mins, uint256[] memory maxs) {
        return _allBounds(config);
    }
}

/// @notice The deploy script's pure parts (spec section 8.3): the canonical config shape, the three price sources
///         with every refusal, and the USD to raw-unit conversion. `run()` needs Robinhood Chain and is exercised by
///         Kobe's dry run on a fork.
contract DeployLaunchpadTest is Test {
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address internal constant AMC = 0x05a3d1Cd21d0C88145E82600E62e7E496e0F222B;
    DeployLaunchpadHarness internal script;
    MockChainlinkAggregator internal feed;

    function setUp() public {
        vm.warp(1_790_000_000);
        script = new DeployLaunchpadHarness();
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

    /// @dev One test, not two, because `vm.setEnv` writes the process environment that parallel tests share.
    ///      With OWNER set, the run gets past the owner guard and stops at the next one, which proves the order.
    function test_run_refuses_a_zero_OWNER_before_touching_the_config() public {
        vm.chainId(4663);
        // Sets one input of run() for this test; nothing else in the suite reads it.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("FEE_WALLET", vm.toString(makeAddr("feeWallet")));
        // Sets one input of run() for this test; nothing else in the suite reads it.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("LAUNCHER_GATE", vm.toString(address(0)));
        // Sets one input of run() for this test; nothing else in the suite reads it.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("OWNER", vm.toString(address(0)));
        vm.expectRevert(bytes("OWNER is zero: set it in .env"));
        script.run();
        // Sets one input of run() for this test; nothing else in the suite reads it.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("OWNER", vm.toString(makeAddr("owner")));
        vm.expectRevert(bytes("POOL_MANAGER has no code on this chain"));
        script.run();
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

    /// @dev One currencies entry of the canonical schema, with `extra` appended inside the object.
    function _row(string memory addr, string memory symbol, string memory source, string memory extra)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            '{"address":"',
            addr,
            '","symbol":"',
            symbol,
            '","decimals":18,"priceSource":"',
            source,
            '","chainlinkProxy":"0x0000000000000000000000000000000000000000","chainlinkDecimals":0,',
            '"referenceUsdPrice":"300000000"',
            extra,
            "}"
        );
    }

    function _config(string memory rows) internal pure returns (string memory) {
        return string.concat('{"minUsd":5000,"maxUsd":10000000,"creationFee":"0","currencies":[', rows, "]}");
    }

    function test_priceOf_refuses_pinned_for_any_token_but_USDG() public {
        DeployLaunchpad.Row memory row = script.parseConfig(_generatorOutput()).rows[0];
        row.quote = AMC;
        row.symbol = "AMC";
        vm.expectRevert(bytes("AMC: priceSource pinned is only for the USDG address"));
        script.priceOf(row);
    }

    function test_parseConfig_refuses_a_config_with_no_currencies() public {
        vm.expectRevert(bytes("the config has no currencies"));
        script.parseConfig(_config(""));
    }

    function test_parseConfig_refuses_a_duplicate_address_naming_the_second_row() public {
        string memory amc = "0x05a3d1cd21d0c88145e82600e62e7e496e0f222b";
        // Same address in another letter case: addresses compare as values, not as strings.
        string memory amcUpper = "0x05A3d1Cd21D0c88145e82600e62E7e496E0f222B";
        vm.expectRevert(bytes("AMC2: duplicate address"));
        script.parseConfig(
            _config(string.concat(_row(amc, "AMC", "reference", ""), ",", _row(amcUpper, "AMC2", "reference", "")))
        );
    }

    function test_parseConfig_accepts_referencePriceDecimals_of_8_and_refuses_any_other() public {
        string memory amc = "0x05a3d1cd21d0c88145e82600e62e7e496e0f222b";
        DeployLaunchpad.Config memory c =
            script.parseConfig(_config(_row(amc, "AMC", "reference", ',"referencePriceDecimals":8')));
        assertEq(c.rows[0].referenceUsdPrice, 3e8, "8 is the only accepted value");
        vm.expectRevert(bytes("AMC: referencePriceDecimals must be 8"));
        script.parseConfig(_config(_row(amc, "AMC", "reference", ',"referencePriceDecimals":6')));
    }

    function test_allBounds_checks_every_row_against_the_chain_before_broadcast() public {
        vm.etch(USDG, address(new MockERC20("Global Dollar", "USDG", 6)).code);
        vm.etch(AAPL, address(new MockERC20("Apple", "AAPL", 18)).code);
        vm.etch(AMC, address(new MockERC20("AMC", "AMC", 18)).code);
        DeployLaunchpad.Config memory c = script.parseConfig(_generatorOutput());
        (uint256[] memory mins, uint256[] memory maxs) = script.allBounds(c);
        assertEq(mins[0], 5_000e6, "USDG minimum");
        assertEq(maxs[1], 40_000e18, "AAPL maximum");

        c.maxUsd = 1e30;
        vm.expectRevert(bytes("AAPL: bounds outside 1e8 to 1e36 raw units"));
        script.allBounds(c);

        c.maxUsd = 10_000_000;
        vm.etch(AMC, address(new MockERC20("AMC", "AMC", 6)).code);
        vm.expectRevert(bytes("AMC: decimals differ from the token on chain"));
        script.allBounds(c);
    }

    function test_usdOf_rounds_the_printed_value_up_so_a_converted_bound_reads_back_whole() public view {
        (uint256 minValuation,) = script.bounds(5_000, 10_000_000, 18, 3e8, 8);
        assertEq(minValuation * 3e8 / 1e26, 4_999, "a plain floor would print 4,999");
        assertEq(script.usdOf(minValuation, 18, 3e8, 8), 5_000, "rounded up it prints 5,000");
        assertEq(script.usdOf(5_000e6, 6, 1, 0), 5_000, "an exact bound is unchanged");
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
