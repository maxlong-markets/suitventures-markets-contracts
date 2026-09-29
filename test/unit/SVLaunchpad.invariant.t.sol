// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {SVLaunchpad} from "../../src/SVLaunchpad.sol";
import {ISVLaunchpad} from "../../src/interfaces/ISVLaunchpad.sol";
import {MockQuirkyERC20} from "../mocks/MockQuirkyERC20.sol";
import {SVLaunchpadTestBase} from "./SVLaunchpad.t.sol";

/// @notice Every call that touches a launch after it exists, for the invariant runner to sequence at random:
///         buys, sells, collections, claims, payout moves, the quote turning refusing, answering false or charging
///         a transfer fee, and the hostile calls that must change nothing: `unlockCallback` from the PoolManager
///         with no unlock in flight, `setPayout` from a stranger, and a second launch beside the first. Reverts are
///         expected and allowed; the counters prove the interesting paths actually ran.
contract LaunchpadFeesHandler is Test {
    SVLaunchpad internal immutable LAUNCHPAD;
    PoolSwapTest internal immutable SWAP_ROUTER;
    MockQuirkyERC20 internal immutable QUOTE;
    IPoolManager internal immutable POOL_MANAGER;
    address internal immutable TOKEN;
    address internal immutable FEE_WALLET;
    /// @dev Never refused and never owed: where claims are sent, so a claim fails only for a real reason.
    address internal immutable RESCUE;
    address[3] internal payouts;
    uint256 internal saltCounter;

    /// @notice Successful collections that credited at least one share to `owed`.
    uint256 public creditingCollections;
    /// @notice Successful claims.
    uint256 public claims;

    constructor(
        SVLaunchpad launchpad,
        PoolSwapTest swapRouter,
        MockQuirkyERC20 quote,
        address token,
        address feeWallet,
        address[3] memory payouts_
    ) {
        LAUNCHPAD = launchpad;
        SWAP_ROUTER = swapRouter;
        QUOTE = quote;
        POOL_MANAGER = launchpad.POOL_MANAGER();
        TOKEN = token;
        FEE_WALLET = feeWallet;
        RESCUE = makeAddr("rescue");
        payouts = payouts_;
        quote.approve(address(swapRouter), type(uint256).max);
        IERC20(token).approve(address(swapRouter), type(uint256).max);
    }

    function buy(uint256 amount) public {
        _swap(true, bound(amount, 1e6, 1_000e6));
    }

    function sell(uint256 amount) external {
        uint256 held = IERC20(TOKEN).balanceOf(address(this));
        if (held == 0) return;
        _swap(false, bound(amount, 1, held));
    }

    function collect() external {
        uint256 before = _owedSum();
        LAUNCHPAD.collectFees(TOKEN);
        if (_owedSum() > before) creditingCollections++;
    }

    function refuse(bool payoutSide, uint256 mode) external {
        address target = payoutSide ? LAUNCHPAD.getLaunch(TOKEN).payout : FEE_WALLET;
        QUOTE.setRefusal(target, MockQuirkyERC20.Refusal(mode % 3));
    }

    function toggleTransferFee(bool on) external {
        QUOTE.setTransferFee(on ? 100 : 0, address(0));
    }

    /// @dev Claims the first owed balance it finds, to the rescue address or to one of the owed accounts.
    function claim(uint256 to) external {
        address recipient = to % 2 == 0 ? RESCUE : account(to / 2);
        for (uint256 i = 0; i < 4; i++) {
            address claimant = account(i);
            address asset = LAUNCHPAD.owed(claimant, address(QUOTE)) > 0 ? address(QUOTE) : TOKEN;
            if (LAUNCHPAD.owed(claimant, asset) == 0) continue;
            vm.prank(claimant);
            LAUNCHPAD.claim(asset, recipient);
            claims++;
            return;
        }
    }

    function movePayout(uint256 to) external {
        address current = LAUNCHPAD.getLaunch(TOKEN).payout;
        vm.prank(current);
        LAUNCHPAD.setPayout(TOKEN, payouts[to % 3]);
    }

    /// @dev Must always revert `NotPayout`: a stranger can never move the payout.
    function setPayoutAsStranger(address to) external {
        vm.prank(makeAddr("stranger in the handler"));
        LAUNCHPAD.setPayout(TOKEN, to);
    }

    /// @dev Must always revert `UnexpectedCallback`: the PoolManager calling with no launchpad unlock in flight.
    function unlockCallbackAsPoolManager(bytes calldata data) external {
        vm.prank(address(POOL_MANAGER));
        LAUNCHPAD.unlockCallback(data);
    }

    /// @dev A second, free launch in the same quote beside the watched one; the handler holds a gate token.
    function secondLaunch() external {
        ISVLaunchpad.LaunchParams memory p;
        p.name = "Second";
        p.symbol = "TWO";
        p.quote = address(QUOTE);
        p.valuation = 5_000e6;
        p.salt = bytes32(saltCounter++);
        p.deadline = block.timestamp + 1 hours;
        ISignatureTransfer.PermitTransferFrom memory none;
        LAUNCHPAD.launch(p, none, "");
    }

    /// @notice The four accounts that can ever be owed: the three payout candidates and the fee wallet.
    function account(uint256 i) public view returns (address) {
        i = i % 4;
        return i == 3 ? FEE_WALLET : payouts[i];
    }

    function _owedSum() internal view returns (uint256 sum) {
        for (uint256 i = 0; i < 4; i++) {
            sum += LAUNCHPAD.owed(account(i), address(QUOTE)) + LAUNCHPAD.owed(account(i), TOKEN);
        }
    }

    function _swap(bool buy_, uint256 amountIn) internal {
        ISVLaunchpad.Launch memory l = LAUNCHPAD.getLaunch(TOKEN);
        bool zeroForOne = buy_ ? !l.tokenIsCurrency0 : l.tokenIsCurrency0;
        SWAP_ROUTER.swap(
            LAUNCHPAD.poolKeyOf(TOKEN),
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                // Bounded amounts, far below 2^255.
                // forge-lint: disable-next-line(unsafe-typecast)
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}

/// @notice Spec sections 4.6 and 8.1, invariant: per currency, the launchpad's balance equals the sum of `owed`,
///         through collections, failed deliveries and claims in random order, including a fee-on-transfer quote;
///         and after launch no sequence of calls changes the position's liquidity. Every run starts with a
///         share already credited to the refused payout; `afterInvariant` checks that, and a unit test drives the
///         credit-then-claim path deterministically.
contract SVLaunchpadInvariantTest is SVLaunchpadTestBase {
    LaunchpadFeesHandler internal handler;
    MockQuirkyERC20 internal q;
    address internal token;

    function setUp() public override {
        super.setUp();
        q = _quirkyQuote(0);
        token = _launchFree(address(q), USDG_MIN, true);
        address[3] memory payouts = [creator, makeAddr("payout b"), makeAddr("payout c")];
        handler = new LaunchpadFeesHandler(launchpad, swapRouter, q, token, feeWallet, payouts);
        q.mint(address(handler), 1e24);
        gate.mint(address(handler), 2);
        // Fees accrued and the payout refused before the first call of every run.
        handler.buy(100e6);
        q.setRefusal(creator, MockQuirkyERC20.Refusal.Revert);
        // Every run starts with a credited share, so its balance-equals-owed check is never vacuous.
        handler.collect();
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.sell.selector;
        selectors[2] = handler.collect.selector;
        selectors[3] = handler.refuse.selector;
        selectors[4] = handler.toggleTransferFee.selector;
        selectors[5] = handler.claim.selector;
        selectors[6] = handler.movePayout.selector;
        selectors[7] = handler.setPayoutAsStranger.selector;
        selectors[8] = handler.unlockCallbackAsPoolManager.selector;
        selectors[9] = handler.secondLaunch.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 256
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_the_launchpad_holds_exactly_the_owed_balances() public view {
        uint256 owedQuote;
        uint256 owedToken;
        for (uint256 i = 0; i < 4; i++) {
            owedQuote += launchpad.owed(handler.account(i), address(q));
            owedToken += launchpad.owed(handler.account(i), token);
        }
        assertEq(q.balanceOf(address(launchpad)), owedQuote, "quote held equals the owed sum");
        assertEq(IERC20(token).balanceOf(address(launchpad)), owedToken, "token held equals the owed sum");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 256
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_the_position_liquidity_never_changes_after_launch() public view {
        uint128 stored = launchpad.getLaunch(token).liquidity;
        assertGt(stored, 0, "the launch placed liquidity");
        assertEq(_positionLiquidity(token), stored, "the position's liquidity changed after launch");
    }

    /// @dev Runs after each invariant run: the run carried a credited share. Claims are proved deterministically
    ///      by the unit test below, not per run, so a random sequence without a claim is not a failure.
    function afterInvariant() external view {
        assertGt(handler.creditingCollections(), 0, "a collection credited a refused share to owed");
    }

    /// @dev The handler's two interesting paths, driven in a fixed order: a collection with the payout refused
    ///      credits `owed`, and a claim sends it to the rescue address; the balance equals the owed sum after each.
    function test_the_handler_credits_a_refused_share_and_claims_it_to_the_rescue_address() public {
        assertEq(handler.creditingCollections(), 1, "setUp's collection credited the refused payout");
        assertGt(launchpad.owed(creator, address(q)), 0, "the payout's quote share waits in owed");
        invariant_the_launchpad_holds_exactly_the_owed_balances();
        handler.buy(100e6);
        handler.collect();
        assertEq(handler.creditingCollections(), 2, "with the payout still refused, a second collection credits again");
        invariant_the_launchpad_holds_exactly_the_owed_balances();
        handler.claim(0);
        assertEq(handler.claims(), 1, "one successful claim, to the rescue address");
        assertEq(launchpad.owed(creator, address(q)), 0, "the creator's owed balance is gone");
        invariant_the_launchpad_holds_exactly_the_owed_balances();
    }
}
