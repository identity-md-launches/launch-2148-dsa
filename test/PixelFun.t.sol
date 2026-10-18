// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PixelFun} from "../src/PixelFun.sol";

contract MockIMD is ERC20 {
    constructor() ERC20("IMD", "IMD") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

contract FeeToken is ERC20 {
    constructor() ERC20("Fee", "FEE") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function _update(address from, address to, uint256 v) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = v / 100;
            super._update(from, address(0xFEE), fee);
            v -= fee;
        }
        super._update(from, to, v);
    }
}

contract LowDecimals is ERC20 {
    constructor() ERC20("L", "L") {}

    function decimals() public pure override returns (uint8) {
        return 2;
    }
}

/// Token that calls back into PixelFun on transfer.
contract ReentrantToken is ERC20 {
    PixelFun public target;
    uint256 public mode;

    constructor() ERC20("R", "R") {}

    function setTarget(PixelFun t, uint256 m) external {
        target = t;
        mode = m;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function _update(address from, address to, uint256 v) internal override {
        super._update(from, to, v);
        if (mode == 1 && from == address(target)) {
            mode = 0;
            target.withdraw(1);
        }
    }
}

contract PixelFunTest is Test {
    MockIMD token;
    PixelFun pf;
    uint256 constant P = 5e15;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        vm.warp(1_000_000);
        token = new MockIMD();
        pf = new PixelFun(address(token), 20);
        _fund(alice, 1000 ether);
        _fund(bob, 1000 ether);
    }

    function _fund(address u, uint256 a) internal {
        token.mint(u, a);
        vm.startPrank(u);
        token.approve(address(pf), a);
        pf.deposit(a);
        vm.stopPrank();
    }

    function _paint(address u, uint32 startId, uint256 n, uint8 color) internal {
        uint32[] memory ids = new uint32[](n);
        uint8[] memory cs = new uint8[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = startId + uint32(i);
            cs[i] = color;
        }
        vm.prank(u);
        pf.paint(ids, cs);
    }

    function _one(uint32 id, uint8 c) internal pure returns (uint32[] memory ids, uint8[] memory cs) {
        ids = new uint32[](1);
        cs = new uint8[](1);
        ids[0] = id;
        cs[0] = c;
    }

    function test_constants() public view {
        assertEq(pf.PRICE(), P);
        assertEq(pf.WIDTH(), 512);
        assertEq(pf.MIN_PIXELS(), 20);
        assertEq(pf.EPOCH_START(), 1_000_000);
        assertEq(address(pf.imd()), address(token));
    }

    function test_constructorZeroAddressReverts() public {
        vm.expectRevert(PixelFun.ZeroAddress.selector);
        new PixelFun(address(0), 20);
    }

    function test_lowDecimalsRejected() public {
        LowDecimals l = new LowDecimals();
        PixelFun p2 = new PixelFun(address(l), 20);
        vm.expectRevert(PixelFun.UnsupportedDecimals.selector);
        p2.deposit(1);
    }

    function test_depositWithdraw() public {
        assertEq(pf.balanceOf(alice), 1000 ether);
        vm.prank(alice);
        pf.withdraw(400 ether);
        assertEq(pf.balanceOf(alice), 600 ether);
        assertEq(token.balanceOf(alice), 400 ether);
        vm.prank(alice);
        vm.expectRevert(PixelFun.InsufficientBalance.selector);
        pf.withdraw(600 ether + 1);
        vm.prank(bob);
        vm.expectRevert(PixelFun.ZeroAmount.selector);
        pf.withdraw(0);
    }

    function test_withdrawAfterPaintOnlyUnspent() public {
        _paint(alice, 0, 10, 1);
        vm.prank(alice);
        pf.withdraw(1000 ether - 10 * P);
        assertEq(pf.balanceOf(alice), 0);
        vm.prank(alice);
        vm.expectRevert(PixelFun.InsufficientBalance.selector);
        pf.withdraw(1);
    }

    function test_feeOnTransferCreditsReceived() public {
        FeeToken f = new FeeToken();
        PixelFun p2 = new PixelFun(address(f), 20);
        f.mint(alice, 100 ether);
        vm.startPrank(alice);
        f.approve(address(p2), 100 ether);
        vm.expectEmit(address(p2));
        emit PixelFun.Deposited(alice, 99 ether);
        p2.deposit(100 ether);
        assertEq(p2.balanceOf(alice), 99 ether);
        assertEq(f.balanceOf(address(p2)), 99 ether);
        p2.withdraw(99 ether);
        vm.stopPrank();
        assertEq(f.balanceOf(address(p2)), 0);
    }

    function test_paintCostAndBurn() public {
        uint256 deadBefore = token.balanceOf(DEAD);
        (uint32[] memory ids, uint8[] memory cs) = _one(5, 7);
        vm.expectEmit(address(pf));
        emit PixelFun.Painted(alice, 0, ids, cs, P);
        vm.prank(alice);
        pf.paint(ids, cs);
        assertEq(token.balanceOf(DEAD) - deadBefore, P);
        assertEq(pf.balanceOf(alice), 1000 ether - P);
        assertEq(pf.pixelAt(5), 8);
        assertEq(pf.totalPixelsPainted(), 1);
        assertEq(pf.totalBurned(), P);
        _paint(alice, 100, 100, 31);
        assertEq(token.balanceOf(DEAD) - deadBefore, 101 * P);
    }

    function test_boundsAndPalette() public {
        (uint32[] memory ids, uint8[] memory cs) = _one(262_144, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PixelFun.PixelOutOfBounds.selector, 262_144));
        pf.paint(ids, cs);
        (ids, cs) = _one(262_143, 32);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PixelFun.ColorOutOfRange.selector, 32));
        pf.paint(ids, cs);
        (ids, cs) = _one(262_143, 31);
        vm.prank(alice);
        pf.paint(ids, cs);
        assertEq(pf.pixelAt(262_143), 32);
        vm.expectRevert(abi.encodeWithSelector(PixelFun.PixelOutOfBounds.selector, 262_144));
        pf.pixelAt(262_144);
    }

    function test_batchLimits() public {
        vm.startPrank(alice);
        vm.expectRevert(PixelFun.BadBatchSize.selector);
        pf.paint(new uint32[](0), new uint8[](0));
        vm.expectRevert(PixelFun.BadBatchSize.selector);
        pf.paint(new uint32[](101), new uint8[](101));
        vm.expectRevert(PixelFun.LengthMismatch.selector);
        pf.paint(new uint32[](2), new uint8[](3));
        pf.paint(new uint32[](100), new uint8[](100));
        vm.stopPrank();
    }

    function test_insufficientBalance() public {
        address carol = address(0xCA201);
        _fund(carol, 2 * P);
        (uint32[] memory ids, uint8[] memory cs) = _one(1, 1);
        vm.prank(carol);
        pf.paint(ids, cs);
        vm.prank(carol);
        pf.paint(ids, cs);
        vm.prank(carol);
        vm.expectRevert(PixelFun.InsufficientBalance.selector);
        pf.paint(ids, cs);
        vm.prank(address(0xBAD));
        vm.expectRevert(PixelFun.InsufficientBalance.selector);
        pf.paint(ids, cs);
    }

    function test_packedSlotBoundaries() public {
        uint32[] memory ids = new uint32[](6);
        uint8[] memory cs = new uint8[](6);
        ids[0] = 30;
        ids[1] = 31;
        ids[2] = 32;
        ids[3] = 33;
        ids[4] = 0;
        ids[5] = 63;
        cs[0] = 1;
        cs[1] = 2;
        cs[2] = 3;
        cs[3] = 4;
        cs[4] = 0;
        cs[5] = 31;
        vm.prank(alice);
        pf.paint(ids, cs);
        assertEq(pf.pixelAt(29), 0);
        assertEq(pf.pixelAt(30), 2);
        assertEq(pf.pixelAt(31), 3);
        assertEq(pf.pixelAt(32), 4);
        assertEq(pf.pixelAt(33), 5);
        assertEq(pf.pixelAt(34), 0);
        assertEq(pf.pixelAt(0), 1);
        assertEq(pf.pixelAt(63), 32);
        bytes memory raw = pf.getPixels(0, 2);
        assertEq(raw.length, 64);
        assertEq(uint8(raw[0]), 1);
        assertEq(uint8(raw[30]), 2);
        assertEq(uint8(raw[31]), 3);
        assertEq(uint8(raw[32]), 4);
        assertEq(uint8(raw[33]), 5);
        assertEq(uint8(raw[63]), 32);
        // overwrite neighbour does not disturb
        (uint32[] memory one, uint8[] memory oc) = _one(31, 9);
        vm.prank(alice);
        pf.paint(one, oc);
        assertEq(pf.pixelAt(30), 2);
        assertEq(pf.pixelAt(31), 10);
        assertEq(pf.pixelAt(32), 4);
        // last slot
        bytes memory last = pf.getPixels(8191, 1);
        assertEq(last.length, 32);
    }

    function test_getPixelsRange() public {
        vm.expectRevert(PixelFun.BadRange.selector);
        pf.getPixels(0, 0);
        vm.expectRevert(PixelFun.BadRange.selector);
        pf.getPixels(0, 1025);
        vm.expectRevert(PixelFun.BadRange.selector);
        pf.getPixels(8191, 2);
        assertEq(pf.getPixels(0, 1024).length, 32_768);
    }

    function test_duplicateIdsLastWinsAllPaid() public {
        uint32[] memory ids = new uint32[](3);
        uint8[] memory cs = new uint8[](3);
        ids[0] = 7;
        ids[1] = 7;
        ids[2] = 7;
        cs[0] = 1;
        cs[1] = 2;
        cs[2] = 3;
        vm.prank(alice);
        pf.paint(ids, cs);
        assertEq(pf.pixelAt(7), 4);
        assertEq(pf.totalPixelsPainted(), 3);
        assertEq(pf.pixelsPaintedIn(0, alice), 3);
        assertEq(pf.balanceOf(alice), 1000 ether - 3 * P);
    }

    function test_epochBoundaries() public {
        assertEq(pf.currentEpoch(), 0);
        assertEq(pf.epochStart(0), 1_000_000);
        assertEq(pf.epochEnd(0), 1_000_000 + 3 days);
        vm.warp(1_000_000 + 3 days - 1);
        assertEq(pf.currentEpoch(), 0);
        assertFalse(pf.epochEnded(0));
        _paint(alice, 0, 1, 0);
        vm.warp(1_000_000 + 3 days);
        assertEq(pf.currentEpoch(), 1);
        assertTrue(pf.epochEnded(0));
        _paint(alice, 0, 2, 0);
        assertEq(pf.pixelsPaintedIn(0, alice), 1);
        assertEq(pf.pixelsPaintedIn(1, alice), 2);
    }

    function test_minPixelsGating() public {
        _paint(alice, 0, 19, 0);
        assertFalse(pf.isWhitelisted(0, alice));
        (address[] memory p,) = pf.getBoard(0);
        assertEq(p.length, 0);
        _paint(alice, 0, 1, 0);
        assertTrue(pf.isWhitelisted(0, alice));
        (address[] memory p2, uint32[] memory c2) = pf.getBoard(0);
        assertEq(p2.length, 1);
        assertEq(p2[0], alice);
        assertEq(c2[0], 20);
    }

    function _painter(uint256 i) internal pure returns (address) {
        return address(uint160(0x10000 + i));
    }

    function _fillBoard() internal {
        // painters 0..65 paint 20+i pixels; painter 0 is the minimum (20)
        for (uint256 i; i < 66; ++i) {
            address u = _painter(i);
            _fund(u, 1 ether);
            uint256 n = 20 + i;
            if (n > 100) {
                _paint(u, 0, 100, 0);
                n -= 100;
            }
            _paint(u, 0, n, 0);
        }
    }

    function test_boardInsertSortedAndDisplace() public {
        _fillBoard();
        (address[] memory p, uint32[] memory c) = pf.getBoard(0);
        assertEq(p.length, 66);
        for (uint256 i; i < 66; ++i) {
            assertEq(p[i], _painter(65 - i));
            assertEq(c[i], 20 + 65 - i);
        }
        // newcomer with equal count (20) to min does NOT displace
        address n1 = address(0xD00D);
        _fund(n1, 1 ether);
        _paint(n1, 0, 20, 0);
        assertFalse(pf.isWhitelisted(0, n1));
        assertTrue(pf.isWhitelisted(0, _painter(0)));
        // strictly greater displaces lowest
        _paint(n1, 0, 1, 0);
        assertTrue(pf.isWhitelisted(0, n1));
        assertFalse(pf.isWhitelisted(0, _painter(0)));
        (p, c) = pf.getBoard(0);
        assertEq(p.length, 66);
        // n1 has 21, ties painter(1) who reached 21 first -> painter(1) ranks above n1
        assertEq(p[64], _painter(1));
        assertEq(p[65], n1);
        // next newcomer with 22 displaces n1 (the later 21), not painter(1)
        address n2 = address(0xD00E);
        _fund(n2, 1 ether);
        _paint(n2, 0, 22, 0);
        assertFalse(pf.isWhitelisted(0, n1));
        assertTrue(pf.isWhitelisted(0, _painter(1)));
        assertTrue(pf.isWhitelisted(0, n2));
        // displaced painter can return by painting more
        _paint(n1, 0, 30, 0);
        assertTrue(pf.isWhitelisted(0, n1));
        assertFalse(pf.isWhitelisted(0, _painter(1)));
    }

    function test_tieOrderingAndMinUpdateOnIncrease() public {
        _paint(alice, 0, 20, 0);
        _paint(bob, 0, 20, 0);
        (address[] memory p,) = pf.getBoard(0);
        assertEq(p[0], alice);
        assertEq(p[1], bob);
        _paint(alice, 0, 1, 0);
        _paint(bob, 0, 1, 0);
        (p,) = pf.getBoard(0);
        assertEq(p[0], alice);
        _paint(bob, 0, 1, 0);
        (p,) = pf.getBoard(0);
        assertEq(p[0], bob);
    }

    function test_frozenBoardAfterEpoch() public {
        _paint(alice, 0, 20, 0);
        vm.warp(1_000_000 + 3 days);
        _paint(bob, 0, 50, 0);
        _paint(alice, 0, 20, 0);
        (address[] memory p, uint32[] memory c) = pf.getBoard(0);
        assertEq(p.length, 1);
        assertEq(p[0], alice);
        assertEq(c[0], 20);
        assertFalse(pf.isWhitelisted(0, bob));
        assertTrue(pf.isWhitelisted(1, bob));
        (p,) = pf.getBoard(1);
        assertEq(p[0], bob);
    }

    function test_reentrancyBlocked() public {
        ReentrantToken r = new ReentrantToken();
        PixelFun p2 = new PixelFun(address(r), 1);
        r.mint(alice, 10 ether);
        vm.startPrank(alice);
        r.approve(address(p2), 10 ether);
        p2.deposit(10 ether);
        vm.stopPrank();
        r.setTarget(p2, 1);
        vm.prank(alice);
        vm.expectRevert(); // ReentrancyGuardReentrantCall bubbles up
        p2.withdraw(1 ether);
        assertEq(p2.balanceOf(alice), 10 ether);
        r.setTarget(p2, 1);
        (uint32[] memory ids, uint8[] memory cs) = _one(1, 1);
        vm.prank(alice);
        vm.expectRevert();
        p2.paint(ids, cs);
    }

    function test_gasFullBatchWithFullBoard() public {
        _fillBoard();
        address n = address(0xFACE);
        _fund(n, 1 ether);
        uint32[] memory ids = new uint32[](100);
        uint8[] memory cs = new uint8[](100);
        for (uint256 i; i < 100; ++i) {
            ids[i] = uint32(i * 2600);
        }
        vm.prank(n);
        uint256 g = gasleft();
        pf.paint(ids, cs);
        g -= gasleft();
        assertLt(g, 3_500_000);
    }

    function testFuzz_invariants(uint32 seed, uint8 rounds) public {
        rounds = uint8(bound(rounds, 1, 20));
        for (uint256 r; r < rounds; ++r) {
            uint256 x = uint256(keccak256(abi.encode(seed, r)));
            address u = x & 1 == 0 ? alice : bob;
            uint256 action = (x >> 1) % 3;
            if (action == 0) {
                _paint(u, uint32((x >> 8) % 262_000), 1 + (x >> 40) % 100, uint8((x >> 50) % 32));
            } else if (action == 1) {
                uint256 a = ((x >> 60) % 1e18) + 1;
                if (a <= pf.balanceOf(u)) {
                    vm.prank(u);
                    pf.withdraw(a);
                }
            } else {
                vm.warp(block.timestamp + (x >> 70) % 2 days);
            }
            assertLe(pf.balanceOf(alice) + pf.balanceOf(bob), token.balanceOf(address(pf)));
            assertEq(pf.totalBurned(), P * pf.totalPixelsPainted());
            assertEq(token.balanceOf(DEAD), pf.totalBurned());
            assertEq(pf.totalDeposited(), token.balanceOf(address(pf)));
        }
    }
}
