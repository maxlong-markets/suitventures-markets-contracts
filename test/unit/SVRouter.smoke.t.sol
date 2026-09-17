// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {SVRouter} from "../../src/SVRouter.sol";
import {ISVRouter} from "../../src/interfaces/ISVRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC721} from "../mocks/MockERC721.sol";
import {MockERC721ShortReply} from "../mocks/MockERC721ShortReply.sol";
import {MockUniversalRouter} from "../mocks/MockUniversalRouter.sol";
import {Permit2Signer} from "../utils/Permit2Signer.sol";

/// @dev A Suits NFT whose `balanceOf` reverts, to show the router treats it as "no holder".
contract RevertingNFT {
    function balanceOf(address) external pure returns (uint256) {
        revert("RevertingNFT");
    }
}

/// @notice Smoke test: the router deploys with the spec's defaults and completes one buy through the mock router.
///         The full unit suite lives in SVRouter.t.sol and SVRouter.fuzz.t.sol.
contract SVRouterSmokeTest is Test {
    uint256 internal constant USER_KEY = 0xA11CE;
    uint128 internal constant AMOUNT_IN = 1_000e18;
    /// @dev What the caller demands and what the pool pays, deliberately different and in this order, so that
    ///      a router reporting `amountOutMin` instead of the measured output would fail the assertions below.
    uint128 internal constant MIN_OUT = 3e18;
    uint128 internal constant OUTPUT = 4e18;

    address internal user;
    address internal owner;
    address internal feeWallet;
    address internal permit2;

    MockERC20 internal token0;
    MockERC20 internal token1;
    MockERC721 internal nft;
    MockUniversalRouter internal universalRouter;
    SVRouter internal router;
    PoolKey internal key;

    function setUp() public {
        user = vm.addr(USER_KEY);
        owner = makeAddr("owner");
        feeWallet = makeAddr("feeWallet");

        // The real Permit2, etched at its canonical address from the bytecode shipped in its repository.
        permit2 = new DeployPermit2().deployPermit2();

        MockERC20 a = new MockERC20("Token A", "A", 18);
        MockERC20 b = new MockERC20("Token B", "B", 18);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            // A non-zero hook, as every real pool has: the `key.hooks` assertion below would be vacuous
            // against address(0). The mock never calls it, so it needs no code.
            hooks: IHooks(makeAddr("pool hook"))
        });

        nft = new MockERC721();
        universalRouter = new MockUniversalRouter(makeAddr("poolManager"));
        router = new SVRouter(owner, feeWallet, address(universalRouter), permit2, address(nft));

        token0.mint(user, AMOUNT_IN);
        vm.prank(user);
        token0.approve(permit2, type(uint256).max);
    }

    function test_deploys_with_the_spec_defaults() public view {
        assertEq(permit2, 0x000000000022D473030F116dDEE9F6B43aC78BA3, "Permit2 at its canonical address");
        assertEq(router.owner(), owner, "owner");
        assertEq(router.feeWallet(), feeWallet, "fee wallet");
        assertEq(router.feeBps(), 50, "feeBps at deploy");
        assertEq(router.holderFeeBps(), 0, "holderFeeBps at deploy");
        assertEq(router.suitsNft(), address(nft), "suits nft");
        assertEq(address(router.UNIVERSAL_ROUTER()), address(universalRouter), "universal router");
        assertEq(address(router.PERMIT2()), permit2, "permit2");
        assertEq(router.MAX_FEE_BPS(), 50, "MAX_FEE_BPS");
    }

    function test_buy_takes_the_fee_and_pays_the_user_through_the_router() public {
        uint256 fee = AMOUNT_IN * 50 / 10_000; // 0.5 % of the input, rounded down: 5e18
        uint256 net = AMOUNT_IN - fee;
        universalRouter.setOutput(address(token1), OUTPUT);
        (ISVRouter.SwapParams memory p, ISignatureTransfer.PermitTransferFrom memory permit, bytes memory signature) =
            _signedBuy(0);

        vm.expectEmit(true, true, true, true, address(router));
        emit ISVRouter.Trade(
            user, PoolId.unwrap(key.toId()), address(token0), address(token1), AMOUNT_IN, fee, OUTPUT, false
        );
        vm.prank(user);
        uint256 amountOut = router.swapExactIn(p, permit, signature);

        assertEq(amountOut, OUTPUT, "returned amountOut");
        assertEq(token0.balanceOf(feeWallet), fee, "fee in the fee wallet");
        assertEq(token0.balanceOf(address(universalRouter)), net, "net in the mock router");
        assertEq(token1.balanceOf(user), OUTPUT, "output at the user");
        assertEq(token0.balanceOf(user), 0, "the user paid amountIn");
        assertEq(token0.balanceOf(address(router)), 0, "router holds no tokenIn");
        assertEq(token1.balanceOf(address(router)), 0, "router holds no tokenOut");
        assertEq(universalRouter.lastCommands(), abi.encodePacked(uint8(Commands.V4_SWAP)), "one V4_SWAP command");
        assertEq(universalRouter.lastInputs().length, 1, "one input");
        assertEq(universalRouter.lastDeadline(), p.deadline, "deadline forwarded");

        // Every field the mock decoded is what the spec says the router sends.
        MockUniversalRouter.RecordedSwap memory s = universalRouter.lastSwapParams();
        assertEq(Currency.unwrap(s.key.currency0), address(token0), "key.currency0");
        assertEq(Currency.unwrap(s.key.currency1), address(token1), "key.currency1");
        assertEq(uint256(s.key.fee), uint256(key.fee), "key.fee");
        assertEq(int256(s.key.tickSpacing), int256(key.tickSpacing), "key.tickSpacing");
        assertEq(address(s.key.hooks), address(key.hooks), "key.hooks");
        assertTrue(s.zeroForOne, "zeroForOne");
        assertEq(s.amountIn, net, "swap amountIn is the net amount");
        assertEq(uint256(s.amountOutMinimum), uint256(MIN_OUT), "amountOutMinimum is the user's bound");
        assertEq(s.minHopPriceX36, 0, "per-hop price floor off");
        assertEq(s.hookData.length, 0, "hookData passed through");
        assertEq(s.settleCurrency, address(token0), "settle currency is tokenIn");
        assertEq(s.settleAmount, net, "settle amount is exactly net, not the open delta");
        assertFalse(s.settlePayerIsUser, "the router itself pays");
        assertEq(s.takeCurrency, address(token1), "take currency is tokenOut");
        assertEq(s.takeRecipient, user, "take recipient is the user");
        assertEq(s.takeAmount, uint256(ActionConstants.OPEN_DELTA), "take amount is the open delta");
    }

    function test_a_codeless_or_reverting_suits_nft_costs_the_holder_rate_not_the_trade() public {
        uint256 fullFee = AMOUNT_IN * 50 / 10_000;
        universalRouter.setOutput(address(token1), OUTPUT);

        vm.prank(owner);
        router.setSuitsNft(makeAddr("no-code"));
        (uint256 fee, bool holderRate) = router.feeFor(user, AMOUNT_IN);
        assertEq(fee, fullFee, "codeless NFT: full fee");
        assertFalse(holderRate, "codeless NFT: not a holder");

        RevertingNFT reverting = new RevertingNFT(); // deployed first: a creation would consume the prank
        vm.prank(owner);
        router.setSuitsNft(address(reverting));
        (fee, holderRate) = router.feeFor(user, AMOUNT_IN);
        assertEq(fee, fullFee, "reverting NFT: full fee");
        assertFalse(holderRate, "reverting NFT: not a holder");

        // The trade itself goes through with the reverting NFT configured.
        (ISVRouter.SwapParams memory p, ISignatureTransfer.PermitTransferFrom memory permit, bytes memory signature) =
            _signedBuy(0);
        vm.prank(user);
        assertEq(router.swapExactIn(p, permit, signature), OUTPUT, "the trade completes");
        assertEq(token0.balanceOf(feeWallet), fullFee, "full fee taken");

        // A real holder gets the holder rate.
        vm.prank(owner);
        router.setSuitsNft(address(nft));
        nft.mint(user, 1);
        (fee, holderRate) = router.feeFor(user, AMOUNT_IN);
        assertEq(fee, 0, "holder: holderFeeBps is 0 at deploy");
        assertTrue(holderRate, "holder rate applies");
    }

    function test_a_short_reply_suits_nft_costs_the_holder_rate_not_the_trade() public {
        uint256 fullFee = AMOUNT_IN * 50 / 10_000;
        universalRouter.setOutput(address(token1), OUTPUT);
        MockERC721ShortReply shortReply = new MockERC721ShortReply(); // deployed before the prank
        vm.prank(owner);
        router.setSuitsNft(address(shortReply));

        (uint256 fee, bool holderRate) = router.feeFor(user, AMOUNT_IN);
        assertEq(fee, fullFee, "short reply: full fee");
        assertFalse(holderRate, "short reply: not a holder");

        (ISVRouter.SwapParams memory p, ISignatureTransfer.PermitTransferFrom memory permit, bytes memory signature) =
            _signedBuy(0);
        vm.prank(user);
        assertEq(router.swapExactIn(p, permit, signature), OUTPUT, "the trade completes");
        assertEq(token0.balanceOf(feeWallet), fullFee, "at the normal fee");
    }

    function test_renounce_ownership_is_disabled() public {
        vm.prank(owner);
        vm.expectRevert(ISVRouter.RenounceDisabled.selector);
        router.renounceOwnership();
        assertEq(router.owner(), owner, "still owned");
    }

    function test_sweep_needs_a_recipient_and_emits_swept() public {
        token1.mint(address(router), 7e18);

        vm.prank(owner);
        vm.expectRevert(ISVRouter.ZeroAddress.selector);
        router.sweep(address(token1), address(0), 7e18);

        vm.expectEmit(true, true, true, true, address(router));
        emit ISVRouter.Swept(address(token1), owner, 7e18);
        vm.prank(owner);
        router.sweep(address(token1), owner, 7e18);
        assertEq(token1.balanceOf(owner), 7e18, "swept to the owner");
        assertEq(token1.balanceOf(address(router)), 0, "router empty again");
    }

    /// @dev One buy of AMOUNT_IN token0 for at least MIN_OUT token1, signed by the user for this router.
    function _signedBuy(uint256 nonce)
        internal
        view
        returns (
            ISVRouter.SwapParams memory p,
            ISignatureTransfer.PermitTransferFrom memory permit,
            bytes memory signature
        )
    {
        p = ISVRouter.SwapParams({
            key: key,
            zeroForOne: true,
            amountIn: AMOUNT_IN,
            amountOutMin: MIN_OUT,
            hookData: "",
            deadline: block.timestamp + 1 hours
        });
        permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(token0), amount: AMOUNT_IN}),
            nonce: nonce,
            deadline: block.timestamp + 1 hours
        });
        signature = Permit2Signer.sign(USER_KEY, permit2, permit, address(router));
    }
}
