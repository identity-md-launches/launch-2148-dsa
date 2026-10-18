// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PixelFun} from "src/PixelFun.sol";

/// @dev Local dependencies only. None of these contracts is a deployment artifact.
contract CanvasToken is ERC20 {
    uint8 private immutable _decimals;
    uint256 public immutable feeBps;
    address public immutable feeCollector;
    bool public failTransfer;
    bool public failTransferFrom;
    bool public revertTransfers;
    error TokenTransferRejected();

    constructor(uint8 decimals_, uint256 feeBps_, address feeCollector_) ERC20("Canvas test token", "CTT") {
        _decimals = decimals_;
        feeBps = feeBps_;
        feeCollector = feeCollector_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFailures(bool transfer_, bool transferFrom_, bool revert_) external {
        failTransfer = transfer_;
        failTransferFrom = transferFrom_;
        revertTransfers = revert_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (revertTransfers) revert TokenTransferRejected();
        if (failTransfer) return false;
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (revertTransfers) revert TokenTransferRejected();
        if (failTransferFrom) return false;
        return super.transferFrom(from, to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0) && feeBps != 0) {
            uint256 fee = amount * feeBps / 10_000;
            super._update(from, feeCollector, fee);
            amount -= fee;
        }
        super._update(from, to, amount);
    }
}

/// @dev ERC-20 with legacy transfer/transferFrom signatures that return no data.
contract NoReturnCanvasToken {
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev Swallows the inner revert so tests can distinguish the guard from unrelated token failures.
contract CallbackCanvasToken is ERC20 {
    PixelFun public target;
    bytes private _payload;
    bool private _armed;
    bool public innerSucceeded;
    bytes public innerResult;
    uint256 public attempts;
    address private _observedUser;
    uint256 public observedVaultBalance;

    constructor() ERC20("Callback test token", "CBT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(PixelFun target_, bytes calldata payload_, address observedUser_) external {
        target = target_;
        _payload = payload_;
        _observedUser = observedUser_;
        _armed = true;
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (_armed && (from == address(target) || to == address(target))) {
            _armed = false;
            ++attempts;
            observedVaultBalance = target.balanceOf(_observedUser);
            (innerSucceeded, innerResult) = address(target).call(_payload);
        }
    }
}
