# PixelFun

Ownerless, fully on-chain 512x512 pixel canvas (32-colour palette) on Robinhood Chain (chain id 4663).
Each painted pixel costs 0.005 IMD (`PRICE = 5 * 10**(decimals-3)`), burned immediately.
Contract: `src/PixelFun.sol` (`contract PixelFun`). No owner, admin, pause, upgrade or privileged function.

## Deployment parameters
| arg | value |
|---|---|
| `imd_` | `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127` (IMD on Robinhood Chain) |
| `minPixels_` | `20` |

The constructor makes no external calls (launch checks run it on an empty chain). The token's
`decimals()` is read and validated (>= 3) on first `deposit`/`paint`, then cached; `PRICE()` is a view.
The launch (manifest, deployment, explorer verification, final address) is done by IMD's deployer
after acceptance; this job deploys nothing. Requester / payout wallet: `0xc4a8ea10819d341d19d1dfbba7bb0e0f2295d952`
(the contract has no owner and pays nobody, so it does not appear in the contract).

## Burn method — deviation note
The brief asks to inspect the token for a permissionless `burn(uint256)`. The Robinhood Chain RPC was not
reachable from the build machine (TLS handshake failure), so this could not be confirmed. IMD on Robinhood
Chain is a bridged token, and bridged tokens commonly restrict `burn` to the bridge. PixelFun therefore
**transfers burned tokens to `0x000000000000000000000000000000000000dEaD`**, which works for any ERC-20
and cannot brick painting. `totalBurned` = `PRICE * totalPixelsPainted`.

## Behaviour
- Vault: `deposit(amount)` credits the balance actually received (fee-on-transfer safe); `withdraw(amount)`
  returns unspent balance, always available. Both `nonReentrant`, CEI.
- `paint(uint32[] ids, uint8[] colors)`: 1..100 items, `id = y*512 + x < 262144`, `color < 32`; duplicates
  allowed (last wins, all paid/counted). Storage packs 32 pixels per slot, 1 byte each, pixel `id%32` at byte
  `id%32` from the most significant end; value 0 = never painted, else `color+1`.
- Epochs: `currentEpoch() = (now - EPOCH_START) / 3 days`; epoch `e` covers `[epochStart(e), epochEnd(e))`.
- Board (top 66 per epoch, entry needs >= MIN_PIXELS in that epoch): fixed array of 66 one-word entries
  (address | uint32 count | uint64 global sequence) with a cached index of the lowest entry. Updating an
  existing member or rejecting a newcomer is O(1); the minimum is rescanned (<= 66 SLOADs) only when it can
  change. A newcomer displaces the minimum only with a strictly greater count. Ties: the global sequence
  number of each entry's last increase — earlier reach ranks higher (exact even within a block). Past boards
  are frozen because `paint` only writes the current epoch. Measured worst case: 100 distinct-slot pixels with
  a full board < 3.5M gas.

## Website reads
`getPixels(startSlot, slotCount)` (max 1024 slots = 32768 bytes per call; 8192 slots total, so 8 calls
for the full canvas), `pixelAt(id)`, `getBoard(epoch)` (sorted desc, ties earlier-first),
`isWhitelisted(epoch, account)`, `epochStart/epochEnd/epochEnded`, `pixelsPaintedIn(epoch, painter)`,
`balanceOf`, `totalPixelsPainted`, `totalBurned`, `totalDeposited`, constants `PRICE() WIDTH HEIGHT
PALETTE_SIZE MAX_BATCH BOARD_SIZE MIN_PIXELS EPOCH_LENGTH EPOCH_START imd BURN_ADDRESS MAX_READ_SLOTS`.
Events: `Deposited(user, amount)`, `Withdrawn(user, amount)`,
`Painted(painter indexed, epoch indexed, ids, colors, burned)`. ABI: `out/PixelFun.sol/PixelFun.json` after `forge build`.

## Chosen values / assumptions
- `MAX_READ_SLOTS = 1024` (sane RPC response size).
- Per-epoch count is `uint32` (brief); exceeding 4.29e9 pixels per painter per epoch reverts (would cost >21M IMD).
- `MIN_PIXELS = 0` would be accepted and simply let any painter enter.
- Timestamps can be nudged slightly by the sequencer near epoch boundaries.

## Open items / responsibilities
- Independent adversarial audit before release (tests are not an audit); audit link to be supplied by the review step.
- Explorer verification and final address/launch number come from IMD's launch, not this job.
- NFT mint for whitelisted painters is out of scope.

## Build / test
`forge build && forge test && forge fmt --check` (solc 0.8.26, dependencies vendored in `lib/`).
