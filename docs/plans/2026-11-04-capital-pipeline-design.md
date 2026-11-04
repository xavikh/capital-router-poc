# Capital Pipeline: Design

Date: 2026-11-04
Status: v1 implemented (steps). v2 validated (flows, balance checks, Merkle claims), implementation in progress on `feat/flow-stages`.
Reference implementation: `../capital-router`

## Goal

A successor to capital-router with one composable shape for every capital flow: a budget, then a chain of stages (action → splitter), where each stage passes what it produced to the next. Every action exposes preconditions and postconditions; managers can tune parameters after install.

Target flows:
- **Swap and split:** an OpenFill-style Dutch auction sells token A for B, then splits the B (e.g. 95% to a burn address, 5% fee).
- **Chains:** swap, keep part of the output, and feed it to the next stage (burn, pay out, swap again).
- **Merkle claims:** accounts claim cumulative amounts from a Merkle root, optionally swapped before they're paid.

## Decisions

| Topic | Decision |
|---|---|
| Entrypoint | One `trigger(bytes[] data)`, one entry per stage. No dispatch/request split. |
| Flow shape | One flow per plugin: budget → stages (action → splitter) → budget commit at the end. |
| Execution | One `dao.execute` per stage, each planned right before it runs. |
| Safety | After every stage the plugin checks balances (recipients, outputs, inputs). |
| Chaining | Each stage's leftover (output minus transfers) is the next stage's input. |
| Claims | Merkle only: cumulative leaves, a claim action selects the claimant's amount. |
| Epochs, gauges, quota budgets | Removed. |
| Budget | `FundedStreamBudget` for streams, `BalanceBudget` for "whatever the DAO holds". |
| Swap pricing | AuctionFill terms (flat demand + minimum price) inside `OpenFillAction`. |
| Manager power | Free within installed flows (one `MANAGER_PERMISSION_ID`); installing flows is DAO-only. |
| Pause and reentrancy | OpenZeppelin `PausableUpgradeable` and `ReentrancyGuardUpgradeable`. |
| Failsafe | Independent flows live in separate plugins; `TriggerBatch` runs several with per-plugin "allowed to fail". |
| Assets | ERC20 only. Native ETH unsupported. |

## Architecture

### Flow

```
Flow (one per plugin)
  budget                      read once at the start: what the flow may spend
  stage 0: action → splitter  action: preconditions → build → postconditions
  stage 1: action → splitter  input = what stage 0 produced and didn't transfer out
  ...
  budget commit               once, after the last stage that ran
```

- A stage may have only an action (e.g. burn) or only a splitter (pay out its input). Not neither.
- An allocation to the DAO itself is kept for the next stage instead of transferred.
- A stage whose action returns `inAmount == 0` is skipped, and so are the stages after it. If stage 0 is skipped, the budget isn't committed.

### Interfaces

```solidity
struct Plan { IERC20 inToken; uint256 inAmount; IERC20 outToken; uint256 outAmount; address beneficiary; }
struct Allocation { address recipient; uint256 amount; }
struct Stage { IStageAction action; ISplitter splitter; }

interface IBudget {
    function token() external view returns (IERC20);
    function available() external view returns (uint256);
    function commitActions(Plan calldata firstStage) external view returns (Action[] memory);
}

interface IStageAction {
    /// The budget this action is bound to (only valid as stage 0 of that budget), or address(0)
    function budget() external view returns (IBudget);
    function preconditions(address caller, Plan calldata draft) external view;   // revert = blocked
    function build(address caller, bytes calldata data, Plan calldata draft)
        external view returns (Plan memory plan, Action[] memory actions);
    function postconditions(address caller, Plan calldata plan) external view returns (Action[] memory);
}

interface ISplitter {
    function split(Plan calldata plan) external view returns (Allocation[] memory);  // of plan.outAmount
}
```

### Running a flow

