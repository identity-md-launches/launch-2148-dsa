// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PixelFun} from "src/PixelFun.sol";
import {CanvasToken} from "./helpers/PixelFunTokens.sol";

contract PixelFunCanvasPropertiesTest is Test {
    CanvasToken internal token;
    PixelFun internal canvas;
    address internal painter;
    uint256 internal constant PRICE = 5e15;

    function setUp() public {
        vm.warp(1_700_000_017);
        painter = makeAddr("canvas painter");
        token = new CanvasToken(18, 0, makeAddr("unused fee collector"));
        canvas = new PixelFun(address(token), 20);
        _fund(canvas, 10 ether);
    }

    function _fund(PixelFun target, uint256 amount) internal {
        token.mint(painter, amount);
        vm.startPrank(painter);
        token.approve(address(target), amount);
        target.deposit(amount);
        vm.stopPrank();
    }

    function test_FreshCanvasIsUnpaintedIncludingLastPage() public view {
        bytes memory zeroPage = new bytes(32768);
        for (uint256 page; page < 8; ++page) {
            assertEq(canvas.getPixels(page * 1024, 1024), zeroPage);
        }
        assertEq(canvas.pixelAt(0), 0);
        assertEq(canvas.pixelAt(262143), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_OverwritesMatchByteArrayAcrossArbitrarySlotBoundary(
        uint16 slotSeed,
        uint8 countSeed,
        bytes32 seed
    ) public {
        uint256 startSlot = bound(slotSeed, 0, 8190);
        bytes memory expected = new bytes(64);
        uint32[] memory initialIds = new uint32[](64);
        uint8[] memory initialColors = new uint8[](64);
        for (uint256 i; i < 64; ++i) {
            initialIds[i] = uint32(startSlot * 32 + i);
            initialColors[i] = 31;
            expected[i] = bytes1(uint8(32));
        }
        vm.prank(painter);
        canvas.paint(initialIds, initialColors);
        uint256 n = bound(countSeed, 1, 100);
        uint32[] memory ids = new uint32[](n);
        uint8[] memory colors = new uint8[](n);
        for (uint256 i; i < n; ++i) {
            uint256 random = uint256(keccak256(abi.encode(seed, i)));
            uint256 offset = random % 64;
            ids[i] = uint32(startSlot * 32 + offset);
            colors[i] = uint8((random >> 8) % 32);
            expected[offset] = bytes1(colors[i] + 1);
        }
        vm.prank(painter);
        canvas.paint(ids, colors);
        assertEq(canvas.getPixels(startSlot, 2), expected);
        for (uint256 i; i < 64; ++i) {
            assertEq(canvas.pixelAt(startSlot * 32 + i), uint8(expected[i]));
        }
        if (startSlot > 0) assertEq(canvas.pixelAt(startSlot * 32 - 1), 0);
        if (startSlot < 8190) assertEq(canvas.pixelAt(startSlot * 32 + 64), 0);
        assertEq(canvas.totalPixelsPainted(), 64 + n);
        assertEq(canvas.balanceOf(painter), 10 ether - (64 + n) * PRICE);
        assertEq(token.balanceOf(canvas.BURN_ADDRESS()), (64 + n) * PRICE);
        assertEq(bytes.concat(canvas.getPixels(startSlot, 1), canvas.getPixels(startSlot + 1, 1)), expected);
    }

    function test_AllPaletteValuesAndRowBoundaryAreEncodedAsIndexPlusOne() public {
        uint32[] memory ids = new uint32[](32);
        uint8[] memory colors = new uint8[](32);
        for (uint256 i; i < 32; ++i) {
            ids[i] = uint32(496 + i);
            colors[i] = uint8(i);
        }
        vm.prank(painter);
        canvas.paint(ids, colors);
        bytes memory raw = canvas.getPixels(15, 2);
        for (uint256 i; i < 64; ++i) {
            uint8 expected = i >= 16 && i < 48 ? uint8(i - 15) : 0;
            assertEq(uint8(raw[i]), expected);
            assertEq(canvas.pixelAt(480 + i), expected);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_BatchPartitionPreservesCanvasAndPayment(bytes32 seed, uint8 lengthSeed, uint8 splitSeed) public {
        uint256 n = bound(lengthSeed, 2, 100);
        uint256 split = bound(splitSeed, 1, n - 1);
        PixelFun partitioned = new PixelFun(address(token), 20);
        _fund(partitioned, 10 ether);
        uint32[] memory ids = new uint32[](n);
        uint8[] memory colors = new uint8[](n);
        uint32[] memory firstIds = new uint32[](split);
        uint8[] memory firstColors = new uint8[](split);
        uint32[] memory lastIds = new uint32[](n - split);
        uint8[] memory lastColors = new uint8[](n - split);
        for (uint256 i; i < n; ++i) {
            uint256 random = uint256(keccak256(abi.encode(seed, i)));
            ids[i] = uint32(random % 96);
            colors[i] = uint8((random >> 8) % 32);
            if (i < split) {
                firstIds[i] = ids[i];
                firstColors[i] = colors[i];
            } else {
                lastIds[i - split] = ids[i];
                lastColors[i - split] = colors[i];
            }
        }
        vm.startPrank(painter);
        canvas.paint(ids, colors);
        partitioned.paint(firstIds, firstColors);
        partitioned.paint(lastIds, lastColors);
        vm.stopPrank();
        assertEq(canvas.getPixels(0, 3), partitioned.getPixels(0, 3));
        assertEq(canvas.balanceOf(painter), partitioned.balanceOf(painter));
        assertEq(canvas.totalBurned(), partitioned.totalBurned());
        assertEq(canvas.pixelsPaintedIn(0, painter), partitioned.pixelsPaintedIn(0, painter));
        (address[] memory a, uint32[] memory ac) = canvas.getBoard(0);
        (address[] memory b, uint32[] memory bc) = partitioned.getBoard(0);
        assertEq(abi.encode(a, ac), abi.encode(b, bc));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_InvalidItemAtAnyPositionRevertsEntireBatch(
        uint8 nSeed,
        uint8 positionSeed,
        uint32 invalidIdSeed,
        uint8 invalidColorSeed,
        bool invalidId
    ) public {
        uint256 n = bound(nSeed, 1, 100);
        uint256 position = bound(positionSeed, 0, n - 1);
        uint32[] memory ids = new uint32[](n);
        uint8[] memory colors = new uint8[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = uint32(i);
            colors[i] = 31;
        }
        bytes memory reason;
        if (invalidId) {
            ids[position] = uint32(bound(invalidIdSeed, 262144, type(uint32).max));
            reason = abi.encodeWithSelector(PixelFun.PixelOutOfBounds.selector, ids[position]);
        } else {
            colors[position] = uint8(bound(invalidColorSeed, 32, type(uint8).max));
            reason = abi.encodeWithSelector(PixelFun.ColorOutOfRange.selector, colors[position]);
        }
        vm.prank(painter);
        vm.expectRevert(reason);
        canvas.paint(ids, colors);
        assertEq(canvas.getPixels(0, 4), new bytes(128));
        assertEq(canvas.totalPixelsPainted(), 0);
        assertEq(canvas.totalBurned(), 0);
        assertEq(canvas.pixelsPaintedIn(0, painter), 0);
        assertEq(canvas.balanceOf(painter), 10 ether);
        assertEq(canvas.totalDeposited(), 10 ether);
        assertEq(token.balanceOf(address(canvas)), 10 ether);
        assertEq(token.balanceOf(canvas.BURN_ADDRESS()), 0);
        assertFalse(canvas.isWhitelisted(0, painter));
    }

    function test_OneWeiShortCannotPaintAndExactFundingCan() public {
        vm.startPrank(painter);
        canvas.withdraw(10 ether - PRICE + 1);
        vm.expectRevert(PixelFun.InsufficientBalance.selector);
        canvas.paint(new uint32[](1), new uint8[](1));
        assertEq(canvas.balanceOf(painter), PRICE - 1);
        token.approve(address(canvas), 1);
        canvas.deposit(1);
        canvas.paint(new uint32[](1), new uint8[](1));
        vm.stopPrank();
        assertEq(canvas.balanceOf(painter), 0);
        assertEq(canvas.pixelAt(0), 1);
        assertEq(token.balanceOf(canvas.BURN_ADDRESS()), PRICE);
    }

    function test_ReadRangeEdgesRejectWithoutAffectingCanvas() public {
        vm.expectRevert(PixelFun.BadRange.selector);
        canvas.getPixels(8192, 1);
        vm.expectRevert(PixelFun.BadRange.selector);
        canvas.getPixels(8191, 1024);
        vm.expectRevert(PixelFun.BadRange.selector);
        canvas.getPixels(0, type(uint256).max);
        // An arithmetic panic also rejects an overflowing range; no particular error is promised.
        vm.expectRevert();
        canvas.getPixels(type(uint256).max, 1);
        vm.expectRevert(abi.encodeWithSelector(PixelFun.PixelOutOfBounds.selector, type(uint256).max));
        canvas.pixelAt(type(uint256).max);
        assertEq(canvas.getPixels(7168, 1024), new bytes(32768));
        assertEq(canvas.getPixels(8191, 1), new bytes(32));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_EpochViewsAtExactEdges(uint16 epochSeed) public {
        uint256 epoch = bound(epochSeed, 0, 10000);
        uint256 start = canvas.EPOCH_START() + epoch * 3 days;
        uint256 end = start + 3 days;
        assertEq(canvas.epochStart(epoch), start);
        assertEq(canvas.epochEnd(epoch), end);
        vm.warp(start);
        assertEq(canvas.currentEpoch(), epoch);
        assertFalse(canvas.epochEnded(epoch));
        vm.warp(end - 1);
        assertEq(canvas.currentEpoch(), epoch);
        assertFalse(canvas.epochEnded(epoch));
        vm.warp(end);
        assertEq(canvas.currentEpoch(), epoch + 1);
        assertTrue(canvas.epochEnded(epoch));
        assertFalse(canvas.epochEnded(epoch + 1));
    }
}
