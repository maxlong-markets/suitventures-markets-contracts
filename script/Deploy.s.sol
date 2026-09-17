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
///
///      The script refuses any chain but Robinhood Chain, and any router or Permit2 address but the spec's
///      constants unless ALLOW_OTHER_ADDRESSES=true is set on purpose.
contract Deploy is Script {
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    address internal constant ROBINHOOD_UNIVERSAL_ROUTER = 0x06AfBA43Fd06227fA663b0DAecF536f6EaA6bf99;
    address internal constant CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function run() external returns (SVRouter router) {
        address owner = vm.envAddress("OWNER");
        address feeWallet = vm.envAddress("FEE_WALLET");
        address universalRouter = vm.envAddress("UNIVERSAL_ROUTER");
        address permit2 = vm.envAddress("PERMIT2");
        address suitsNft = vm.envOr("SUITS_NFT", address(0));

        require(block.chainid == ROBINHOOD_CHAIN_ID, "not Robinhood Chain (chain id 4663): check --rpc-url");
        if (!vm.envOr("ALLOW_OTHER_ADDRESSES", false)) {
            require(
                universalRouter == ROBINHOOD_UNIVERSAL_ROUTER,
                "UNIVERSAL_ROUTER is not the spec's router; set ALLOW_OTHER_ADDRESSES=true to override"
            );
            require(
                permit2 == CANONICAL_PERMIT2, "PERMIT2 is not the canonical Permit2; set ALLOW_OTHER_ADDRESSES=true"
            );
        }
        // The two counterparties must exist on the target chain.
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
