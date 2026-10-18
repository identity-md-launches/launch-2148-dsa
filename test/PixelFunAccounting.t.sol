// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PixelFun} from "src/PixelFun.sol";
import {CanvasToken, NoReturnCanvasToken, CallbackCanvasToken} from "./helpers/PixelFunTokens.sol";

contract PixelFunAccountingTest is Test {
    CanvasToken internal token;
    PixelFun internal canvas;
    address internal alice;
    address internal bob;
    address internal collector;
    uint256 internal constant PRICE = 5e15;

    function setUp() public {
        alice = makeAddr("accounting Alice");
        bob = makeAddr("accounting Bob");
        collector = makeAddr("token fee collector");
        token = new CanvasToken(18, 0, collector);
        canvas = new PixelFun(address(token), 20);
    }

    function _deposit(address user, uint256 amount) internal {
        token.mint(user, amount);
        vm.startPrank(user);
        token.approve(address(canvas), amount);
        canvas.deposit(amount);
        vm.stopPrank();
    }

    function _paint(address user, uint256 n) internal {
        vm.prank(user);
        canvas.paint(new uint32[](n), new uint8[](n));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_DepositPaintWithdrawConservesEachUsersFunds(uint128 amountSeed, uint8 countSeed) public {
        uint256 n = bound(countSeed, 1, 100);
        uint256 amount = bound(amountSeed, n * PRICE + 1, type(uint128).max);
        _deposit(bob, 3 ether);
        _deposit(alice, amount);
        _paint(alice, n);
        uint256 unspent = amount - n * PRICE;
        vm.expectEmit(true, false, false, true, address(canvas));
        emit PixelFun.Withdrawn(alice, unspent);
        vm.prank(alice);
        canvas.withdraw(unspent);
        assertEq(token.balanceOf(alice) + token.balanceOf(canvas.BURN_ADDRESS()), amount);
        assertEq(canvas.balanceOf(alice), 0);
        assertEq(canvas.balanceOf(bob), 3 ether);
        assertEq(token.balanceOf(address(canvas)), 3 ether);
        assertEq(canvas.totalDeposited(), 3 ether);
        assertEq(canvas.totalPixelsPainted(), n);
        assertEq(canvas.pixelsPaintedIn(0, alice), n);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_FeeDepositWithdrawRoundTrip(uint128 seed, uint16 feeSeed) public {
        uint256 amount = bound(seed, 1, 1e30);
        uint256 bps = bound(feeSeed, 1, 9999);
        CanvasToken feeToken = new CanvasToken(18, bps, collector);
        PixelFun feeCanvas = new PixelFun(address(feeToken), 20);
        feeToken.mint(alice, amount);
        uint256 received = amount - amount * bps / 10_000;
        vm.startPrank(alice);
        feeToken.approve(address(feeCanvas), amount);
        vm.expectEmit(true, false, false, true, address(feeCanvas));
        emit PixelFun.Deposited(alice, received);
        feeCanvas.deposit(amount);
        assertEq(feeCanvas.balanceOf(alice), received);
        assertEq(feeCanvas.totalDeposited(), received);
        assertEq(feeToken.balanceOf(address(feeCanvas)), received);
        feeCanvas.withdraw(received);
        vm.stopPrank();
        uint256 returned = received - received * bps / 10_000;
        assertEq(feeToken.balanceOf(alice), returned);
        assertEq(feeToken.balanceOf(collector) + returned, amount);
        assertEq(feeToken.balanceOf(address(feeCanvas)), 0);
        assertEq(feeCanvas.balanceOf(alice), 0);
        assertEq(feeCanvas.totalDeposited(), 0);
    }

    function test_OneWeiCanBeDepositedAndFullyWithdrawn() public {
        _deposit(alice, 1);
        vm.prank(alice);
        canvas.withdraw(1);
        assertEq(token.balanceOf(alice), 1);
        assertEq(canvas.totalDeposited(), 0);
        assertEq(token.balanceOf(address(canvas)), 0);
    }

    function test_DepositZeroAndMissingAllowanceLeaveNoLiability() public {
        token.mint(alice, 10);
        vm.startPrank(alice);
        vm.expectRevert(PixelFun.ZeroAmount.selector);
        canvas.deposit(0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(canvas), 0, 10)
        );
        canvas.deposit(10);
        token.approve(address(canvas), 11);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10, 11));
        canvas.deposit(11);
        vm.stopPrank();
        assertEq(canvas.balanceOf(alice), 0);
        assertEq(canvas.totalDeposited(), 0);
        assertEq(token.balanceOf(alice), 10);
    }

    function test_FailedDepositRollsBackAndCanBeRetried() public {
        token.mint(alice, 1 ether);
        vm.prank(alice);
        token.approve(address(canvas), 1 ether);
        token.setFailures(false, true, false);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        canvas.deposit(1 ether);
        assertEq(canvas.balanceOf(alice), 0);
        assertEq(canvas.totalDeposited(), 0);
        assertEq(token.balanceOf(address(canvas)), 0);
        token.setFailures(false, false, false);
        vm.prank(alice);
        canvas.deposit(1 ether);
        assertEq(canvas.balanceOf(alice), 1 ether);
    }

    function test_FailedWithdrawalPreservesFundsAndOtherUsersCanExit() public {
        _deposit(alice, 2 ether);
        _deposit(bob, 1 ether);
        token.setFailures(true, false, false);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        canvas.withdraw(2 ether);
        assertEq(canvas.balanceOf(alice), 2 ether);
        assertEq(canvas.totalDeposited(), 3 ether);
        assertEq(token.balanceOf(address(canvas)), 3 ether);
        token.setFailures(false, false, false);
        vm.prank(bob);
        canvas.withdraw(1 ether);
        vm.prank(alice);
        canvas.withdraw(2 ether);
        assertEq(token.balanceOf(alice), 2 ether);
        assertEq(token.balanceOf(bob), 1 ether);
        assertEq(canvas.totalDeposited(), 0);
    }

    function test_FailedBurnRollsBackCanvasCountersVaultAndBoard() public {
        _deposit(alice, 2 ether);
        _paint(alice, 20);
        (address[] memory oldPainters, uint32[] memory oldCounts) = canvas.getBoard(0);
        uint256 heldBefore = token.balanceOf(address(canvas));
        token.setFailures(true, false, false);
        uint32[] memory ids = new uint32[](100);
        uint8[] memory colors = new uint8[](100);
        for (uint256 i; i < 100; ++i) {
            ids[i] = uint32(32 * i + 1);
            colors[i] = 31;
        }
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        canvas.paint(ids, colors);
        assertEq(canvas.totalPixelsPainted(), 20);
        assertEq(canvas.totalBurned(), 20 * PRICE);
        assertEq(canvas.totalDeposited(), heldBefore);
        assertEq(canvas.balanceOf(alice), heldBefore);
        assertEq(token.balanceOf(address(canvas)), heldBefore);
        assertEq(token.balanceOf(canvas.BURN_ADDRESS()), 20 * PRICE);
        assertEq(canvas.pixelsPaintedIn(0, alice), 20);
        for (uint256 i; i < 100; ++i) {
            assertEq(canvas.pixelAt(ids[i]), 0);
        }
        (address[] memory painters, uint32[] memory counts) = canvas.getBoard(0);
        assertEq(abi.encode(painters, counts), abi.encode(oldPainters, oldCounts));
        token.setFailures(false, false, false);
        vm.prank(alice);
        canvas.paint(ids, colors);
        assertEq(canvas.pixelsPaintedIn(0, alice), 120);
    }

    function test_RevertingTokenBubblesAndAccountingRollsBack() public {
        _deposit(alice, 1 ether);
        token.setFailures(false, false, true);
        vm.prank(alice);
        vm.expectRevert(CanvasToken.TokenTransferRejected.selector);
        canvas.withdraw(1 ether);
        assertEq(canvas.balanceOf(alice), 1 ether);
        assertEq(canvas.totalDeposited(), 1 ether);
        token.setFailures(false, false, false);
        vm.prank(alice);
        canvas.withdraw(1 ether);
        assertEq(canvas.totalDeposited(), 0);
    }

    function test_DonationCannotBeWithdrawnOrCreditedByNextDepositor() public {
        token.mint(bob, 10 ether);
        vm.prank(bob);
        token.transfer(address(canvas), 10 ether);
        _deposit(alice, 1 ether);
        assertEq(canvas.balanceOf(alice), 1 ether);
        assertEq(canvas.balanceOf(bob), 0);
        vm.prank(bob);
        vm.expectRevert(PixelFun.InsufficientBalance.selector);
        canvas.withdraw(1);
        vm.prank(alice);
        canvas.withdraw(1 ether);
        assertEq(canvas.totalDeposited(), 0);
        assertEq(token.balanceOf(address(canvas)), 10 ether);
    }

    function test_MsgSenderOwnsVaultRegardlessOfTxOrigin() public {
        token.mint(alice, 1 ether);
        vm.startPrank(alice, bob);
        token.approve(address(canvas), 1 ether);
        canvas.deposit(1 ether);
        vm.stopPrank();
        vm.prank(bob, alice);
        vm.expectRevert(PixelFun.InsufficientBalance.selector);
        canvas.withdraw(1);
        vm.prank(bob, alice);
        vm.expectRevert(PixelFun.InsufficientBalance.selector);
        canvas.paint(new uint32[](1), new uint8[](1));
        assertEq(canvas.balanceOf(alice), 1 ether);
        assertEq(canvas.balanceOf(bob), 0);
    }

    function test_NoReturnTokenSupportsEntireLifecycle() public {
        NoReturnCanvasToken legacy = new NoReturnCanvasToken();
        PixelFun legacyCanvas = new PixelFun(address(legacy), 20);
        legacy.mint(alice, 1_000_000);
        vm.startPrank(alice);
        legacy.approve(address(legacyCanvas), 1_000_000);
        legacyCanvas.deposit(1_000_000);
        legacyCanvas.paint(new uint32[](20), new uint8[](20));
        legacyCanvas.withdraw(900_000);
        vm.stopPrank();
        assertEq(legacyCanvas.PRICE(), 5000);
        assertEq(legacy.balanceOf(legacyCanvas.BURN_ADDRESS()), 100_000);
        assertEq(legacy.balanceOf(alice), 900_000);
        assertEq(legacyCanvas.totalDeposited(), 0);
        assertEq(legacyCanvas.pixelAt(0), 1);
        assertTrue(legacyCanvas.isWhitelisted(0, alice));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_DecimalScalingPaysExactPrice(uint8 decimalSeed, uint8 batchSeed) public {
        uint8 decimals = uint8(bound(decimalSeed, 3, 77));
        uint256 n = bound(batchSeed, 1, 100);
        CanvasToken scaled = new CanvasToken(decimals, 0, collector);
        PixelFun scaledCanvas = new PixelFun(address(scaled), 20);
        // Independent specification: one thousand pixels must cost exactly five tokens.
        uint256 unit = 10 ** uint256(decimals);
        uint256 price = unit / 200;
        assertEq(scaledCanvas.PRICE(), price);
        scaled.mint(alice, n * price);
        vm.startPrank(alice);
        scaled.approve(address(scaledCanvas), n * price);
        scaledCanvas.deposit(n * price);
        scaledCanvas.paint(new uint32[](n), new uint8[](n));
        vm.stopPrank();
        assertEq(scaled.balanceOf(scaledCanvas.BURN_ADDRESS()), n * price);
        assertEq(scaledCanvas.balanceOf(alice), 0);
        assertEq(scaledCanvas.totalPixelsPainted(), n);
    }

    function test_UnsupportedLowDecimalsNeverAcceptFunds() public {
        for (uint8 d; d < 3; ++d) {
            CanvasToken low = new CanvasToken(d, 0, collector);
            PixelFun lowCanvas = new PixelFun(address(low), 20);
            low.mint(alice, 1);
            vm.startPrank(alice);
            low.approve(address(lowCanvas), 1);
            vm.expectRevert(PixelFun.UnsupportedDecimals.selector);
            lowCanvas.deposit(1);
            vm.stopPrank();
            assertEq(lowCanvas.balanceOf(alice), 0);
            assertEq(low.balanceOf(alice), 1);
        }
    }

    function test_DepositRejectsAllThreeReentrantEntryPoints() public {
        _checkCallbacks(0);
    }

    function test_WithdrawRejectsAllThreeReentrantEntryPoints() public {
        _checkCallbacks(1);
    }

    function test_PaintRejectsAllThreeReentrantEntryPoints() public {
        _checkCallbacks(2);
    }

    function _checkCallbacks(uint256 outerAction) internal {
        for (uint256 innerAction; innerAction < 3; ++innerAction) {
            CallbackCanvasToken callback = new CallbackCanvasToken();
            PixelFun guarded = new PixelFun(address(callback), 1);
            // Give the callback caller a real balance and allowance, so lack of funds cannot mask a missing guard.
            callback.mint(address(callback), 2 ether);
            vm.startPrank(address(callback));
            callback.approve(address(guarded), type(uint256).max);
            guarded.deposit(1 ether);
            vm.stopPrank();
            callback.mint(alice, 2 ether);
            vm.startPrank(alice);
            callback.approve(address(guarded), type(uint256).max);
            guarded.deposit(1 ether);
            vm.stopPrank();
            bytes memory payload;
            if (innerAction == 0) payload = abi.encodeCall(PixelFun.deposit, (1));
            else if (innerAction == 1) payload = abi.encodeCall(PixelFun.withdraw, (1));
            else payload = abi.encodeCall(PixelFun.paint, (new uint32[](1), new uint8[](1)));
            callback.arm(guarded, payload, alice);
            vm.prank(alice);
            if (outerAction == 0) guarded.deposit(1 ether);
            else if (outerAction == 1) guarded.withdraw(1 ether);
            else guarded.paint(new uint32[](1), new uint8[](1));
            assertEq(callback.attempts(), 1);
            assertFalse(callback.innerSucceeded());
            assertEq(
                callback.innerResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
            );
            assertEq(guarded.balanceOf(address(callback)), 1 ether);
            assertEq(guarded.pixelsPaintedIn(0, address(callback)), 0);
            uint256 expectedAlice = outerAction == 0 ? 2 ether : outerAction == 1 ? 0 : 1 ether - PRICE;
            assertEq(guarded.balanceOf(alice), expectedAlice);
            assertEq(callback.observedVaultBalance(), outerAction == 0 ? 1 ether : expectedAlice);
            assertEq(callback.balanceOf(address(guarded)), 1 ether + expectedAlice);
        }
    }
}
