// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PixelFun} from "src/PixelFun.sol";
import {CanvasToken} from "./helpers/PixelFunTokens.sol";
import {PixelFunBoardHandler} from "./helpers/PixelFunBoardHandler.sol";

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract PixelFunBoardInvariantTest is StdInvariant, Test {
    PixelFun internal canvas;
    CanvasToken internal token;
    PixelFunBoardHandler internal handler;

    function setUp() public {
        vm.warp(1_700_000_017);
        token = new CanvasToken(18, 0, makeAddr("unused collector"));
        canvas = new PixelFun(address(token), 20);
        handler = new PixelFunBoardHandler(canvas, token);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.paint.selector;
        selectors[1] = handler.catchUpToAnotherPainter.selector;
        selectors[2] = handler.increaseCurrentMinimum.selector;
        selectors[3] = handler.advanceWithinEpoch.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_BoardContainsExactlyTheTop66ByScoreAndReachOrder() public view {
        (address[] memory painters, uint32[] memory counts) = canvas.getBoard(0);
        assertEq(painters.length, 66);
        assertEq(counts.length, painters.length);
        bool[70] memory seen;
        uint256 previousReach;
        for (uint256 i; i < painters.length; ++i) {
            uint256 indexOne = handler.indexPlusOne(painters[i]);
            assertGt(indexOne, 0, "unknown painter on board");
            uint256 index = indexOne - 1;
            assertFalse(seen[index], "duplicate board entry");
            seen[index] = true;
            assertEq(counts[i], handler.scores(index));
            assertGe(counts[i], 20);
            uint256 reach = handler.reached(index);
            if (i != 0) {
                assertGe(counts[i - 1], counts[i], "scores not descending");
                if (counts[i - 1] == counts[i]) assertLt(previousReach, reach, "later painter won a tie");
            }
            previousReach = reach;
        }
        uint256 total;
        for (uint256 i; i < 70; ++i) {
            address actor = handler.actors(i);
            uint256 score = handler.scores(i);
            assertEq(canvas.pixelsPaintedIn(0, actor), score);
            assertEq(canvas.isWhitelisted(0, actor), seen[i], "whitelist and board disagree");
            total += score;
            if (!seen[i]) {
                assertLe(score, counts[65], "a better painter was left off the board");
                if (score == counts[65]) {
                    assertGt(handler.reached(i), previousReach, "earlier tied painter was evicted");
                }
            }
        }
        assertEq(canvas.totalPixelsPainted(), total);
        assertEq(total, handler.paintedPixels());
        assertEq(token.balanceOf(canvas.BURN_ADDRESS()), total * 5e15);
    }
}

contract PixelFunBoardPropertiesTest is Test {
    PixelFun internal canvas;
    CanvasToken internal token;
    address[70] internal actors;

    function setUp() public {
        vm.warp(1_700_000_017);
        token = new CanvasToken(18, 0, makeAddr("unused collector"));
        canvas = new PixelFun(address(token), 20);
        for (uint256 i; i < 70; ++i) {
            actors[i] = makeAddr(string.concat("leaderboard painter ", vm.toString(i)));
        }
    }

    function _paint(uint256 actor, uint256 n) internal {
        uint256 cost = n * 5e15;
        token.mint(actors[actor], cost);
        vm.startPrank(actors[actor]);
        token.approve(address(canvas), cost);
        canvas.deposit(cost);
        canvas.paint(new uint32[](n), new uint8[](n));
        vm.stopPrank();
    }

    function _fillTiedBoard() internal {
        for (uint256 i; i < 66; ++i) {
            _paint(i, 20);
        }
    }

    function test_SameBlockTiesPreferFirstReachNotFirstAdmission() public {
        _paint(0, 20);
        _paint(1, 21);
        _paint(0, 1);
        (address[] memory painters, uint32[] memory counts) = canvas.getBoard(0);
        assertEq(painters[0], actors[1]);
        assertEq(painters[1], actors[0]);
        assertEq(counts[0], 21);
        assertEq(counts[1], 21);
        _paint(0, 1);
        _paint(1, 1);
        (painters, counts) = canvas.getBoard(0);
        assertEq(painters[0], actors[0]);
        assertEq(painters[1], actors[1]);
        assertEq(counts[0], 22);
        assertEq(counts[1], 22);
    }

    function test_StrictCutoffLatestTieEvictionAndDisplacedPainterReentry() public {
        _fillTiedBoard();
        _paint(66, 20);
        assertFalse(canvas.isWhitelisted(0, actors[66]));
        for (uint256 i; i < 66; ++i) {
            assertTrue(canvas.isWhitelisted(0, actors[i]));
        }
        _paint(67, 21);
        assertFalse(canvas.isWhitelisted(0, actors[65]));
        assertTrue(canvas.isWhitelisted(0, actors[64]));
        _paint(65, 1);
        assertTrue(canvas.isWhitelisted(0, actors[65]));
        assertFalse(canvas.isWhitelisted(0, actors[64]));
        (address[] memory painters, uint32[] memory counts) = canvas.getBoard(0);
        assertEq(painters[0], actors[67]);
        assertEq(painters[1], actors[65]);
        assertEq(counts[0], 21);
        assertEq(counts[1], 21);
        assertEq(painters[65], actors[63]);
    }

    function test_IncreasingCachedMinimumChangesWhoIsDisplaced() public {
        _fillTiedBoard();
        _paint(65, 100);
        _paint(66, 21);
        assertTrue(canvas.isWhitelisted(0, actors[65]));
        assertFalse(canvas.isWhitelisted(0, actors[64]));
        assertTrue(canvas.isWhitelisted(0, actors[63]));
        (address[] memory painters, uint32[] memory counts) = canvas.getBoard(0);
        assertEq(painters[0], actors[65]);
        assertEq(counts[0], 120);
        assertEq(painters[1], actors[66]);
    }

    function test_FailedDisplacingBurnPreservesIncumbentAndMembershipIndexes() public {
        _fillTiedBoard();
        uint256 cost = 21 * 5e15;
        token.mint(actors[66], cost);
        vm.startPrank(actors[66]);
        token.approve(address(canvas), cost);
        canvas.deposit(cost);
        vm.stopPrank();
        (address[] memory beforePainters, uint32[] memory beforeCounts) = canvas.getBoard(0);
        token.setFailures(true, false, false);
        vm.prank(actors[66]);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        canvas.paint(new uint32[](21), new uint8[](21));
        (address[] memory afterPainters, uint32[] memory afterCounts) = canvas.getBoard(0);
        assertEq(abi.encode(beforePainters, beforeCounts), abi.encode(afterPainters, afterCounts));
        assertTrue(canvas.isWhitelisted(0, actors[65]));
        assertFalse(canvas.isWhitelisted(0, actors[66]));
        assertEq(canvas.pixelsPaintedIn(0, actors[66]), 0);
        assertEq(canvas.balanceOf(actors[66]), cost);
        token.setFailures(false, false, false);
        vm.prank(actors[66]);
        canvas.paint(new uint32[](21), new uint8[](21));
        assertFalse(canvas.isWhitelisted(0, actors[65]));
        assertTrue(canvas.isWhitelisted(0, actors[66]));
    }

    function test_EpochCutoffFreezesFullBoardAndGatingRestartsFromZero() public {
        _fillTiedBoard();
        uint256 end = canvas.epochEnd(0);
        vm.warp(end - 1);
        _paint(66, 21);
        (address[] memory oldPainters, uint32[] memory oldCounts) = canvas.getBoard(0);
        vm.warp(end);
        _paint(66, 19);
        assertTrue(canvas.epochEnded(0));
        assertFalse(canvas.isWhitelisted(1, actors[66]));
        _paint(66, 1);
        assertTrue(canvas.isWhitelisted(1, actors[66]));
        assertEq(canvas.pixelsPaintedIn(0, actors[66]), 21);
        assertEq(canvas.pixelsPaintedIn(1, actors[66]), 20);
        // Inactivity creates genuinely empty epochs; no stale whitelist is carried forward.
        vm.warp(canvas.epochStart(5));
        _paint(65, 100);
        (address[] memory painters, uint32[] memory counts) = canvas.getBoard(0);
        assertEq(abi.encode(painters, counts), abi.encode(oldPainters, oldCounts));
        for (uint64 epoch = 2; epoch < 5; ++epoch) {
            (painters, counts) = canvas.getBoard(epoch);
            assertEq(painters.length, 0);
            assertEq(counts.length, 0);
            assertFalse(canvas.isWhitelisted(epoch, actors[66]));
            assertTrue(canvas.epochEnded(epoch));
        }
        assertEq(canvas.pixelAt(0), 1, "canvas persists between rounds");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_MinPixelsIsInclusiveAndCumulative(uint16 thresholdSeed) public {
        uint256 threshold = bound(thresholdSeed, 1, 250);
        canvas = new PixelFun(address(token), threshold);
        uint256 remaining = threshold - 1;
        while (remaining != 0) {
            uint256 n = remaining > 100 ? 100 : remaining;
            _paint(0, n);
            remaining -= n;
        }
        assertFalse(canvas.isWhitelisted(0, actors[0]));
        (address[] memory painters,) = canvas.getBoard(0);
        assertEq(painters.length, 0);
        _paint(0, 1);
        assertTrue(canvas.isWhitelisted(0, actors[0]));
        uint32[] memory counts;
        (painters, counts) = canvas.getBoard(0);
        assertEq(painters.length, 1);
        assertEq(painters[0], actors[0]);
        assertEq(counts[0], threshold);
    }

    function test_ZeroMinimumStillRequiresPaintingAndNeverDuplicatesEntry() public {
        canvas = new PixelFun(address(token), 0);
        assertFalse(canvas.isWhitelisted(0, actors[0]));
        _paint(0, 1);
        _paint(0, 1);
        (address[] memory painters, uint32[] memory counts) = canvas.getBoard(0);
        assertEq(painters.length, 1);
        assertEq(painters[0], actors[0]);
        assertEq(counts[0], 2);
    }
}
