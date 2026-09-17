// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {SVRouter} from "../src/SVRouter.sol";

/// @notice Deploys SVRouter on Robinhood Chain from environment variables (see .env.example and the README).
/// @dev Not run before Kobe's review. The deployer key is never in the environment: pass it to forge with
///      --account, --ledger or --interactive. Example:
///
///        forge script script/Deploy.s.sol --rpc-url robinhood --account <name> --broadcast \
///          --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api
contract Deploy is Script {
    function run() external returns (SVRouter router) {
        address owner = vm.envAddress("OWNER");
        address feeWallet = vm.envAddress("FEE_WALLET");
        address universalRouter = vm.envAddress("UNIVERSAL_ROUTER");
        address permit2 = vm.envAddress("PERMIT2");
        address suitsNft = vm.envOr("SUITS_NFT", address(0));

        // The two counterparties must exist on the target chain; this also catches a wrong --rpc-url.
        require(universalRouter.code.length != 0, "UNIVERSAL_ROUTER has no code on this chain");
        require(permit2.code.length != 0, "PERMIT2 has no code on this chain");

        vm.startBroadcast();
        router = new SVRouter(owner, feeWallet, universalRouter, permit2, suitsNft);
        vm.stopBroadcast();

        console.log("SVRouter deployed at:", address(router));
        console.log("  chain id:        ", block.chainid);
        console.log("  owner:           ", owner);
        console.log("  fee wallet:      ", feeWallet);
        console.log("  universal router:", universalRouter);
        console.log("  permit2:         ", permit2);
        console.log("  suits nft:       ", suitsNft);
    }
}
