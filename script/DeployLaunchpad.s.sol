// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {SVLaunchpad} from "../src/SVLaunchpad.sol";

/// @notice The two Chainlink reads the script makes; the proxies on Robinhood Chain answer both.
interface IChainlinkFeed {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Deploys SVLaunchpad on Robinhood Chain and allows every currency of
///         script/config/launch-currencies.json with its USD bounds converted to raw units (spec section 8.3).
/// @dev Not run before Kobe's review. The deployer key is never in the environment: pass it to forge with
///      --account, --ledger or --interactive. Dry run first on a local anvil fork of chain 4663, then:
///
///        forge script script/DeployLaunchpad.s.sol --rpc-url robinhood --account <name> --broadcast
///
///      The broadcaster deploys with itself as owner, allows every currency, then hands ownership to OWNER, who
///      must call acceptOwnership (Ownable2Step). The script refuses any chain but 4663 and a PoolManager or
///      Permit2 other than the chain's unless ALLOW_OTHER_ADDRESSES=true is set on purpose. Every row is priced
///      and checked before anything is broadcast.
contract DeployLaunchpad is Script {
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    address internal constant ROBINHOOD_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    /// @dev USDG, the one currency priced as USD 1 without a feed.
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    string internal constant CONFIG_PATH = "script/config/launch-currencies.json";
    /// @dev The app's own staleness window for Chainlink prices.
    uint256 internal constant MAX_FEED_AGE = 3 days;
    uint8 internal constant REFERENCE_DECIMALS = 8;
    /// @dev USD 0.01 and USD 100,000 per token at 8 decimals: a reference price outside is a typo.
    uint256 internal constant MIN_REFERENCE_PRICE = 1e6;
    uint256 internal constant MAX_REFERENCE_PRICE = 1e13;
    /// @dev SVLaunchpad's internal MIN_VALUATION and MAX_VALUATION (spec section 4.3).
    uint256 internal constant MIN_VALUATION = 1e8;
    uint256 internal constant MAX_VALUATION = 1e36;

    /// @notice One currency of the config.
    struct Row {
        address quote;
        string symbol;
        uint8 decimals;
        string priceSource; // "chainlink", "pinned" or "reference"
        address chainlinkProxy; // the zero address when none
        uint8 chainlinkDecimals; // 0 when none
        uint256 referenceUsdPrice; // 8 decimals; 0 when not filled
    }

    /// @notice The whole config.
    struct Config {
        uint256 minUsd;
        uint256 maxUsd;
        uint256 creationFee;
        Row[] rows;
    }

    function run() external returns (SVLaunchpad launchpad) {
        address owner = vm.envAddress("OWNER");
        address feeWallet = vm.envAddress("FEE_WALLET");
        address launcherGate = vm.envAddress("LAUNCHER_GATE");
        address poolManager = vm.envOr("POOL_MANAGER", ROBINHOOD_POOL_MANAGER);
        address permit2 = vm.envOr("PERMIT2", CANONICAL_PERMIT2);

        require(block.chainid == ROBINHOOD_CHAIN_ID, "not Robinhood Chain (chain id 4663): check --rpc-url");
        // The .env.example placeholder is the zero address; deploying with it would leave the broadcaster as owner.
        require(owner != address(0), "OWNER is zero: set it in .env");
        if (!vm.envOr("ALLOW_OTHER_ADDRESSES", false)) {
            require(
                poolManager == ROBINHOOD_POOL_MANAGER,
                "POOL_MANAGER is not the chain's PoolManager; set ALLOW_OTHER_ADDRESSES=true to override"
            );
            require(
                permit2 == CANONICAL_PERMIT2, "PERMIT2 is not the canonical Permit2; set ALLOW_OTHER_ADDRESSES=true"
            );
        }
        require(poolManager.code.length != 0, "POOL_MANAGER has no code on this chain");
        require(permit2.code.length != 0, "PERMIT2 has no code on this chain");
        if (launcherGate != address(0)) require(launcherGate.code.length != 0, "LAUNCHER_GATE has no code");

        // Reads only the config, under the one read-only fs_permissions entry `./script/config`.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        Config memory config = parseConfig(vm.readFile(CONFIG_PATH));
        (uint256[] memory mins, uint256[] memory maxs) = _allBounds(config);

        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();
        launchpad = new SVLaunchpad(
            IPoolManager(poolManager), ISignatureTransfer(permit2), broadcaster, feeWallet, launcherGate
        );
        for (uint256 i = 0; i < config.rows.length; i++) {
            launchpad.setCurrency(config.rows[i].quote, mins[i], maxs[i], config.creationFee);
        }
        if (owner != broadcaster) launchpad.transferOwnership(owner);
        vm.stopBroadcast();

        _print(launchpad, config, mins, maxs, owner);
    }

    /// @notice The canonical config written by the frontend's generator.
    function parseConfig(string memory json) public view returns (Config memory c) {
        c.minUsd = vm.parseJsonUint(json, ".minUsd");
        c.maxUsd = vm.parseJsonUint(json, ".maxUsd");
        require(c.minUsd < c.maxUsd, "minUsd must be below maxUsd");
        c.creationFee = vm.parseUint(vm.parseJsonString(json, ".creationFee"));
        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".currencies[", vm.toString(n), "]"))) {
            n++;
        }
        require(n != 0, "the config has no currencies");
        c.rows = new Row[](n);
        for (uint256 i = 0; i < n; i++) {
            c.rows[i] = _parseRow(json, string.concat(".currencies[", vm.toString(i), "]"));
            for (uint256 j = 0; j < i; j++) {
                require(c.rows[j].quote != c.rows[i].quote, string.concat(c.rows[i].symbol, ": duplicate address"));
            }
        }
    }

    /// @notice A row's USD price per whole token as an integer `answer` with `feedDecimals` decimals.
    function priceOf(Row memory row) public view returns (uint256 answer, uint8 feedDecimals) {
        bytes32 source = keccak256(bytes(row.priceSource));
        if (source == keccak256("pinned")) {
            require(row.quote == USDG, string.concat(row.symbol, ": priceSource pinned is only for the USDG address"));
            return (1, 0);
        }
        if (source == keccak256("chainlink")) {
            require(
                row.chainlinkProxy != address(0),
                string.concat(row.symbol, ": priceSource chainlink without a chainlinkProxy")
            );
            IChainlinkFeed feed = IChainlinkFeed(row.chainlinkProxy);
            require(
                feed.decimals() == row.chainlinkDecimals,
                string.concat(row.symbol, ": chainlinkDecimals differ from the feed's decimals()")
            );
            (, int256 a,, uint256 updatedAt,) = feed.latestRoundData();
            require(a > 0, string.concat(row.symbol, ": the feed answer is not positive"));
            require(updatedAt <= block.timestamp, string.concat(row.symbol, ": the feed's updatedAt is in the future"));
            require(
                block.timestamp - updatedAt <= MAX_FEED_AGE,
                string.concat(row.symbol, ": the feed is older than 3 days")
            );
            // `a` was checked positive just above, so the cast to uint256 is exact.
            // forge-lint: disable-next-line(unsafe-typecast)
            return (uint256(a), row.chainlinkDecimals);
        }
        if (source == keccak256("reference")) {
            require(row.referenceUsdPrice > 0, string.concat(row.symbol, ": referenceUsdPrice is not filled in"));
            require(
                row.referenceUsdPrice >= MIN_REFERENCE_PRICE && row.referenceUsdPrice <= MAX_REFERENCE_PRICE,
                string.concat(row.symbol, ": referenceUsdPrice outside USD 0.01 to 100,000 per token")
            );
            return (row.referenceUsdPrice, REFERENCE_DECIMALS);
        }
        revert(string.concat(row.symbol, ": unknown priceSource"));
    }

    /// @notice Spec section 8.3, in integers, rounded down:
    ///         `bound = usd * 10^quoteDecimals * 10^feedDecimals / answer`.
    function bounds(uint256 minUsd, uint256 maxUsd, uint8 quoteDecimals, uint256 answer, uint8 feedDecimals)
        public
        pure
        returns (uint256 minValuation, uint256 maxValuation)
    {
        uint256 scale = 10 ** (uint256(quoteDecimals) + feedDecimals);
        minValuation = minUsd * scale / answer;
        maxValuation = maxUsd * scale / answer;
    }

    /// @notice The USD value of `raw` quote units for the printout, rounded up. A bound is rounded down from a whole
    ///         USD amount, so rounding its value up reads that amount back: USD 5,000 prints 5,000, not 4,999.
    function usdOf(uint256 raw, uint8 quoteDecimals, uint256 answer, uint8 feedDecimals) public pure returns (uint256) {
        uint256 scale = 10 ** (uint256(quoteDecimals) + feedDecimals);
        return (raw * answer + scale - 1) / scale;
    }

    function _parseRow(string memory json, string memory at) internal view returns (Row memory row) {
        row.quote = vm.parseJsonAddress(json, string.concat(at, ".address"));
        row.symbol = vm.parseJsonString(json, string.concat(at, ".symbol"));
        // ERC-20 and Chainlink decimals fit uint8 by definition; the script checks both against the chain.
        // forge-lint: disable-next-line(unsafe-typecast)
        row.decimals = uint8(vm.parseJsonUint(json, string.concat(at, ".decimals")));
        row.priceSource = vm.parseJsonString(json, string.concat(at, ".priceSource"));
        row.chainlinkProxy = vm.parseJsonAddress(json, string.concat(at, ".chainlinkProxy"));
        // forge-lint: disable-next-line(unsafe-typecast)
        row.chainlinkDecimals = uint8(vm.parseJsonUint(json, string.concat(at, ".chainlinkDecimals")));
        row.referenceUsdPrice = vm.parseUint(vm.parseJsonString(json, string.concat(at, ".referenceUsdPrice")));
        // Optional in the schema; when present it must match the 8 decimals the script reads the price at.
        string memory decimalsKey = string.concat(at, ".referencePriceDecimals");
        if (vm.keyExistsJson(json, decimalsKey)) {
            require(
                vm.parseJsonUint(json, decimalsKey) == REFERENCE_DECIMALS,
                string.concat(row.symbol, ": referencePriceDecimals must be 8")
            );
        }
    }

    /// @dev Every row priced, converted and checked before anything is broadcast, so a bad row stops the run
    ///      with nothing deployed.
    function _allBounds(Config memory config) internal view returns (uint256[] memory mins, uint256[] memory maxs) {
        mins = new uint256[](config.rows.length);
        maxs = new uint256[](config.rows.length);
        for (uint256 i = 0; i < config.rows.length; i++) {
            Row memory row = config.rows[i];
            require(
                IERC20Metadata(row.quote).decimals() == row.decimals,
                string.concat(row.symbol, ": decimals differ from the token on chain")
            );
            (uint256 answer, uint8 feedDecimals) = priceOf(row);
            (mins[i], maxs[i]) = bounds(config.minUsd, config.maxUsd, row.decimals, answer, feedDecimals);
            require(mins[i] <= maxs[i], string.concat(row.symbol, ": converted minimum above the maximum"));
            require(
                mins[i] >= MIN_VALUATION && maxs[i] <= MAX_VALUATION,
                string.concat(row.symbol, ": bounds outside 1e8 to 1e36 raw units")
            );
        }
    }

    function _print(
        SVLaunchpad launchpad,
        Config memory config,
        uint256[] memory mins,
        uint256[] memory maxs,
        address owner
    ) internal view {
        console.log("SVLaunchpad deployed at:", address(launchpad));
        for (uint256 i = 0; i < config.rows.length; i++) {
            (uint256 answer, uint8 feedDecimals) = priceOf(config.rows[i]);
            uint8 quoteDecimals = config.rows[i].decimals;
            console.log(config.rows[i].symbol, config.rows[i].priceSource);
            console.log("  USD per token", answer, "with decimals", feedDecimals);
            console.log("  min raw", mins[i], "USD", usdOf(mins[i], quoteDecimals, answer, feedDecimals));
            console.log("  max raw", maxs[i], "USD", usdOf(maxs[i], quoteDecimals, answer, feedDecimals));
        }
        console.log("  owner now:      ", launchpad.owner());
        console.log("  pending owner:  ", launchpad.pendingOwner());
        console.log("  intended owner: ", owner);
        console.log("  fee wallet:     ", launchpad.feeWallet());
        console.log("  router fee bps: ", launchpad.routerFeeBps());
        console.log("  creator share:  ", launchpad.creatorShareBps());
        console.log("  first-buy cap:  ", launchpad.firstBuyCapBps());
        console.log("  daily limit:    ", launchpad.dailyLaunchLimit());
        console.log("  launcher gate:  ", launchpad.launcherGate());
        console.log("  hook:           ", launchpad.hook());
        console.log("  creation fee:   ", config.creationFee);
        console.log("  currencies:     ", config.rows.length);
    }
}
