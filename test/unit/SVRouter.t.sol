// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {SignatureVerification} from "permit2/src/libraries/SignatureVerification.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {SVRouter} from "../../src/SVRouter.sol";
import {ISVRouter} from "../../src/interfaces/ISVRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC721} from "../mocks/MockERC721.sol";
import {MockUniversalRouter} from "../mocks/MockUniversalRouter.sol";
import {Permit2Signer} from "../utils/Permit2Signer.sol";

/// @dev A Suits NFT whose `balanceOf` reverts. `feeFor` must read it as "not a holder" and let the trade run.
contract RevertingSuitsNft {
    error SuitsNftIsUnwell();

    function balanceOf(address) external pure returns (uint256) {
        revert SuitsNftIsUnwell();
    }
}

/// @notice Shared fixture for the unit suite: the real Permit2 etched at its canonical address, two sorted
///         MockERC20s as the pool's currencies, a MockERC721 as the Suits NFT (nobody holds one), the
///         MockUniversalRouter, and an SVRouter at the spec's deploy values. The fuzz suite inherits it too.
/// @dev The user is a `vm.addr` key so the tests can sign real Permit2 messages; no real wallet or key appears
///      anywhere. Both currencies are minted to the user and approved to Permit2, so either direction trades.
abstract contract SVRouterTestBase is Test {
    uint256 internal constant USER_KEY = 0xA11CE;
    uint256 internal constant STRANGER_KEY = 0xB0BB1E;

    /// @dev The standard trade of this suite, at the deploy rate of 50 bps.
    uint128 internal constant AMOUNT_IN = 1_000e18;
    uint128 internal constant FEE = AMOUNT_IN * 50 / 10_000; // 5e18
    uint128 internal constant NET = AMOUNT_IN - FEE; // 995e18
    uint128 internal constant OUTPUT = 3e18;
    uint256 internal constant MINT = 10_000e18;

    address internal user;
    address internal stranger;
    address internal owner;
    address internal feeWallet;
    address internal permit2;

    MockERC20 internal token0;
    MockERC20 internal token1;
    MockERC721 internal nft;
    MockUniversalRouter internal universalRouter;
    SVRouter internal router;
    PoolKey internal key;

    function setUp() public virtual {
        user = vm.addr(USER_KEY);
        stranger = vm.addr(STRANGER_KEY);
        vm.label(user, "user");
        vm.label(stranger, "stranger");
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

        token0.mint(user, MINT);
        token1.mint(user, MINT);
        vm.startPrank(user);
        token0.approve(permit2, type(uint256).max);
        token1.approve(permit2, type(uint256).max);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------------------------------------
    // Fixture helpers
    // -------------------------------------------------------------------------------------------------------

    /// @dev The two currencies of `key` in the order the direction pays and receives them.
    function _tokens(bool zeroForOne) internal view returns (MockERC20 tokenIn, MockERC20 tokenOut) {
        return zeroForOne ? (token0, token1) : (token1, token0);
    }

    function _swapParams(bool zeroForOne, uint128 amountIn, uint128 amountOutMin)
        internal
        view
        returns (ISVRouter.SwapParams memory)
    {
        return ISVRouter.SwapParams({
            key: key,
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            hookData: "",
            deadline: block.timestamp + 1 hours
        });
    }

    function _permitFor(address token, uint256 amount, uint256 nonce)
        internal
        view
        returns (ISignatureTransfer.PermitTransferFrom memory)
    {
        return ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: token, amount: amount}),
            nonce: nonce,
            deadline: block.timestamp + 1 hours
        });
    }

    /// @dev `privateKey` signs the permit for this router as the spender.
    function _sign(uint256 privateKey, ISignatureTransfer.PermitTransferFrom memory permit)
        internal
        view
        returns (bytes memory)
    {
        return Permit2Signer.sign(privateKey, permit2, permit, address(router));
    }

    /// @dev One whole trade in the fixture's standard shape: the user signs for exactly `amountIn` of the
    ///      input token at `nonce`, the mock router is told to pay `output` of the output token.
    function _trade(bool zeroForOne, uint128 amountIn, uint128 amountOutMin, uint128 output, uint256 nonce)
        internal
        returns (uint256 amountOut)
    {
        (MockERC20 tokenIn, MockERC20 tokenOut) = _tokens(zeroForOne);
        universalRouter.setOutput(address(tokenOut), output);
        ISVRouter.SwapParams memory p = _swapParams(zeroForOne, amountIn, amountOutMin);
        ISignatureTransfer.PermitTransferFrom memory permit = _permitFor(address(tokenIn), amountIn, nonce);
        bytes memory signature = _sign(USER_KEY, permit);
        vm.prank(user);
        return router.swapExactIn(p, permit, signature);
    }
}