```
trigger(bytes[] data)                          nonReentrant, whenNotPaused, auth(TRIGGER)
  input = { budget.token(), budget.available() }
  for each stage k while input > 0:
    plan  = action ? action.build(caller, data[k], draft) : draft      (preconditions first)
    if plan.inAmount == 0 → stop (skip k and the rest)
    check: same input token, inAmount ≤ input, beneficiary not changed
    acts  = build + action.postconditions + transfers(splitter.split(plan))   (DAO allocations kept)
    reject any act targeting the DAO
    snapshot balances → dao.execute(acts) → verify balances
    input = { plan.outToken, plan.outAmount − transferred, plan.beneficiary }
  if stage 0 ran → dao.execute(budget.commitActions(stage 0 plan))
```

### Balance checks (after every stage)

1. Every recipient received its allocations, summed per recipient (closes capital-router's hole where a recipient listed twice could miss a silent failure).
2. The DAO's output-token balance rose by at least `outAmount − transferred`.
3. The DAO's input-token balance fell by no more than `inAmount`.

When input and output are the same token, 2 and 3 combine into one check. Together they make every stage's plan a verified fact, so the leftover a next stage spends is always real and never the treasury's other holdings.

### Example flows

```
Swap and split                                  Swap, keep 95%, pay it on
budget:  FundedStreamBudget(A)                  budget:  FundedStreamBudget(A)
stage 0: OpenFillAction → Ratio{burn 95, fee 5} stage 0: OpenFillAction → Ratio{fee 5, DAO 95}
commit:  writeCheckpoint                        stage 1: (none) → Ratio{alice 100}
                                                commit:  writeCheckpoint

Merkle claim                                    Merkle claim, then swap
budget:  BalanceBudget(A)                       budget:  BalanceBudget(A)
stage 0: MerkleClaimAction → PayBeneficiary     stage 0: MerkleClaimAction → (none)
                                                stage 1: swap action (A→B) → PayBeneficiary
```

## Rules

1. **Preconditions and postconditions belong to the action interface.** The plugin calls all three hooks on every stage with an action, so an action's checks can't be left out by wiring.
2. **The budget is read once and committed once, at the end.** `FundedStreamBudget.writeCheckpoint()` must see the balance after every stage; committing earlier would let a later deposit release hidden growth.
3. **Planning is view-only.** Every state change is a DAO action. Each stage is planned right before its own `execute`, so it sees real balances.
4. **Actions declare their output at plan time.** Splitters divide the declared output before anything executes. Swap surplus above the declared minimum stays in the DAO.
5. **A beneficiary, once set, can't change.** Later actions may leave it unset; a different one reverts.
6. **Bound actions are stage 0 only.** `OpenFillAction` (restarts its auction) and `MerkleClaimAction` (selects from its budget) must be the first stage of a flow on their own budget.
7. **A parameter change never alters what has already accrued.** Stream setters sync first; price setters restart the auction.

## Components

### `CapitalPipelinePlugin` (PluginCloneable, PausableUpgradeable, ReentrancyGuardUpgradeable)

- Storage: `IBudget budget`, `Stage[] stages`.
- `trigger(bytes[] data)`: `auth(TRIGGER_PERMISSION_ID)` (granted to `ANY_ADDR`), `nonReentrant`, `whenNotPaused`.
- `setFlow(budget, stages)`: `auth(CONFIGURE_PERMISSION_ID)`, DAO only: an action can return arbitrary DAO actions. Rejects no budget, no stages, empty stages, and bound actions outside stage 0 of their budget.
- `pause()`, `unpause()`: `auth(MANAGER_PERMISSION_ID)`.

### `FundedStreamBudget`

Streaming pot that never jumps: `min(baseAmount + rate × elapsed, lastSeenBalance, daoBalance, maxBudget)`. Setters sync first. `commitActions` returns `writeCheckpoint()`.

### `BalanceBudget`

The DAO's whole balance of a token; commits nothing. For flows where something else decides the amount (Merkle claims).

### `OpenFillAction`

Dutch-auction swap bound to its stream budget: offers `min(input, maxOffered())`, demands `demandPerFill`, calls the filler back (`IFiller.fillOffer`), postcondition `assertReceived`. Price setters restart the auction. Carries the beneficiary on.

### `MerkleClaimAction`

Cumulative Merkle distribution bound to its budget. Leaves: OpenZeppelin `StandardMerkleTree` format of `(account, cumulative)`. Stage data: `(account, cumulative, proof, beneficiary)`.

- Outputs only `cumulative − claimed[account]` and sets it as the flow's beneficiary, so later stages can swap it.
- `beneficiary == 0` means the account. A different beneficiary requires `caller == account`; relayers can claim, but only to the account. The DAO can't be the beneficiary.
- The claim record is written by the DAO inside the stage (`recordClaim`), so it rolls back with the flow.
- `setRoot`: `auth(MANAGER_PERMISSION_ID)`. Whoever holds it can direct payouts up to the budget's balance.

### Splitters

- `RatioSplitter`: fixed ratios, remainder to the largest share. A ratio to the DAO keeps that share for the next stage.
- `PayBeneficiary`: 100% of the output to `plan.beneficiary`; stateless, one deployment serves all plugins.

### `TriggerBatch` (periphery)

Calls `trigger` on several plugins (any DAOs) in one transaction; a plugin marked allowed-to-fail is skipped with an event.

### `CapitalPipelinePluginSetup`

Installs the swap-and-split flow (`FundedStreamBudget` → `OpenFillAction` → `RatioSplitter`) with:

| Permission | Where | Who |
|---|---|---|
| `EXECUTE_PERMISSION_ID` | DAO | plugin |
| `TRIGGER_PERMISSION_ID` | plugin | `ANY_ADDR` |
| `CONFIGURE_PERMISSION_ID` | plugin | DAO |
| `MANAGER_PERMISSION_ID` | plugin, budget, action, splitter | manager |
| `CHECKPOINT_PERMISSION_ID` | budget | DAO, swap action |

## Failure handling

- Any revert in any component, hook or balance check reverts the whole `trigger`.
- Paused plugin: `Pausable: paused`. Re-entry: `ReentrancyGuard: reentrant call`.
- Plugin errors: `DataLengthMismatch`, `InputTokenMismatch`, `InAmountExceedsInput`, `BeneficiaryChanged`, `AllocationExceedsOutput`, `InvalidOutToken`, `ActionTargetsDao`, `UnexpectedBalance(stage, account, token, expected, actual)`.

## Constraints and known limits

- No fee-on-transfer or rebasing tokens, and no recipients that forward tokens on receipt: the balance checks reject them.
- One beneficiary per trigger. Batch Merkle claims by calling `trigger` several times in one transaction.
- Claim + swap runs one swap per claim; the claimant gets the swap's declared minimum.
- `FundedStreamBudget` freezes after deposits until someone calls `sync()`.
- Manager power is spend power within installed flows (prices, splits, Merkle roots).
- 256 actions per `execute`, per stage.
- Burn is a transfer to `0x…dEaD`: `totalSupply` doesn't drop.

## Testing (Foundry)

- **Plugin:** configuration rules, swap-and-split, chaining (kept share, unsplit output, skipped stages, commit after the last stage), every guard, and the balance checks (lying action, overspending action, silent transfer failure, repeated recipient). The balance-check tests fail when the checks are removed.
- **Components:** budgets, splitters, OpenFill, Merkle claims (claim, relayer, redirect, new round, insolvency, claim then swap), TriggerBatch.
- **Invariant:** across random fills, deposits, syncs and tweaks, the DAO's pre-existing B is never spent and proceeds are split exactly.

## Out of scope

- Native ETH.
- A real `burn()` action (burn address works today).
- Uniswap / oracle-priced swap actions (the coverage POC has working versions).
- Gasless redirected claims (would need a signature from the account).
- A setup preset for Merkle flows.
