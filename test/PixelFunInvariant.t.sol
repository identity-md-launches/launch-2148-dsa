// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {PixelFun} from "src/PixelFun.sol";
import {CanvasToken} from "./helpers/PixelFunTokens.sol";
import {PixelFunHandler} from "./helpers/PixelFunHandler.sol";

abstract contract PixelFunInvariantBase is StdInvariant, Test {
    PixelFun internal canvas;
    CanvasToken internal token;
    PixelFunHandler internal handler;
    address internal collector;

    function _setUp(uint256 feeBps, bool includePaint) internal {
        vm.warp(1_700_000_017);
        collector = makeAddr("invariant fee collector");
        token = new CanvasToken(18, feeBps, collector);
        canvas = new PixelFun(address(token), 20);
        handler = new PixelFunHandler(canvas, token);
        bytes4[] memory selectors = new bytes4[](includePaint ? 8 : 7);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.withdraw.selector;
        selectors[2] = handler.withdrawAll.selector;
        selectors[3] = handler.donate.selector;
        selectors[4] = handler.rejectOverspending.selector;
        selectors[5] = handler.roundTrip.selector;
        selectors[6] = handler.advanceTime.selector;
        if (includePaint) selectors[7] = handler.paint.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function _checkAccounting() internal view {
        uint256 sum;
        uint256 issued;
        for (uint256 i; i < handler.ACTORS(); ++i) {
            address actor = handler.actors(i);
            uint256 credited = handler.credits(actor);
            assertEq(canvas.balanceOf(actor), credited, "actor's claim diverged from successful inputs");
            sum += credited;
            issued += handler.minted(actor);
            assertEq(
                token.balanceOf(actor) + handler.grossDeposits(actor) + handler.donated(actor),
                handler.minted(actor) + handler.receivedWithdrawals(actor),
                "actor gained/lost funds outside modeled operations"
            );
            assertLe(handler.withdrawals(actor) + handler.spent(actor), handler.grossDeposits(actor));
        }
        assertLe(sum, token.balanceOf(address(canvas)), "vault is insolvent");
        assertEq(canvas.totalDeposited(), sum, "aggregate liability differs from per-user balances");
        assertEq(token.balanceOf(address(canvas)), sum + handler.surplus(), "unexplained token surplus/deficit");
        assertEq(token.balanceOf(collector), handler.fees(), "fee accounting mismatch");
        assertEq(token.totalSupply(), issued);
    }

    function afterInvariant() public {
        handler.closeAll();
        _checkAccounting();
        assertEq(canvas.totalDeposited(), 0, "some users cannot fully exit");
        assertEq(token.balanceOf(address(canvas)), handler.surplus());
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract PixelFunInvariantTest is PixelFunInvariantBase {
    function setUp() public {
        _setUp(0, true);
    }

    function invariant_VaultSolvencyAndActualBurnsMatchIndependentAccounting() public view {
        _checkAccounting();
        uint256 expectedBurn = handler.pixels() * 5e15;
        assertEq(canvas.totalPixelsPainted(), handler.pixels());
        assertEq(canvas.totalBurned(), expectedBurn);
        assertEq(token.balanceOf(canvas.BURN_ADDRESS()), expectedBurn, "recorded burns must really leave circulation");
        uint256 allEpochCounts;
        for (uint64 epoch; epoch <= handler.lastEpoch(); ++epoch) {
            for (uint256 i; i < handler.ACTORS(); ++i) {
                address actor = handler.actors(i);
                uint256 count = handler.counts(epoch, actor);
                assertEq(canvas.pixelsPaintedIn(epoch, actor), count);
                allEpochCounts += count;
            }
        }
        assertEq(allEpochCounts, handler.pixels());
    }

    function invariant_CanvasMatchesLastWritesAndFinishedBoardsStayFrozen() public view {
        assertEq(bytes.concat(canvas.getPixels(0, 3), canvas.getPixels(8190, 2)), handler.expectedColors());
        assertEq(canvas.currentEpoch(), handler.lastEpoch());
        for (uint64 epoch; epoch <= handler.lastEpoch(); ++epoch) {
            (address[] memory painters, uint32[] memory counts) = canvas.getBoard(epoch);
            if (epoch < handler.lastEpoch()) {
                assertEq(keccak256(abi.encode(painters, counts)), handler.frozenBoardHash(epoch));
                assertTrue(canvas.epochEnded(epoch));
            }
            // With five actors there is room for everyone who reaches the threshold, in every epoch.
            uint256 eligible;
            for (uint256 i; i < handler.ACTORS(); ++i) {
                address actor = handler.actors(i);
                bool qualifies = handler.counts(epoch, actor) >= 20;
                assertEq(canvas.isWhitelisted(epoch, actor), qualifies);
                if (qualifies) ++eligible;
            }
            assertEq(painters.length, eligible);
            assertEq(counts.length, eligible);
            for (uint256 i; i < painters.length; ++i) {
                assertEq(counts[i], handler.counts(epoch, painters[i]));
                assertGe(counts[i], 20);
                if (i != 0) assertGe(counts[i - 1], counts[i]);
                for (uint256 j; j < i; ++j) {
                    assertTrue(painters[j] != painters[i]);
                }
            }
        }
    }

    // Pins every handler path, including zero/full balance transitions; complements the runner's call distribution.
    function test_HandlerExercisesEveryOperationAndClosesAllPositions() public {
        handler.deposit(0, 1);
        handler.paint(0, 100, keccak256("first batch"));
        handler.donate(1, 1 ether);
        handler.rejectOverspending(2, 1);
        handler.withdraw(0, 1);
        handler.withdrawAll(1);
        handler.roundTrip(2, 1);
        handler.advanceTime(3 days);
        handler.paint(3, 20, keccak256("second epoch"));
        invariant_VaultSolvencyAndActualBurnsMatchIndependentAccounting();
        invariant_CanvasMatchesLastWritesAndFinishedBoardsStayFrozen();
        assertGt(handler.depositCalls(), 0);
        assertGt(handler.withdrawCalls(), 0);
        assertGt(handler.paintCalls(), 0);
        assertGt(handler.donationCalls(), 0);
        assertGt(handler.rejectedCalls(), 0);
        assertGt(handler.roundTripCalls(), 0);
        afterInvariant();
    }
}

/// @dev Fee-on-transfer vault campaign. Painting with outbound fees has a separate reported reproduction;
///      this suite covers the promised actual-receipt deposit accounting and full withdrawal liveness.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract PixelFunFeeVaultInvariantTest is PixelFunInvariantBase {
    function setUp() public {
        _setUp(137, false);
    }

    function invariant_FeeVaultRemainsSolventAcrossDepositsWithdrawalsAndDonations() public view {
        _checkAccounting();
    }
}
