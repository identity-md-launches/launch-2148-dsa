// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PixelFun} from "src/PixelFun.sol";
import {CanvasToken} from "./PixelFunTokens.sol";

/// @dev Stores every painter's score and chronological reach order. It does not maintain a board or cached minimum.
contract PixelFunBoardHandler is Test {
    PixelFun public immutable canvas;
    CanvasToken public immutable token;
    uint256 public constant ACTORS = 70;
    address[ACTORS] public actors;
    mapping(address => uint256) public indexPlusOne;
    uint32[ACTORS] public scores;
    uint256[ACTORS] public reached;
    uint256 public paintCalls;
    uint256 public paintedPixels;

    constructor(PixelFun canvas_, CanvasToken token_) {
        canvas = canvas_;
        token = token_;
        for (uint256 i; i < ACTORS; ++i) {
            address actor = address(uint160(uint256(keccak256(abi.encode("board competitor", i)))));
            actors[i] = actor;
            indexPlusOne[actor] = i + 1;
            _fund(actor, 10 ether);
            // Full board plus four real competitors, poised at the admission threshold.
            _paint(i, i < 66 ? 20 + i % 4 : 19);
        }
    }

    function _fund(address actor, uint256 amount) internal {
        token.mint(actor, amount);
        vm.startPrank(actor);
        token.approve(address(canvas), amount);
        canvas.deposit(amount);
        vm.stopPrank();
    }

    function _paint(uint256 index, uint256 n) internal {
        address actor = actors[index];
        uint256 cost = n * 5e15;
        uint256 balance = canvas.balanceOf(actor);
        if (balance < cost) _fund(actor, cost - balance);
        vm.prank(actor);
        canvas.paint(new uint32[](n), new uint8[](n));
        scores[index] += uint32(n);
        reached[index] = ++paintCalls;
        paintedPixels += n;
    }

    function paint(uint256 actorSeed, uint256 countSeed) external {
        _paint(actorSeed % ACTORS, bound(countSeed, 1, 100));
    }

    function catchUpToAnotherPainter(uint256 actorSeed, uint256 referenceSeed) external {
        uint256 index = actorSeed % ACTORS;
        uint256 referenceScore = scores[referenceSeed % ACTORS];
        uint256 count = referenceScore > scores[index] ? referenceScore - scores[index] : 1;
        if (count > 100) count = 100;
        _paint(index, count);
    }

    function increaseCurrentMinimum(uint256 countSeed) external {
        (address[] memory painters,) = canvas.getBoard(0);
        uint256 index = indexPlusOne[painters[painters.length - 1]] - 1;
        _paint(index, bound(countSeed, 1, 100));
    }

    function advanceWithinEpoch(uint256 secondsSeed) external {
        uint256 end = canvas.EPOCH_START() + 3 days;
        uint256 next = vm.getBlockTimestamp() + bound(secondsSeed, 0, 1 hours);
        vm.warp(next < end ? next : end - 1);
    }
}
