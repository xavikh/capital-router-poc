# Capital Pipeline: Design

Date: 2026-11-04
Status: Validated design, pre-implementation
Reference implementation: `../capital-router`

## Goal

A successor to capital-router where every strategy ("step") has the same structure (budget → action → splitter, with every action exposing preconditions and postconditions), so steps are easy to compose and reason about, and where managers can tune parameters after install.

v1 target flow: an OpenFill-style swap (a filler buys token A from the DAO for token B), then split the B received by ratio: most of it to a burn address, a small part to a fee address.

## Decisions

| Topic | Decision |
|---|---|
| Entrypoint | One `trigger(bytes[] data)`. No dispatch/request split. |
| Epochs, gauges, claims | Removed. Every step drains a pot atomically. |
| Budget | `FundedStreamBudget` (repo root), adapted to the new interface. |
| Swap pricing | AuctionFill terms (flat demand + minimum price), folded into the swap action. OracleFill removed. |
| Manager power | Free. One `MANAGER_PERMISSION_ID`. The DAO can restrict it later with an OSx condition. |
| v1 assets | ERC20 on both sides. Native ETH deferred. |

## Architecture

### Step pipeline

A step has three components. Action and splitter may be empty (`address(0)`); the budget may not.

```
Budget  →  Action                                      →  Splitter
 (in)      preconditions → build → postconditions         (deliver out)
```

- **Budget**: how much of token A the step may spend now.
- **Action**: converts input into output. Its interface has three hooks, all called by the plugin:
  - `preconditions`: reverts if the action must not run.
  - `build`: the actions that do the work.
  - `postconditions`: the checks that make the work safe, appended as DAO actions.

  With no action, output = input (a plain transfer step) and there are no hooks to call.
- **Splitter**: who receives the output. With no splitter, the output stays in the DAO.

The splitter runs on the **output**. This is valid because an action must declare its output amount at plan time (see rules). It also means the DAO only forwards exactly what the step produced, never its existing holdings of the output token.

### Interfaces

```solidity
struct Plan { IERC20 inToken; uint256 inAmount; IERC20 outToken; uint256 outAmount; }
struct Allocation { address recipient; uint256 amount; }

interface IBudget {
    function token() external view returns (IERC20);
    function available() external view returns (uint256);
    function commitActions(Plan calldata plan) external view returns (Action[] memory);
}

interface IStepAction {
    /// The budget this action is bound to, or address(0) if it works with any budget
    function budget() external view returns (IBudget);

    /// Reverts if the action must not run
    function preconditions(address caller, Plan calldata draft) external view;

    /// Caps inAmount, sets outToken/outAmount, returns the actions that do the work
    function build(address caller, bytes calldata data, Plan calldata draft)
        external view returns (Plan memory plan, Action[] memory actions);

    /// The checks that make this action safe, executed by the DAO after the work
    function postconditions(address caller, Plan calldata plan) external view returns (Action[] memory);
}

interface ISplitter {
    function split(uint256 amount) external view returns (Allocation[] memory); // sums to amount
}
```

### Plugin assembly

```
trigger(bytes[] data)                                    // one entry per step, or empty
  nonReentrant, whenNotPaused                            // OpenZeppelin modifiers
  for each step i:
    draft = { A, budget.available(), A, budget.available() }
    action.preconditions(caller, draft)                 // skipped when there is no action
    (plan, acts) = action.build(caller, data[i], draft)  // no action → (draft, [])
    if plan.inAmount == 0 → skip step (no checkpoint)
    acts += action.postconditions(caller, plan)         // skipped when there is no action
    acts += transfers(plan.outToken, splitter.split(plan.outAmount))
    acts += budget.commitActions(plan)
    if any acts[j].to == dao → revert ActionTargetsDao(i, j)
    dao.execute(executionId(i), acts, 0)
    emit StepExecuted(i, caller, plan)
```

`caller` is always the plugin's `msg.sender`, never a value from calldata.

### v1 flow: action list for one fill

```
1. A.approve(filler, in)                          ┐
2. filler.fillOffer(A, in, B, out, data)          ├ action.build
3. A.approve(filler, 0)                           ┘
4. swapAction.assertReceived(B, before + out)     ← action.postconditions
5. B.transfer(0x…dEaD, 95% of out)
6. B.transfer(fee, 5% of out + rounding remainder → largest share)
7. budget.writeCheckpoint()
```

