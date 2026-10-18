# PixelFun test additions

Run the complete offline suite with the assignment's seed:

```sh
FOUNDRY_FUZZ_SEED=0x26a6691fa493045ed5ade580392dfb5e884203b9f769d57144866c24f069de2d forge test
forge build
```

No new dependencies, RPC, forks, FFI, private keys, environment mutations, or configuration changes are required. The original `PixelFun.t.sol` remains intact.

| File | Coverage |
| --- | --- |
| `PixelFunAccounting.t.sol` | Independent user balances; deposit/paint/full-withdraw conservation; donations; one-unit dust; fee-on-transfer accounting; decimal scaling from 3 to 77; no-return and false-return tokens; transfer reverts; rollback of pixels, counters and boards after failed burns; nine combinations of outer/inner reentrant entry points with exact guard-error checks. |
| `PixelFunCanvasProperties.t.sol` | All palette values; arbitrary packed-slot boundaries; neighbor preservation; duplicate writes against a byte-array model; batch partition equivalence; invalid items at arbitrary positions and atomic rollback; exact funding threshold; full canvas pagination and invalid reads; exact epoch boundaries. |
| `PixelFunBoardProperties.t.sol` | Inclusive MIN_PIXELS gating across batches; full board cutoff ties; chronological tie ordering within one block; cached-minimum updates; eviction and reentry; failed displacements; frozen full boards and empty skipped epochs; 70-painter stateful leaderboard oracle. |
| `PixelFunInvariant.t.sol` | Five-actor randomized deposits, partial/full withdrawals, paintings, donations, rejected overspending, round trips and time progression; independent accounting, real burn balances, last-write canvas state, per-epoch counts and frozen board snapshots; a separate fee-token vault campaign. |
| `helpers/` | Local tokens and bounded handlers, used only by tests. |

Stateless fuzz properties use 1,000 runs each. Each invariant campaign uses 256 runs at depth 96 with `fail-on-revert = true`, configured inline in Solidity. Invalid actions are checked with precise expected reverts; valid actions are allowed to fail the campaign. Selectors explicitly target only intended handler actions. The runner's call-distribution output shows which actions ran. A deterministic handler exercise also pins every action and the transition between epochs.

The vault model tracks gross inputs, net credits, withdrawals, spending, minting, donations and token fees independently of contract accounting. Every invariant campaign ends by withdrawing all outstanding balances. The ordinary-token campaign checks actual dead-address holdings against `5e15 *` the ghost paint count, as well as checking the contract's counters. Donations create surplus, not user credit. Random painting covers 160 positions across the first three and last two slots; the separate fuzz tests cover arbitrary slots across the entire canvas. Time advances monotonically through epochs 0–8, with later calls continuing to operate in epoch 8.

The board model stores scores and the chronological order in which scores were reached for all 70 participants. It does not reproduce the implementation's packed entries, index mapping, insertion sort, or cached minimum. It checks unique membership, all scores, sorted order, tie precedence, whitelist agreement, and that every excluded participant ranks below the last board member. The board starts full, so displacement, rejected competitors and minimum updates are exercised throughout random sequences. This campaign stays within one epoch; the other invariant campaign and deterministic board tests cover epoch transitions and freezing.

## Reported limitation

`.imd-findings.json` reports a medium-severity mismatch between claimed and actual burns when the token takes a recipient-deducted outgoing transfer fee. Its self-contained proof was executed in `test/scratch/` and failed on the expected assertion: `4950000000000000 != 5000000000000000`. The proof is embedded in the finding rather than included as a failing test in the delivered suite. It permits an atomic rejection of the unsupported burn transfer as a safe resolution.

The fee-token invariant campaign exercises deposits, withdrawals, donations and time progression. It does not assert that fee-charging paints satisfy the burn requirement; that path is the reported defect. No claim is made that the production IMD token charges such a fee. Verification of its live transfer behavior, decimals, bridge restrictions and permissionless burn support remains an integration step; these offline mocks do not establish those facts.
