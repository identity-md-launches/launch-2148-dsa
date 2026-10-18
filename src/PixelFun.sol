// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PixelFun
/// @notice Ownerless 512x512 on-chain pixel canvas. Every painted pixel burns 0.005 IMD.
/// @dev Burn method: tokens are transferred to 0x...dEaD. The IMD token is a bridged token on
///      Robinhood Chain whose burn(uint256) could not be confirmed as permissionless (bridged
///      tokens commonly restrict burn to the bridge), and a transfer to the dead address works for
///      every ERC-20. No owner, admin, pause or upgrade path exists.
contract PixelFun is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- constants
    uint256 public constant WIDTH = 512;
    uint256 public constant HEIGHT = 512;
    uint256 public constant PIXEL_COUNT = WIDTH * HEIGHT;
    uint256 public constant SLOT_COUNT = PIXEL_COUNT / 32;
    uint256 public constant PALETTE_SIZE = 32;
    uint256 public constant MAX_BATCH = 100;
    uint256 public constant BOARD_SIZE = 66;
    uint256 public constant EPOCH_LENGTH = 3 days;
    uint256 public constant MAX_READ_SLOTS = 1024;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // ---------------------------------------------------------------- immutables
    IERC20 public immutable imd;
    uint256 public immutable EPOCH_START;
    uint256 public immutable MIN_PIXELS;

    // ---------------------------------------------------------------- storage
    /// @dev Cached price, set on first use from the token's decimals (constructor may not call out).
    uint256 private _cachedPrice;

    mapping(address => uint256) public balanceOf;
    uint256 public totalDeposited;
    uint256 public totalBurned;
    uint256 public totalPixelsPainted;
    mapping(uint64 => mapping(address => uint32)) public pixelsPaintedIn;

    /// @dev 32 pixels per slot; pixel (id % 32) lives in byte (id % 32) counted from the most
    ///      significant byte, so a slot's big-endian bytes are in row-major order.
    uint256[SLOT_COUNT] private _pixels;

    /// @dev Board entry packed in one word: painter (160) | count (32) | seq (64).
    struct Board {
        uint8 size;
        uint8 minIndex;
        uint256[BOARD_SIZE] entries;
    }

    mapping(uint64 => Board) private _boards;
    /// @dev index + 1 of a painter on an epoch board; 0 = not on board.
    mapping(uint64 => mapping(address => uint256)) private _boardIndex;
    /// @dev Global monotonic counter: orders "who reached the count first", even within a block.
    uint64 private _seq;

    // ---------------------------------------------------------------- events / errors
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Painted(address indexed painter, uint64 indexed epoch, uint32[] ids, uint8[] colors, uint256 burned);

    error ZeroAddress();
    error ZeroAmount();
    error UnsupportedDecimals();
    error InsufficientBalance();
    error LengthMismatch();
    error BadBatchSize();
    error PixelOutOfBounds(uint256 id);
    error ColorOutOfRange(uint256 color);
    error BadRange();

    constructor(address imd_, uint256 minPixels_) {
        if (imd_ == address(0)) revert ZeroAddress();
        imd = IERC20(imd_);
        MIN_PIXELS = minPixels_;
        EPOCH_START = block.timestamp;
    }

    // ---------------------------------------------------------------- price
    /// @notice 0.005 IMD in token units: 5 * 10**(decimals-3).
    function PRICE() public view returns (uint256) {
        uint256 p = _cachedPrice;
        return p != 0 ? p : _computePrice();
    }

    function _computePrice() private view returns (uint256) {
        uint8 d = IERC20Metadata(address(imd)).decimals();
        if (d < 3 || d > 77) revert UnsupportedDecimals();
        return 5 * 10 ** (d - 3);
    }

    function _price() private returns (uint256 p) {
        p = _cachedPrice;
        if (p == 0) {
            p = _computePrice();
            _cachedPrice = p;
        }
    }

    // ---------------------------------------------------------------- vault
    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _price(); // validates the token's decimals once
        uint256 before = imd.balanceOf(address(this));
        imd.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = imd.balanceOf(address(this)) - before;
        balanceOf[msg.sender] += received;
        totalDeposited += received;
        emit Deposited(msg.sender, received);
    }

    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 bal = balanceOf[msg.sender];
        if (amount > bal) revert InsufficientBalance();
        balanceOf[msg.sender] = bal - amount;
        totalDeposited -= amount;
        imd.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // ---------------------------------------------------------------- paint
    function paint(uint32[] calldata ids, uint8[] calldata colors) external nonReentrant {
        uint256 n = ids.length;
        if (n != colors.length) revert LengthMismatch();
        if (n == 0 || n > MAX_BATCH) revert BadBatchSize();

        uint256 cost = n * _price();
        uint256 bal = balanceOf[msg.sender];
        if (cost > bal) revert InsufficientBalance();
        balanceOf[msg.sender] = bal - cost;
        totalDeposited -= cost;
        totalBurned += cost;

        for (uint256 i; i < n; ++i) {
            uint256 id = ids[i];
            uint256 c = colors[i];
            if (id >= PIXEL_COUNT) revert PixelOutOfBounds(id);
            if (c >= PALETTE_SIZE) revert ColorOutOfRange(c);
            uint256 shift = (31 - (id & 31)) * 8;
            uint256 slot = id >> 5;
            _pixels[slot] = (_pixels[slot] & ~(uint256(0xff) << shift)) | ((c + 1) << shift);
        }

        totalPixelsPainted += n;
        uint64 epoch = uint64(currentEpoch());
        uint32 count = pixelsPaintedIn[epoch][msg.sender] + uint32(n);
        pixelsPaintedIn[epoch][msg.sender] = count;
        if (count >= MIN_PIXELS) _updateBoard(epoch, msg.sender, count);

        imd.safeTransfer(BURN_ADDRESS, cost);
        emit Painted(msg.sender, epoch, ids, colors, cost);
    }

    // ---------------------------------------------------------------- board
    /// @dev Unsorted fixed array of 66 one-word entries plus a cached index of the lowest entry.
    ///      An existing member's update and a rejected newcomer cost O(1); only when the minimum
    ///      entry changes (displacement, or the minimum itself increases) is it rescanned: at most
    ///      66 SLOADs (~140k gas cold worst case), bounded regardless of the number of painters.
    function _updateBoard(uint64 epoch, address painter, uint32 count) private {
        Board storage b = _boards[epoch];
        uint64 seq = ++_seq;
        uint256 entry = _pack(painter, count, seq);
        uint256 idx = _boardIndex[epoch][painter];
        if (idx != 0) {
            b.entries[idx - 1] = entry;
            if (idx - 1 == b.minIndex) b.minIndex = _findMin(b, b.size);
            return;
        }
        uint256 size = b.size;
        if (size < BOARD_SIZE) {
            b.entries[size] = entry;
            _boardIndex[epoch][painter] = size + 1;
            b.size = uint8(size + 1);
            b.minIndex = _findMin(b, size + 1);
            return;
        }
        uint256 m = b.minIndex;
        uint256 old = b.entries[m];
        if (count <= _count(old)) return; // strictly greater required
        delete _boardIndex[epoch][address(uint160(old))];
        b.entries[m] = entry;
        _boardIndex[epoch][painter] = m + 1;
        b.minIndex = _findMin(b, size);
    }

    /// @dev Lowest entry: smallest count, and among equal counts the latest seq (reached last).
    function _findMin(Board storage b, uint256 size) private view returns (uint8 minI) {
        uint256 best = b.entries[0];
        for (uint256 i = 1; i < size; ++i) {
            uint256 e = b.entries[i];
            if (_ranksBelow(e, best)) {
                best = e;
                minI = uint8(i);
            }
        }
    }

    /// @dev True if a ranks strictly below b.
    function _ranksBelow(uint256 a, uint256 b) private pure returns (bool) {
        uint256 ca = _count(a);
        uint256 cb = _count(b);
        return ca < cb || (ca == cb && _seqOf(a) > _seqOf(b));
    }

    function _pack(address p, uint32 c, uint64 s) private pure returns (uint256) {
        return uint256(uint160(p)) | (uint256(c) << 160) | (uint256(s) << 192);
    }

    function _count(uint256 e) private pure returns (uint32) {
        return uint32(e >> 160);
    }

    function _seqOf(uint256 e) private pure returns (uint64) {
        return uint64(e >> 192);
    }

    // ---------------------------------------------------------------- views
    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - EPOCH_START) / EPOCH_LENGTH;
    }

    function epochStart(uint256 epoch) public view returns (uint256) {
        return EPOCH_START + epoch * EPOCH_LENGTH;
    }

    /// @notice Exclusive end: the epoch covers [epochStart, epochEnd).
    function epochEnd(uint256 epoch) public view returns (uint256) {
        return EPOCH_START + (epoch + 1) * EPOCH_LENGTH;
    }

    function epochEnded(uint256 epoch) external view returns (bool) {
        return block.timestamp >= epochEnd(epoch);
    }

    function isWhitelisted(uint64 epoch, address account) external view returns (bool) {
        return _boardIndex[epoch][account] != 0;
    }

    /// @notice Board sorted by count descending, ties by earlier reach first.
    function getBoard(uint64 epoch) external view returns (address[] memory painters, uint32[] memory counts) {
        Board storage b = _boards[epoch];
        uint256 size = b.size;
        uint256[] memory e = new uint256[](size);
        for (uint256 i; i < size; ++i) {
            e[i] = b.entries[i];
        }
        // insertion sort, n <= 66
        for (uint256 i = 1; i < size; ++i) {
            uint256 key = e[i];
            uint256 j = i;
            while (j > 0 && _ranksBelow(e[j - 1], key)) {
                e[j] = e[j - 1];
                --j;
            }
            e[j] = key;
        }
        painters = new address[](size);
        counts = new uint32[](size);
        for (uint256 i; i < size; ++i) {
            painters[i] = address(uint160(e[i]));
            counts[i] = _count(e[i]);
        }
    }

    function pixelAt(uint256 id) external view returns (uint8) {
        if (id >= PIXEL_COUNT) revert PixelOutOfBounds(id);
        return uint8(_pixels[id >> 5] >> ((31 - (id & 31)) * 8));
    }

    /// @notice Raw packed canvas: slotCount*32 bytes, byte k = pixel startSlot*32 + k.
    function getPixels(uint256 startSlot, uint256 slotCount) external view returns (bytes memory out) {
        if (slotCount == 0 || slotCount > MAX_READ_SLOTS || startSlot + slotCount > SLOT_COUNT) revert BadRange();
        out = new bytes(slotCount * 32);
        for (uint256 i; i < slotCount; ++i) {
            uint256 w = _pixels[startSlot + i];
            assembly ("memory-safe") {
                mstore(add(add(out, 32), mul(i, 32)), w)
            }
        }
    }
}
