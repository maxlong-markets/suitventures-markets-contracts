// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {SVRouter} from "../../src/SVRouter.sol";
import {ISVRouter} from "../../src/interfaces/ISVRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC721} from "../mocks/MockERC721.sol";
import {MockUniversalRouter} from "../mocks/MockUniversalRouter.sol";
import {Permit2Signer} from "../utils/Permit2Signer.sol";

/// @notice Smoke test: the router deploys with the spec's defaults and completes one buy through the mock router.
///         The full unit suite lives in SVRouter.t.sol and SVRouter.fuzz.t.sol.
contract SVRouterSmokeTest is Test {
    uint256 internal constant USER_KEY = 0xA11CE;
    uint128 internal constant AMOUNT_IN = 1_000e18;
    uint128 internal constant OUTPUT = 3e18;

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
            hooks: IHooks(address(0))
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

        ISVRouter.SwapParams memory p = ISVRouter.SwapParams({
            key: key,
            zeroForOne: true,
            amountIn: AMOUNT_IN,
            amountOutMin: OUTPUT,
            hookData: "",
            deadline: block.timestamp + 1 hours
        });
        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(token0), amount: AMOUNT_IN}),
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });
        bytes memory signature = Permit2Signer.sign(USER_KEY, permit2, permit, address(router));

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
    }
}