One `dao.execute`: if the filler under-delivers, everything reverts.

## Rules

1. **Preconditions and postconditions are part of the action interface, not of the step.** OpenFill's "DAO received ≥ out" lives in `OpenFillAction.postconditions`, and the plugin calls both hooks on every step with an action, so the check can't be left out by wiring. Budget and splitter stay separate components of the step.
2. **The budget always appends its own commit.** Steps can't leave it out. Without `writeCheckpoint`, a filler could fill again in the same block.
3. **Planning is view-only.** Every state change is a DAO action inside the single `execute`. No `PREPARE_PERMISSION_ID`, no self-call wrapper. Previews are a plain `eth_call`.
4. **Actions declare their output at plan time.** OpenFill: the demand. No action: output = input. Actions whose output is only known after execution (CowSwap) cannot be combined with a splitter.
5. **A parameter change never alters what has already accrued.** Each setter settles under the old values before switching (see manager setters).

## Components (v1)

### `CapitalPipelinePlugin` (PluginCloneable, PausableUpgradeable, ReentrancyGuardUpgradeable)

- Storage: `Step[] steps` where `Step = { IBudget budget; IStepAction action; ISplitter splitter; }`. Pause state and reentrancy lock come from OpenZeppelin.
- `trigger(bytes[] data)`: `auth(TRIGGER_PERMISSION_ID)` (granted to `ANY_ADDR` at install, so OSx conditions can gate it later), `nonReentrant`, `whenNotPaused`.
- `setSteps(Step[])`: `auth(CONFIGURE_PERMISSION_ID)`, held by the DAO only. An action can return arbitrary DAO actions, so installing a step is equivalent to executing from the treasury and stays a governance decision.
- `pause()`, `unpause()`: `auth(MANAGER_PERMISSION_ID)`. Pausing stops every step; to disable a single step, the DAO removes it with `setSteps`.
- Every assembled action targeting the DAO itself is rejected, so no step can grant permissions, upgrade, or reconfigure the DAO.
- `setSteps` rejects a step whose swap action is bound to a different budget than the step's budget.

### `FundedStreamBudget` (adapted)

Keeps the existing curve: `min(baseAmount + rate × elapsed, lastSeenBalance, vaultBalance, maxBudget)`. Changes:

- Implements `IBudget`. `commitActions` returns `[writeCheckpoint()]`.
- Vault is the DAO (`dao()`); the separate `vault` parameter is dropped, since the DAO must hold the tokens it approves.
- Access moves from `onlyVault` to OSx permissions: `MANAGER_PERMISSION_ID` for setters, `CHECKPOINT_PERMISSION_ID` for `writeCheckpoint` (granted to the DAO and to the step's swap action).
- New setters `setAmountPerEpoch`, `setMaxBudget`, both calling `_sync()` first, like `setEpochInterval` already does.
- One step per instance.

### `OpenFillAction`

- Bound at init to: its budget, the output token B, `demandPerFill`, `minDemandedPerOffered`.
- `preconditions`: none in v1 (no-op).
- `build`: `in = min(draft.inAmount, maxOffered())`, `out = demandPerFill`, returns actions 1–3 above.
- `postconditions`: snapshots the DAO's B balance, returns action 4. A future swap action (e.g. Uniswap) implements the same function.
- `maxOffered() = demandPerFill × 1e18 / minDemandedPerOffered` (same scaling and init checks as capital-router's `AuctionFillPolicy`).
- `assertReceived(B, minBalance)`: view, reverts if the DAO holds less.
- Setters `setDemandPerFill`, `setMinDemandedPerOffered`: `auth(MANAGER_PERMISSION_ID)`, then call `budget.writeCheckpoint()` to restart the auction. Without the restart, lowering the demand or the minimum price lets a filler take the accumulated offer at the new price in the same block.
- Rejects A == B at init.

### `RatioSplitter`

- Recipients and ratios summing to `RATIO_BASE`.
- Rounding remainder goes to the largest share, so allocations sum to exactly `amount`.
- `setRecipients(address[], uint32[])`: `auth(MANAGER_PERMISSION_ID)`. No settling needed: a sweep keeps no memory between triggers.

### `CapitalPipelinePluginSetup`

Deploys the plugin and components as clones and grants:

| Permission | Where | Who |
|---|---|---|
| `EXECUTE_PERMISSION_ID` | DAO | plugin |
| `TRIGGER_PERMISSION_ID` | plugin | `ANY_ADDR` |
| `CONFIGURE_PERMISSION_ID` | plugin | DAO |
| `MANAGER_PERMISSION_ID` | plugin, budget, action, splitter | manager (install param) |
| `CHECKPOINT_PERMISSION_ID` | budget | DAO, swap action |

## Failure handling

- Any revert in any component or hook reverts the whole `trigger`. No failsafe map in v1 (one step); add it when multi-step flows exist.
- Paused plugin: `trigger` reverts with `Pausable: paused`.
- Empty pot (`plan.inAmount == 0`): the step is skipped without a checkpoint; `trigger` succeeds.
- `data` must be empty or have one entry per step, otherwise revert.
- An assembled action targeting the DAO: `trigger` reverts with `ActionTargetsDao(step, index)`.
- Reentrancy: the filler runs arbitrary code inside `dao.execute` before the checkpoint. The DAO's own guard blocks a nested `execute`; the plugin guard on `trigger` keeps that protection local.

## Constraints and known limits

- Token B must revert on failed transfers (standard OpenZeppelin ERC20). Split transfers are not receipt-checked; a false-returning token would leave B in the DAO instead of burning it.
- No fee-on-transfer or rebasing tokens: `assertReceived` would revert or drift.
- Burn is a transfer to `0x…dEaD`: `totalSupply` does not drop. Matters if B is a governance token with supply-based quorum.
- `FundedStreamBudget` freezes after deposits of A until someone calls `sync()`. Run a keeper or add a `sync()` action wherever revenue enters the DAO.
- Manager power is spend power within the installed steps: a manager can lower the minimum price or redirect the split. Accepted for v1. Installing or removing steps stays with the DAO.
- 256 actions per `execute`: 7 for the v1 flow, so the splitter can hold up to ~250 recipients.

## Testing (Foundry)

1. **Happy path**: mock filler delivers; the DAO's A drops by `in`, `0x…dEaD` and fee receive exactly 95% / 5% of `out`, checkpoint written.
2. **Bad fillers and bad steps**: under-delivery reverts everything (no transfers, no checkpoint); a filler that re-enters `trigger` from `fillOffer` fails; a second fill in the same block gets zero; a step returning an action that targets the DAO reverts with `ActionTargetsDao`; the manager cannot call `setSteps`.
3. **Tweaks don't jump**: after rate or max changes, `available()` is unchanged in the same block; after price-term changes, `available()` is zero.
4. **Splitter fuzz**: allocations sum to exactly `amount` for any amount and valid ratio set.
5. **Invariant**: the DAO's pre-existing B balance never decreases across any sequence of triggers and tweaks.

## Out of scope (add when needed)

- Claim kind (cumulative release + shares + ledger) for per-recipient claims.
- Failsafe map for multi-step plugins.
- Uniswap action (split the guaranteed minimum; surplus stays in the DAO). CowSwap is incompatible with a splitter.
- Native ETH on either side.
- Oracle-based pricing.

## Implementation notes

Details settled while implementing v1:

- `IStepAction.budget()` returns the budget an action is bound to (address(0) if any). `setSteps` uses it to reject a step whose action is bound to a different budget.
- `ICheckpointedBudget` extends `IBudget` with `writeCheckpoint()`. `OpenFillAction` requires one, so its price setters can restart the auction.
- `IFiller.fillOffer` keeps the selector of capital-router's `ISwapSolver.fillOffer`, so existing fillers work unchanged.
- `FundedStreamBudget` drops ERC165, `budgetId` and the `vault` parameter (the vault is `dao()`). Tokens must have code, which also rejects native ETH.
- Pause and the reentrancy lock on `trigger` use OpenZeppelin's `PausableUpgradeable` and `ReentrancyGuardUpgradeable` (4.9.6, the version OSx depends on). OZ's transient `ReentrancyGuardTransient` needs OZ 5.1+, so the lock costs about 1.8k more gas per trigger than a transient one would.
