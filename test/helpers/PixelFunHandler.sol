// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PixelFun} from "src/PixelFun.sol";
import {CanvasToken} from "./PixelFunTokens.sol";

/// @dev Ghosts are updated from successful inputs and the mock's documented fee, never copied from vault getters.
contract PixelFunHandler is Test {
    PixelFun public immutable canvas;
    CanvasToken public immutable token;
    uint256 public immutable price;
    uint256 public immutable feeBps;
    uint256 public constant ACTORS = 5;
    address[ACTORS] public actors;
    mapping(address => uint256) public credits;
    mapping(address => uint256) public grossDeposits;
    mapping(address => uint256) public withdrawals;
    mapping(address => uint256) public spent;
    mapping(address => uint256) public minted;
    mapping(address => uint256) public donated;
    mapping(address => uint256) public receivedWithdrawals;
    mapping(uint64 => mapping(address => uint32)) public counts;
    uint256 public pixels;
    uint256 public surplus;
    uint256 public fees;
    uint256 public depositCalls;
    uint256 public withdrawCalls;
    uint256 public paintCalls;
    uint256 public donationCalls;
    uint256 public rejectedCalls;
    uint256 public roundTripCalls;
    bytes private _colors = new bytes(160);
    uint64 public lastEpoch;
    mapping(uint64 => bytes32) public frozenBoardHash;

    constructor(PixelFun canvas_, CanvasToken token_) {
        canvas = canvas_;
        token = token_;
        price = canvas_.PRICE();
        feeBps = token_.feeBps();
        for (uint256 i; i < ACTORS; ++i) {
            actors[i] = address(uint160(uint256(keccak256(abi.encode("stateful painter", i)))));
            _deposit(actors[i], 5 ether);
        }
    }

    function expectedColors() external view returns (bytes memory) {
        return _colors;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % ACTORS];
    }

    function _net(uint256 amount) internal view returns (uint256) {
        return amount - amount * feeBps / 10000;
    }

    function _deposit(address actor, uint256 amount) internal {
        token.mint(actor, amount);
        minted[actor] += amount;
        vm.startPrank(actor);
        token.approve(address(canvas), amount);
        canvas.deposit(amount);
        vm.stopPrank();
        uint256 net = _net(amount);
        credits[actor] += net;
        grossDeposits[actor] += amount;
        fees += amount - net;
        ++depositCalls;
    }

    function deposit(uint256 actorSeed, uint256 amountSeed) external {
        _deposit(_actor(actorSeed), bound(amountSeed, 1, 100 ether));
    }

    function _withdraw(address actor, uint256 amount) internal {
        vm.prank(actor);
        canvas.withdraw(amount);
        credits[actor] -= amount;
        withdrawals[actor] += amount;
        uint256 net = _net(amount);
        receivedWithdrawals[actor] += net;
        fees += amount - net;
        ++withdrawCalls;
    }

    function withdraw(uint256 actorSeed, uint256 amountSeed) external {
        address actor = _actor(actorSeed);
        if (credits[actor] == 0) _deposit(actor, 1);
        _withdraw(actor, bound(amountSeed, 1, credits[actor]));
    }

    function withdrawAll(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        if (credits[actor] == 0) _deposit(actor, 1);
        _withdraw(actor, credits[actor]);
        assertEq(canvas.balanceOf(actor), 0, "full exit must clear only caller's claim");
    }

    function roundTrip(uint256 actorSeed, uint256 amountSeed) external {
        address actor = _actor(actorSeed);
        uint256 amount = bound(amountSeed, 1, 100 ether);
        uint256 creditBefore = credits[actor];
        uint256 walletBefore = token.balanceOf(actor);
        _deposit(actor, amount);
        _withdraw(actor, _net(amount));
        assertEq(canvas.balanceOf(actor), creditBefore, "roundtrip changed pre-existing credit");
        assertEq(token.balanceOf(actor), walletBefore + _net(_net(amount)), "roundtrip created value");
        ++roundTripCalls;
    }

    function donate(uint256 actorSeed, uint256 amountSeed) external {
        address actor = _actor(actorSeed);
        uint256 amount = bound(amountSeed, 1, 10 ether);
        token.mint(actor, amount);
        minted[actor] += amount;
        vm.prank(actor);
        token.transfer(address(canvas), amount);
        surplus += _net(amount);
        donated[actor] += amount;
        fees += amount - _net(amount);
        ++donationCalls;
    }

    function paint(uint256 actorSeed, uint256 countSeed, bytes32 seed) external {
        address actor = _actor(actorSeed);
        uint256 n = bound(countSeed, 1, 100);
        uint256 cost = n * price;
        if (credits[actor] < cost) _deposit(actor, cost - credits[actor]);
        uint32[] memory ids = new uint32[](n);
        uint8[] memory colors = new uint8[](n);
        uint256[] memory offsets = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 random = uint256(keccak256(abi.encode(seed, i)));
            uint256 offset = random % 160;
            offsets[i] = offset;
            ids[i] = uint32(offset < 96 ? offset : 262080 + offset - 96);
            colors[i] = uint8((random >> 8) % 32);
        }
        vm.prank(actor);
        canvas.paint(ids, colors);
        credits[actor] -= cost;
        spent[actor] += cost;
        pixels += n;
        counts[lastEpoch][actor] += uint32(n);
        for (uint256 i; i < n; ++i) {
            _colors[offsets[i]] = bytes1(colors[i] + 1);
        }
        ++paintCalls;
    }

    function rejectOverspending(uint256 actorSeed, uint256 excessSeed) external {
        address actor = _actor(actorSeed);
        uint256 attempted = credits[actor] + bound(excessSeed, 1, 100 ether);
        vm.prank(actor);
        vm.expectRevert(PixelFun.InsufficientBalance.selector);
        canvas.withdraw(attempted);
        assertEq(canvas.balanceOf(actor), credits[actor]);
        ++rejectedCalls;
    }

    function advanceTime(uint256 deltaSeed) external {
        uint256 next = vm.getBlockTimestamp() + bound(deltaSeed, 0, 3 days + 1);
        uint256 limit = canvas.EPOCH_START() + 8 * 3 days + 3 days - 1;
        if (next > limit) next = limit;
        uint64 nextEpoch = uint64((next - canvas.EPOCH_START()) / 3 days);
        for (uint64 epoch = lastEpoch; epoch < nextEpoch; ++epoch) {
            (address[] memory painters, uint32[] memory boardCounts) = canvas.getBoard(epoch);
            frozenBoardHash[epoch] = keccak256(abi.encode(painters, boardCounts));
        }
        vm.warp(next);
        lastEpoch = nextEpoch;
    }

    /// @dev Called after each campaign: every remaining depositor must still be able to exit.
    function closeAll() external {
        for (uint256 i; i < ACTORS; ++i) {
            address actor = actors[i];
            if (credits[actor] != 0) _withdraw(actor, credits[actor]);
        }
    }
}