/// @notice The unit suite for `src/SVRouter.sol`: the constructor, the owner settings, `feeFor`, `sweep` and
///         every path through `swapExactIn`, against the real Permit2 and the mock Universal Router.
/// @dev Design: docs/superpowers/specs/2026-09-17-svrouter-design.md, sections 3 to 6.
contract SVRouterTest is SVRouterTestBase {
    // -------------------------------------------------------------------------------------------------------
    // Constructor (spec section 5)
    // -------------------------------------------------------------------------------------------------------

    function test_constructor_stores_the_deploy_values() public view {
        assertEq(permit2, 0x000000000022D473030F116dDEE9F6B43aC78BA3, "Permit2 at its canonical address");
        assertEq(router.owner(), owner, "owner");
        assertEq(router.pendingOwner(), address(0), "no pending owner at deploy");
        assertEq(router.feeWallet(), feeWallet, "fee wallet");
        assertEq(router.feeBps(), 50, "feeBps at deploy");
        assertEq(router.holderFeeBps(), 0, "holderFeeBps at deploy");
        assertEq(router.suitsNft(), address(nft), "suits nft");
        assertEq(address(router.UNIVERSAL_ROUTER()), address(universalRouter), "universal router");
        assertEq(address(router.PERMIT2()), permit2, "permit2");
        assertEq(router.MAX_FEE_BPS(), 50, "MAX_FEE_BPS");
    }

    function test_constructor_emits_the_three_change_events() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));

        vm.expectEmit(true, true, true, true, predicted);
        emit ISVRouter.FeeWalletChanged(feeWallet);
        vm.expectEmit(true, true, true, true, predicted);
        emit ISVRouter.FeesChanged(50, 0);
        vm.expectEmit(true, true, true, true, predicted);
        emit ISVRouter.SuitsNftChanged(address(nft));
        SVRouter deployed = new SVRouter(owner, feeWallet, address(universalRouter), permit2, address(nft));

        assertEq(address(deployed), predicted, "the events came from the router just deployed");
    }

    function test_constructor_reverts_on_a_zero_owner() public {
        vm.expectRevert(ISVRouter.ZeroAddress.selector);
        new SVRouter(address(0), feeWallet, address(universalRouter), permit2, address(nft));
    }

    function test_constructor_reverts_on_a_zero_fee_wallet() public {
        vm.expectRevert(ISVRouter.ZeroAddress.selector);
        new SVRouter(owner, address(0), address(universalRouter), permit2, address(nft));
    }

    function test_constructor_reverts_on_a_zero_universal_router() public {
        vm.expectRevert(ISVRouter.ZeroAddress.selector);
        new SVRouter(owner, feeWallet, address(0), permit2, address(nft));
    }

    function test_constructor_reverts_on_a_zero_permit2() public {
        vm.expectRevert(ISVRouter.ZeroAddress.selector);
        new SVRouter(owner, feeWallet, address(universalRouter), address(0), address(nft));
    }

    function test_constructor_accepts_a_zero_suits_nft() public {
        nft.mint(user, 1); // even a holder of the real NFT pays the standard rate while none is configured
        SVRouter noPerk = new SVRouter(owner, feeWallet, address(universalRouter), permit2, address(0));

        assertEq(noPerk.suitsNft(), address(0), "no NFT configured");
        (uint256 fee, bool holderRate) = noPerk.feeFor(user, AMOUNT_IN);
        assertEq(fee, FEE, "standard rate");
        assertFalse(holderRate, "no holder rate without an NFT address");
    }

    // -------------------------------------------------------------------------------------------------------
    // setFeeWallet
    // -------------------------------------------------------------------------------------------------------

    function test_setFeeWallet_sets_the_wallet_and_emits() public {
        address newWallet = makeAddr("newFeeWallet");

        vm.expectEmit(true, true, true, true, address(router));
        emit ISVRouter.FeeWalletChanged(newWallet);
        vm.prank(owner);
        router.setFeeWallet(newWallet);

        assertEq(router.feeWallet(), newWallet, "fee wallet");
    }

    function test_setFeeWallet_reverts_on_the_zero_address() public {
        vm.expectRevert(ISVRouter.ZeroAddress.selector);
        vm.prank(owner);
        router.setFeeWallet(address(0));

        assertEq(router.feeWallet(), feeWallet, "unchanged");
    }

    function test_setFeeWallet_is_owner_only() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        router.setFeeWallet(stranger);

        assertEq(router.feeWallet(), feeWallet, "unchanged");
    }

    // -------------------------------------------------------------------------------------------------------
    // setFees
    // -------------------------------------------------------------------------------------------------------

    function test_setFees_sets_both_rates_and_emits() public {
        vm.expectEmit(true, true, true, true, address(router));
        emit ISVRouter.FeesChanged(30, 10);
        vm.prank(owner);
        router.setFees(30, 10);

        assertEq(router.feeBps(), 30, "feeBps");
        assertEq(router.holderFeeBps(), 10, "holderFeeBps");
    }

    function test_setFees_reverts_above_the_cap() public {
        vm.expectRevert(ISVRouter.FeeTooHigh.selector);
        vm.prank(owner);
        router.setFees(51, 0);

        assertEq(router.feeBps(), 50, "unchanged");
    }

    function test_setFees_reverts_when_the_holder_rate_exceeds_the_standard_rate() public {
        vm.expectRevert(ISVRouter.FeeTooHigh.selector);
        vm.prank(owner);
        router.setFees(20, 21);

        assertEq(router.feeBps(), 50, "unchanged");
        assertEq(router.holderFeeBps(), 0, "unchanged");
    }

    function test_setFees_allows_raising_back_to_the_cap_after_lowering() public {
        vm.startPrank(owner);
        router.setFees(0, 0);
        assertEq(router.feeBps(), 0, "lowered to zero");

        router.setFees(50, 50);
        vm.stopPrank();

        assertEq(router.feeBps(), 50, "back at the cap");
        assertEq(router.holderFeeBps(), 50, "holder rate may equal the standard rate");
    }

    function test_setFees_is_owner_only() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        router.setFees(0, 0);

        assertEq(router.feeBps(), 50, "unchanged");
    }

    // -------------------------------------------------------------------------------------------------------
    // setSuitsNft
    // -------------------------------------------------------------------------------------------------------

    function test_setSuitsNft_sets_the_address_and_emits() public {
        MockERC721 newNft = new MockERC721();

        vm.expectEmit(true, true, true, true, address(router));
        emit ISVRouter.SuitsNftChanged(address(newNft));
        vm.prank(owner);
        router.setSuitsNft(address(newNft));

        assertEq(router.suitsNft(), address(newNft), "suits nft");
    }

    function test_setSuitsNft_accepts_zero_and_disables_the_perk() public {
        nft.mint(user, 1);
        vm.prank(owner);
        router.setFees(50, 10);
        (, bool beforeZeroing) = router.feeFor(user, AMOUNT_IN);
        assertTrue(beforeZeroing, "the holder rate applied while the NFT was configured");

        vm.expectEmit(true, true, true, true, address(router));
        emit ISVRouter.SuitsNftChanged(address(0));
        vm.prank(owner);
        router.setSuitsNft(address(0));

        assertEq(router.suitsNft(), address(0), "perk off");
        (uint256 fee, bool holderRate) = router.feeFor(user, AMOUNT_IN);
        assertEq(fee, FEE, "standard rate again");
        assertFalse(holderRate, "no holder rate");
    }

    function test_setSuitsNft_is_owner_only() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        router.setSuitsNft(address(0));

        assertEq(router.suitsNft(), address(nft), "unchanged");
    }

    // -------------------------------------------------------------------------------------------------------
    // Ownable2Step (spec section 5: the Safe must accept at M5)
    // -------------------------------------------------------------------------------------------------------

    function test_ownership_transfer_takes_two_steps() public {
        address newOwner = makeAddr("newOwner");

        vm.expectEmit(true, true, true, true, address(router));
        emit Ownable2Step.OwnershipTransferStarted(owner, newOwner);
        vm.prank(owner);
        router.transferOwnership(newOwner);

        assertEq(router.owner(), owner, "owner unchanged until the transfer is accepted");
        assertEq(router.pendingOwner(), newOwner, "pending owner");

        // The pending owner has no powers yet, and nobody else may accept for them.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newOwner));
        vm.prank(newOwner);
        router.setFees(10, 0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        router.acceptOwnership();

        vm.expectEmit(true, true, true, true, address(router));
        emit Ownable.OwnershipTransferred(owner, newOwner);
        vm.prank(newOwner);
        router.acceptOwnership();

        assertEq(router.owner(), newOwner, "new owner");
        assertEq(router.pendingOwner(), address(0), "pending owner cleared");

        // The settings moved with the ownership: the old owner is out, the new one is in.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vm.prank(owner);
        router.setFees(10, 0);
        vm.prank(newOwner);
        router.setFees(10, 0);
        assertEq(router.feeBps(), 10, "the new owner sets the fee");
    }

    function test_renounceOwnership_is_disabled() public {
        vm.expectRevert(ISVRouter.RenounceDisabled.selector);
        vm.prank(owner);
        router.renounceOwnership();

        // The override has no access check of its own, and needs none: nobody can leave the router ownerless.
        vm.expectRevert(ISVRouter.RenounceDisabled.selector);
        vm.prank(stranger);
        router.renounceOwnership();

        assertEq(router.owner(), owner, "still owned");
        assertEq(router.pendingOwner(), address(0), "and no transfer started");
        vm.prank(owner);
        router.setFees(10, 0);
        assertEq(router.feeBps(), 10, "the owner still owns");
    }

    // -------------------------------------------------------------------------------------------------------
    // feeFor (spec section 4.3)
    // -------------------------------------------------------------------------------------------------------

    function test_feeFor_uses_the_standard_rate_when_no_nft_is_configured() public {
        vm.prank(owner);
        router.setSuitsNft(address(0));

        (uint256 fee, bool holderRate) = router.feeFor(user, AMOUNT_IN);
        assertEq(fee, FEE, "0.5 % of the input");
        assertFalse(holderRate, "standard rate");
    }

    function test_feeFor_uses_the_standard_rate_when_the_user_holds_no_nft() public view {
        assertEq(nft.balanceOf(user), 0, "the user holds none");

        (uint256 fee, bool holderRate) = router.feeFor(user, AMOUNT_IN);
        assertEq(fee, FEE, "0.5 % of the input");
        assertFalse(holderRate, "standard rate");
    }

    function test_feeFor_uses_the_holder_rate_when_the_user_holds_an_nft() public {
        vm.prank(owner);
        router.setFees(50, 20);
        nft.mint(user, 7);

        (uint256 fee, bool holderRate) = router.feeFor(user, AMOUNT_IN);
        assertEq(fee, AMOUNT_IN * 20 / 10_000, "0.2 % of the input");
        assertTrue(holderRate, "holder rate");
        (uint256 otherFee, bool otherHolderRate) = router.feeFor(stranger, AMOUNT_IN);
        assertEq(otherFee, FEE, "a non-holder still pays 0.5 %");
        assertFalse(otherHolderRate, "standard rate for the non-holder");
    }

    function test_feeFor_rounds_the_fee_down() public view {
        (uint256 feeOnOne,) = router.feeFor(user, 1);
        assertEq(feeOnOne, 0, "1 wei at 50 bps rounds to nothing");
        (uint256 feeOn199,) = router.feeFor(user, 199);
        assertEq(feeOn199, 0, "0.995 rounds down to 0");
        (uint256 feeOn200,) = router.feeFor(user, 200);
        assertEq(feeOn200, 1, "exactly 1");
        (uint256 feeOn12345,) = router.feeFor(user, 12_345);
        assertEq(feeOn12345, 61, "61.725 rounds down to 61");
        uint256 oddAmount = 1e18 + 1;
        (uint256 feeOnOdd,) = router.feeFor(user, oddAmount);
        assertEq(feeOnOdd, oddAmount * 50 / 10_000, "rounds down on an odd amount");
        assertEq(feeOnOdd, 5e15, "half a basis point of the odd wei is dropped");
    }

    function test_feeFor_uses_the_standard_rate_when_the_nft_call_reverts() public {
        // Deployed before the prank: a CREATE from this test would consume it.
        RevertingSuitsNft unwell = new RevertingSuitsNft();
        vm.prank(owner);
        router.setSuitsNft(address(unwell));

        (uint256 fee, bool holderRate) = router.feeFor(user, AMOUNT_IN);
        assertEq(fee, FEE, "the standard rate, and no revert out of feeFor");
        assertFalse(holderRate, "a reverting balanceOf is not a holder");
    }

    function test_feeFor_uses_the_standard_rate_when_the_nft_address_has_no_code() public {
        address noCode = makeAddr("an address with no code");
        vm.prank(owner);
        router.setSuitsNft(noCode);
        assertEq(noCode.code.length, 0, "the fixture's premise");

        (uint256 fee, bool holderRate) = router.feeFor(user, AMOUNT_IN);
        assertEq(fee, FEE, "the standard rate, and no revert out of feeFor");
        assertFalse(holderRate, "an address without code is not a holder");
    }

    // -------------------------------------------------------------------------------------------------------
    // swapExactIn: the happy paths (spec section 4)
    // -------------------------------------------------------------------------------------------------------

    function test_swapExactIn_buys_currency1_with_currency0() public {
        universalRouter.setOutput(address(token1), OUTPUT);
        ISVRouter.SwapParams memory p = _swapParams(true, AMOUNT_IN, OUTPUT);
        ISignatureTransfer.PermitTransferFrom memory permit = _permitFor(address(token0), AMOUNT_IN, 0);
        bytes memory signature = _sign(USER_KEY, permit);

        vm.expectEmit(true, true, true, true, address(router));
        emit ISVRouter.Trade(
            user, PoolId.unwrap(key.toId()), address(token0), address(token1), AMOUNT_IN, FEE, OUTPUT, false
        );
        vm.prank(user);
        uint256 amountOut = router.swapExactIn(p, permit, signature);

        assertEq(amountOut, OUTPUT, "returned amountOut");
        assertEq(token0.balanceOf(feeWallet), FEE, "fee in the fee wallet");
        assertEq(token0.balanceOf(address(universalRouter)), NET, "net in the mock router");
        assertEq(token1.balanceOf(user), MINT + OUTPUT, "output at the user");
        assertEq(token0.balanceOf(user), MINT - AMOUNT_IN, "the user paid amountIn, fee included");
        assertEq(token0.balanceOf(address(router)), 0, "the router holds no tokenIn");
        assertEq(token1.balanceOf(address(router)), 0, "the router holds no tokenOut");
        assertEq(token1.balanceOf(address(universalRouter)), 0, "the mock router kept no output");
    }

    function test_swapExactIn_sells_currency1_for_currency0() public {
        universalRouter.setOutput(address(token0), OUTPUT);
        ISVRouter.SwapParams memory p = _swapParams(false, AMOUNT_IN, OUTPUT);
        ISignatureTransfer.PermitTransferFrom memory permit = _permitFor(address(token1), AMOUNT_IN, 0);
        bytes memory signature = _sign(USER_KEY, permit);

        vm.expectEmit(true, true, true, true, address(router));
        emit ISVRouter.Trade(
            user, PoolId.unwrap(key.toId()), address(token1), address(token0), AMOUNT_IN, FEE, OUTPUT, false
        );
        vm.prank(user);
        uint256 amountOut = router.swapExactIn(p, permit, signature);

        assertEq(amountOut, OUTPUT, "returned amountOut");
        assertEq(token1.balanceOf(feeWallet), FEE, "fee in the fee wallet, in the token sold");
        assertEq(token1.balanceOf(address(universalRouter)), NET, "net in the mock router");
        assertEq(token0.balanceOf(user), MINT + OUTPUT, "output at the user");
        assertEq(token1.balanceOf(user), MINT - AMOUNT_IN, "the user paid amountIn, fee included");
        assertEq(token0.balanceOf(address(router)), 0, "the router holds no tokenOut");
        assertEq(token1.balanceOf(address(router)), 0, "the router holds no tokenIn");
    }

    function test_swapExactIn_encodes_one_v4_swap_when_buying() public {
        universalRouter.setOutput(address(token1), OUTPUT);
        ISVRouter.SwapParams memory p = _swapParams(true, AMOUNT_IN, OUTPUT);
        p.hookData = hex"c0ffee";
        ISignatureTransfer.PermitTransferFrom memory permit = _permitFor(address(token0), AMOUNT_IN, 0);
        // Signed before the prank: reading Permit2's domain separator is an external call, which would
        // otherwise consume it and send the trade from the test contract instead of the user.
        bytes memory signature = _sign(USER_KEY, permit);

        vm.prank(user);
        router.swapExactIn(p, permit, signature);

        // The raw calldata first: one V4_SWAP command, one input, the trade's deadline, three actions in order.
        assertEq(universalRouter.lastCommands(), abi.encodePacked(uint8(Commands.V4_SWAP)), "one V4_SWAP command");
        assertEq(universalRouter.lastDeadline(), p.deadline, "the trade's deadline is forwarded");
        bytes[] memory inputs = universalRouter.lastInputs();
        assertEq(inputs.length, 1, "one input");
        (bytes memory actions, bytes[] memory params) = abi.decode(inputs[0], (bytes, bytes[]));
        assertEq(
            actions,
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE), uint8(Actions.TAKE)),
            "swap, settle, take"
        );
        assertEq(params.length, 3, "one parameter per action");

        // Then every field the mock decoded out of it.
        _assertRecordedSwap(true, NET, OUTPUT, hex"c0ffee");
    }

    function test_swapExactIn_encodes_one_v4_swap_when_selling() public {
        universalRouter.setOutput(address(token0), OUTPUT);
        ISVRouter.SwapParams memory p = _swapParams(false, AMOUNT_IN, OUTPUT - 1);
        ISignatureTransfer.PermitTransferFrom memory permit = _permitFor(address(token1), AMOUNT_IN, 0);
        bytes memory signature = _sign(USER_KEY, permit);

        vm.prank(user);
        router.swapExactIn(p, permit, signature);

        assertEq(universalRouter.lastCommands(), abi.encodePacked(uint8(Commands.V4_SWAP)), "one V4_SWAP command");
        assertEq(universalRouter.lastDeadline(), p.deadline, "the trade's deadline is forwarded");
        _assertRecordedSwap(false, NET, OUTPUT - 1, "");
    }

    function test_swapExactIn_settles_the_whole_input_when_the_fee_is_zero() public {
        nft.mint(user, 1); // holderFeeBps is 0 at deploy, so net == amountIn and nothing is skimmed
        _trade(true, AMOUNT_IN, OUTPUT, OUTPUT, 0);

        _assertRecordedSwap(true, AMOUNT_IN, OUTPUT, "");
        assertEq(token0.balanceOf(address(universalRouter)), AMOUNT_IN, "the mock was paid what it must settle");
    }

    /// @dev Every field of the swap the mock decoded: the pool, the direction, the net amount, the user's
    ///      minimum, the per-hop price floor switched off, the hookData, and the SETTLE and TAKE parameters.
    ///      The settle amount is the exact net and never the open delta: a partial fill has to revert rather
    ///      than strand the remainder inside the Universal Router.
    function _assertRecordedSwap(bool zeroForOne, uint128 net, uint128 amountOutMin, bytes memory hookData)
        private
        view
    {
        (MockERC20 tokenIn, MockERC20 tokenOut) = _tokens(zeroForOne);
        MockUniversalRouter.RecordedSwap memory s = universalRouter.lastSwapParams();

        assertEq(Currency.unwrap(s.key.currency0), address(token0), "key.currency0");
        assertEq(Currency.unwrap(s.key.currency1), address(token1), "key.currency1");
        assertEq(uint256(s.key.fee), uint256(key.fee), "key.fee");
        assertEq(int256(s.key.tickSpacing), int256(key.tickSpacing), "key.tickSpacing");
        assertEq(address(s.key.hooks), address(key.hooks), "key.hooks");
        assertEq(s.zeroForOne, zeroForOne, "zeroForOne");
        assertEq(uint256(s.amountIn), uint256(net), "the swap gets the net amount, not the gross");
        assertEq(uint256(s.amountOutMinimum), uint256(amountOutMin), "amountOutMinimum passed through");
        assertEq(s.minHopPriceX36, 0, "the per-hop price floor is switched off");
        assertEq(s.hookData, hookData, "hookData passed through");
        assertEq(s.settleCurrency, address(tokenIn), "settle the input currency");
        assertEq(s.settleAmount, uint256(net), "settle exactly the net amount, not the open delta");
        assertFalse(s.settlePayerIsUser, "the Universal Router pays from its own balance");
        assertEq(s.takeCurrency, address(tokenOut), "take the output currency");
        assertEq(s.takeRecipient, user, "the output goes straight to the caller");
        assertEq(s.takeAmount, uint256(ActionConstants.OPEN_DELTA), "take the whole open credit");
    }

    function test_swapExactIn_leaves_the_routers_own_balances_and_allowances_untouched() public {
        uint256 strayIn = 11e18;
        uint256 strayOut = 13e18;
        token0.mint(address(router), strayIn);
        token1.mint(address(router), strayOut);

        _trade(true, AMOUNT_IN, OUTPUT, OUTPUT, 0);

        assertEq(token0.balanceOf(address(router)), strayIn, "tokenIn balance unchanged by the swap");
        assertEq(token1.balanceOf(address(router)), strayOut, "tokenOut balance unchanged by the swap");
        assertEq(token0.allowance(address(router), address(universalRouter)), 0, "no allowance to the router");
        assertEq(token1.allowance(address(router), address(universalRouter)), 0, "no allowance to the router");
        assertEq(token0.allowance(address(router), permit2), 0, "no allowance to Permit2");
    }

    function test_swapExactIn_succeeds_at_exactly_the_deadline() public {
        universalRouter.setOutput(address(token1), OUTPUT);
        ISVRouter.SwapParams memory p = _swapParams(true, AMOUNT_IN, OUTPUT);
        ISignatureTransfer.PermitTransferFrom memory permit = _permitFor(address(token0), AMOUNT_IN, 0);
        bytes memory signature = _sign(USER_KEY, permit);

        vm.warp(p.deadline); // the check is `block.timestamp > deadline`, so this last second still trades
        vm.prank(user);
        uint256 amountOut = router.swapExactIn(p, permit, signature);

        assertEq(amountOut, OUTPUT, "the trade went through on the deadline itself");
    }

    function test_swapExactIn_accepts_a_permit_for_more_than_amountIn() public {
        universalRouter.setOutput(address(token1), OUTPUT);
        ISVRouter.SwapParams memory p = _swapParams(true, AMOUNT_IN, OUTPUT);
        ISignatureTransfer.PermitTransferFrom memory permit = _permitFor(address(token0), AMOUNT_IN * 2, 0);
        bytes memory signature = _sign(USER_KEY, permit);

        vm.prank(user);
        uint256 amountOut = router.swapExactIn(p, permit, signature);

        assertEq(amountOut, OUTPUT, "the trade went through");
        assertEq(token0.balanceOf(user), MINT - AMOUNT_IN, "only amountIn was pulled, not the permitted maximum");
        assertEq(token0.balanceOf(feeWallet), FEE, "the fee is on amountIn");
    }

    // -------------------------------------------------------------------------------------------------------
    // swapExactIn: the Suits NFT holder rate (spec section 4.3, decision D34)
    // -------------------------------------------------------------------------------------------------------

    function test_swapExactIn_at_the_holder_rate_of_zero_takes_no_fee_and_transfers_nothing() public {
        nft.mint(user, 1); // holderFeeBps is 0 at deploy: the holder pays nothing
        universalRouter.setOutput(address(token1), OUTPUT);
        ISVRouter.SwapParams memory p = _swapParams(true, AMOUNT_IN, OUTPUT);
        ISignatureTransfer.PermitTransferFrom memory permit = _permitFor(address(token0), AMOUNT_IN, 0);
        bytes memory signature = _sign(USER_KEY, permit);

        vm.expectEmit(true, true, true, true, address(router));
        emit ISVRouter.Trade(
            user, PoolId.unwrap(key.toId()), address(token0), address(token1), AMOUNT_IN, 0, OUTPUT, true
        );
        vm.recordLogs();
        vm.prank(user);
        uint256 amountOut = router.swapExactIn(p, permit, signature);

        assertEq(amountOut, OUTPUT, "returned amountOut");
        assertEq(token0.balanceOf(feeWallet), 0, "no fee");
        assertEq(token0.balanceOf(address(universalRouter)), AMOUNT_IN, "the whole input reached the mock router");

        // A zero fee is not transferred at all (spec 6a): the input token moved exactly twice, from the user
        // into the router (Permit2) and from the router on to the Universal Router, and never to the fee wallet.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 transferTopic = keccak256("Transfer(address,address,uint256)");
        uint256 transfersOfTokenIn;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(token0) || logs[i].topics[0] != transferTopic) continue;
            transfersOfTokenIn++;
            assertNotEq(
                address(uint160(uint256(logs[i].topics[2]))), feeWallet, "no zero-value transfer to the fee wallet"
            );
        }
        assertEq(transfersOfTokenIn, 2, "the pull and the payment to the router, and nothing else");
    }

    function test_swapExactIn_at_a_configured_holder_rate() public {
        vm.prank(owner);
        router.setFees(50, 20); // holders pay 0.2 %
        nft.mint(user, 1);
        uint128 holderFee = AMOUNT_IN * 20 / 10_000; // 2e18
        universalRouter.setOutput(address(token1), OUTPUT);
        ISVRouter.SwapParams memory p = _swapParams(true, AMOUNT_IN, OUTPUT);
        ISignatureTransfer.PermitTransferFrom memory permit = _permitFor(address(token0), AMOUNT_IN, 0);
        bytes memory signature = _sign(USER_KEY, permit);

        vm.expectEmit(true, true, true, true, address(router));
        emit ISVRouter.Trade(
            user, PoolId.unwrap(key.toId()), address(token0), address(token1), AMOUNT_IN, holderFee, OUTPUT, true
        );
        vm.prank(user);
        uint256 amountOut = router.swapExactIn(p, permit, signature);

        assertEq(amountOut, OUTPUT, "returned amountOut");
        assertEq(token0.balanceOf(feeWallet), holderFee, "the holder fee reached the fee wallet");
        assertEq(token0.balanceOf(address(universalRouter)), AMOUNT_IN - holderFee, "net in the mock router");
        assertLt(holderFee, FEE, "the holder paid less than the standard rate");
    }

    function test_swapExactIn_completes_when_the_nft_call_reverts() public {
        RevertingSuitsNft unwell = new RevertingSuitsNft();
        vm.prank(owner);
        router.setSuitsNft(address(unwell));
        universalRouter.setOutput(address(token1), OUTPUT);
        ISVRouter.SwapParams memory p = _swapParams(true, AMOUNT_IN, OUTPUT);
        ISignatureTransfer.PermitTransferFrom memory permit = _permitFor(address(token0), AMOUNT_IN, 0);
        bytes memory signature = _sign(USER_KEY, permit);

        vm.expectEmit(true, true, true, true, address(router));
        emit ISVRouter.Trade(
            user, PoolId.unwrap(key.toId()), address(token0), address(token1), AMOUNT_IN, FEE, OUTPUT, false
        );
        vm.prank(user);
        uint256 amountOut = router.swapExactIn(p, permit, signature);

        assertEq(amountOut, OUTPUT, "a broken NFT costs the holder rate, never the trade");
        assertEq(token0.balanceOf(feeWallet), FEE, "the standard fee was taken");
        assertEq(token1.balanceOf(user), MINT + OUTPUT, "the output still reached the user");
    }

    function test_swapExactIn_completes_when_the_nft_address_has_no_code() public {
        vm.prank(owner);
        router.setSuitsNft(makeAddr("an address with no code"));
        universalRouter.setOutput(address(token1), OUTPUT);
        ISVRouter.SwapParams memory p = _swapParams(true, AMOUNT_IN, OUTPUT);
        ISignatureTransfer.PermitTransferFrom memory permit = _permitFor(address(token0), AMOUNT_IN, 0);
        bytes memory signature = _sign(USER_KEY, permit);

        vm.expectEmit(true, true, true, true, address(router));
        emit ISVRouter.Trade(
            user, PoolId.unwrap(key.toId()), address(token0), address(token1), AMOUNT_IN, FEE, OUTPUT, false
        );
        vm.prank(user);
        uint256 amountOut = router.swapExactIn(p, permit, signature);

        assertEq(amountOut, OUTPUT, "a codeless NFT address costs the holder rate, never the trade");
        assertEq(token0.balanceOf(feeWallet), FEE, "the standard fee was taken");
    }

    // -------------------------------------------------------------------------------------------------------
    // swapExactIn: the reverts (spec sections 4.1, 4.2, 4.5)
    // -------------------------------------------------------------------------------------------------------

    function test_swapExactIn_reverts_after_the_deadline() public {
        ISVRouter.SwapParams memory p = _swapParams(true, AMOUNT_IN, OUTPUT);
        ISignatureTransfer.PermitTransferFrom memory permit = _permitFor(address(token0), AMOUNT_IN, 0);
        bytes memory signature = _sign(USER_KEY, permit);

        vm.warp(p.deadline + 1);
        vm.expectRevert(ISVRouter.Expired.selector);
        vm.prank(user);
        router.swapExactIn(p, permit, signature);

        assertEq(token0.balanceOf(user), MINT, "nothing was pulled from the user");
    }

    function test_swapExactIn_reverts_on_a_zero_amount() public {
        ISVRouter.SwapParams memory p = _swapParams(true, 0, 0);
        ISignatureTransfer.PermitTransferFrom memory permit = _permitFor(address(token0), AMOUNT_IN, 0);
        bytes memory signature = _sign(USER_KEY, permit);

        vm.expectRevert(ISVRouter.ZeroAmount.selector);
        vm.prank(user);
        router.swapExactIn(p, permit, signature);
    }

    function test_swapExactIn_reverts_when_the_permit_names_another_token() public {
        ISVRouter.SwapParams memory p = _swapParams(true, AMOUNT_IN, OUTPUT);
        // The trade pays currency0; the permit is signed for currency1.
        ISignatureTransfer.PermitTransferFrom memory permit = _permitFor(address(token1), AMOUNT_IN, 0);
        bytes memory signature = _sign(USER_KEY, permit);

        vm.expectRevert(ISVRouter.PermitMismatch.selector);
        vm.prank(user);
        router.swapExactIn(p, permit, signature);

        assertEq(token1.balanceOf(user), MINT, "nothing was pulled from the user");
    }

    function test_swapExactIn_reverts_when_the_permit_covers_less_than_amountIn() public {
        ISVRouter.SwapParams memory p = _swapParams(true, AMOUNT_IN, OUTPUT);
        ISignatureTransfer.PermitTransferFrom memory permit = _permitFor(address(token0), AMOUNT_IN - 1, 0);
        bytes memory signature = _sign(USER_KEY, permit);

        vm.expectRevert(ISVRouter.PermitMismatch.selector);
        vm.prank(user);
        router.swapExactIn(p, permit, signature);

        assertEq(token0.balanceOf(user), MINT, "nothing was pulled from the user");
    }

    function test_swapExactIn_reverts_on_a_signature_from_another_key() public {
        universalRouter.setOutput(address(token1), OUTPUT);
        ISVRouter.SwapParams memory p = _swapParams(true, AMOUNT_IN, OUTPUT);
        ISignatureTransfer.PermitTransferFrom memory permit = _permitFor(address(token0), AMOUNT_IN, 0);
        bytes memory signature = _sign(STRANGER_KEY, permit); // not the caller's key

        vm.expectRevert(SignatureVerification.InvalidSigner.selector); // Permit2's own check
        vm.prank(user);
        router.swapExactIn(p, permit, signature);

        assertEq(token0.balanceOf(user), MINT, "nothing was pulled from the user");
    }

    function test_swapExactIn_reverts_when_the_permit_nonce_is_reused() public {
        _trade(true, AMOUNT_IN, OUTPUT, OUTPUT, 0);

        ISVRouter.SwapParams memory p = _swapParams(true, AMOUNT_IN, OUTPUT);
        ISignatureTransfer.PermitTransferFrom memory permit = _permitFor(address(token0), AMOUNT_IN, 0);
        bytes memory signature = _sign(USER_KEY, permit);

        // Permit2's `InvalidNonce()`; its PermitErrors.sol pins pragma 0.8.17 and cannot be imported here.
        vm.expectRevert(abi.encodeWithSignature("InvalidNonce()"));
        vm.prank(user);
        router.swapExactIn(p, permit, signature);

        assertEq(token0.balanceOf(user), MINT - AMOUNT_IN, "only the first trade was paid for");
    }

    function test_swapExactIn_reverts_when_the_output_is_below_the_minimum() public {
        uint128 short = OUTPUT - 1; // a hook took a bite out of the output, say
        universalRouter.setOutput(address(token1), short);
        ISVRouter.SwapParams memory p = _swapParams(true, AMOUNT_IN, OUTPUT);
        ISignatureTransfer.PermitTransferFrom memory permit = _permitFor(address(token0), AMOUNT_IN, 0);
        bytes memory signature = _sign(USER_KEY, permit);

        vm.expectRevert(abi.encodeWithSelector(ISVRouter.InsufficientOutput.selector, short, OUTPUT));
        vm.prank(user);
        router.swapExactIn(p, permit, signature);

        assertEq(token0.balanceOf(feeWallet), 0, "the whole trade was rolled back, fee included");
        assertEq(token0.balanceOf(user), MINT, "nothing was pulled from the user");
    }

    function test_swapExactIn_bubbles_up_the_universal_routers_revert() public {
        // What the real Universal Router throws when the pool cannot fill the trade at the caller's minimum.
        bytes memory slippage = abi.encodeWithSelector(IV4Router.V4TooLittleReceived.selector, OUTPUT, OUTPUT - 1);
        universalRouter.setOutput(address(token1), OUTPUT);
        universalRouter.setRevert(slippage);
        ISVRouter.SwapParams memory p = _swapParams(true, AMOUNT_IN, OUTPUT);
        ISignatureTransfer.PermitTransferFrom memory permit = _permitFor(address(token0), AMOUNT_IN, 0);
        bytes memory signature = _sign(USER_KEY, permit);

        vm.expectRevert(slippage);
        vm.prank(user);
        router.swapExactIn(p, permit, signature);

        assertEq(token0.balanceOf(feeWallet), 0, "the whole trade was rolled back, fee included");
        assertEq(token0.balanceOf(user), MINT, "nothing was pulled from the user");
    }

    // -------------------------------------------------------------------------------------------------------
    // sweep (spec section 7: for tokens sent here by mistake)
    // -------------------------------------------------------------------------------------------------------

    function test_sweep_moves_a_token_sent_to_the_router_by_mistake() public {
        address rescue = makeAddr("rescue");
        uint256 stray = 7e18;
        token0.mint(address(router), stray);

        vm.expectEmit(true, true, true, true, address(router));
        emit ISVRouter.Swept(address(token0), rescue, stray);
        vm.prank(owner);
        router.sweep(address(token0), rescue, stray);

        assertEq(token0.balanceOf(rescue), stray, "swept to the destination");
        assertEq(token0.balanceOf(address(router)), 0, "the router is empty again");
    }

    function test_sweep_reverts_on_a_zero_destination() public {
        uint256 stray = 7e18;
        token0.mint(address(router), stray);

        vm.expectRevert(ISVRouter.ZeroAddress.selector);
        vm.prank(owner);
        router.sweep(address(token0), address(0), stray);

        assertEq(token0.balanceOf(address(router)), stray, "a sweep can never burn");
    }

    function test_sweep_is_owner_only() public {
        uint256 stray = 7e18;
        token0.mint(address(router), stray);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        router.sweep(address(token0), stranger, stray);

        assertEq(token0.balanceOf(address(router)), stray, "still there");
    }
}
