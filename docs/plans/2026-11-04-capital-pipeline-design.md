# Capital Pipeline: Design

Date: 2026-11-04 (updated 2026-11-05)
Status: v1 (steps), v2 (stages) and v3 (trees) implemented. Recipe installation with a component registry validated, implementation in progress on `feat/flow-stages`.
Reference implementation: `../capital-router`

## Goal

One composable shape for every treasury flow: a budget feeding a tree of explicit actions. Each action can split its output into branches by fixed weights, and every branch ends in a leaf that consumes what it receives (transfer, burn, keep). Every action exposes preconditions and postconditions; managers tune parameters after install; the DAO owns the shape of the tree.

## Decisions

| Topic | Decision |
|---|---|
| Entrypoint | One `trigger(bytes[] data)`, one data entry per node. |
| Flow shape | One flow per plugin: a budget and a tree of nodes, committed once at the end. |
| Execution | Each node with an action runs in its own `dao.execute`, planned right after its parent ran. |
| Success | Every node must succeed. Anything else reverts the whole trigger. |
| Branches | Fixed weights stored in the tree. The DAO changes them with `setFlow`. |
| Leaves | Explicit actions: `Transfer`, `TransferToBeneficiary`, `SplitTransfer`, `Burn`, `Keep`. |
| Claims | Merkle only, cumulative leaves, one claim per trigger, only the account itself can claim. |
| Budgets | `FundedStreamBudget` for streams, `BalanceBudget` for "whatever the DAO holds". |
| Swap pricing | AuctionFill terms (flat demand + minimum price) inside `OpenFillAction`. |
| Manager power | Free within installed flows (one `MANAGER_PERMISSION_ID`); the tree itself is DAO-only. |
| Pause and reentrancy | OpenZeppelin `PausableUpgradeable` and `ReentrancyGuardUpgradeable`. |
| Assets | ERC20 and native ETH, written `NATIVE` = `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`. `address(0)` is never a valid token. |
| Independent flows | Separate plugins, triggered separately. |
| Installation | One setup installs any tree from a recipe. Implementations come from a write-once `ComponentRegistry`. |
| Components | Every component is a clone bound to one DAO; implementations are locked and never used directly. |

## Architecture

### Example tree

```
budget  FundedStreamBudget(A)             10 A released this epoch
└─ OpenFill (A → B)                       root: bound to the budget; a filler pays 1,000 B
   ├─ 95% → Burn                          leaf: burns 950 B
   └─  5% → Transfer(feeAddr)             leaf: sends 50 B; postcondition checks it arrived
commit  writeCheckpoint                   once, after the whole tree
```

### Interfaces

```solidity
struct Plan { IERC20 inToken; uint256 inAmount; IERC20 outToken; uint256 outAmount; address beneficiary; }
struct Node { INodeAction action; uint32[] children; uint32[] weights; }
struct Allocation { address recipient; uint256 amount; }

interface IBudget {
    function token() external view returns (IERC20);
    function available() external view returns (uint256);
    function commitActions(Plan calldata root) external view returns (Action[] memory);  // once, at the end
}

interface INodeAction {
    function budget() external view returns (IBudget);   // bound budget (root only), or address(0)
    function preconditions(address caller, Plan calldata draft) external view;   // revert = blocked
    function build(address caller, bytes calldata data, Plan calldata draft)
        external view returns (Plan memory plan, Action[] memory actions);
    function postconditions(address caller, Plan calldata plan) external view returns (Action[] memory);
}

interface ISplitter {   // used by SplitTransferAction for dynamic recipient lists
    function split(uint256 amount) external view returns (Allocation[] memory);
}
```

### The tree

- Node 0 is the root and receives the budget. Children always have a higher index than their parent and exactly one parent, so the nodes form a tree with no cycles.
- A node with 2+ children is a branch: its output is split by `weights` (summing to 1,000,000), the rounding remainder going to the largest weight. A branch may have no action, in which case it splits its input unchanged.
- A node with no children is a leaf: its action must output nothing.
- At most 16 nodes.

### Running a trigger

```
trigger(bytes[] data)                                   nonReentrant, whenNotPaused, auth(TRIGGER)
  run(node 0, input = { budget.token(), budget.available() })
  dao.execute(budget.commitActions(root plan))          once, after the whole tree

run(node, input)                                        depth first
  input == 0                     → revert EmptyInput
  no action (branch)             → plan = input
  otherwise
    action.preconditions → action.build → plan
    root: 0 < plan.in ≤ input; others: plan.in == input        else revert
    same input token; leaves output 0; beneficiary not changed  else revert
    acts = build actions + action.postconditions
    reject acts targeting the DAO or the plugin
    snapshot DAO balances → dao.execute(acts) → verify DAO balances
  children get plan.out (split by weights for a branch)
```

### Balance checks (after every node)

The DAO spent no more than the node's `inAmount` and received at least its `outAmount` (combined into one check when input and output are the same token). Recipient checks are the leaf actions' own postconditions (`assertReceived`), measured around their own `dao.execute`, so they never see another node's movements. Together these make each node's declared output a verified fact before its children spend it.

### Example flows

```
Claim paid in another token                  Claim with a 1% fee
budget  BalanceBudget(A)                     budget  BalanceBudget(A)
└─ MerkleClaim (beneficiary)                 └─ MerkleClaim                    alice: 100 A
   └─ Swap (A → B)                              ├─  1% → Transfer(feeAddr)
      └─ TransferToBeneficiary                  └─ 99% → Swap (A → B)
                                                         └─ TransferToBeneficiary

Payroll (one execute)                        Treasury diversification
budget  FundedStreamBudget(USDC)             budget  FundedStreamBudget(ETH)
└─ SplitTransfer(Ratio{alice 50,             └─ OpenFill (ETH → USDC)
     bob 30, carol 20})                         ├─ 70% → Keep
                                                └─ 30% → Transfer(grantsSafe)
```

Rejected shapes: a bound action below the root (`BudgetMismatch`), weights not summing to 100% (`InvalidWeights`), an action-less leaf (`MissingAction`), a leaf that outputs something (`LeafLeftOutput` at trigger), a node that takes part of its input (`NodeIncomplete` at trigger).

## Rules

1. **Preconditions and postconditions belong to the action interface.** The plugin calls all three hooks on every node with an action.
2. **Every node must succeed.** The root takes a non-zero amount, up to the budget; every other node takes exactly its input; leaves output nothing. A trigger with nothing to do reverts.
3. **The budget is read once and committed once, after the whole tree,** so a stream checkpoint sees the final balance.
4. **Planning is view-only.** Every state change is a DAO action; each node is planned right before its own `execute`.
5. **Actions declare their output at plan time.** Branch weights divide the declared output. Swap surplus above the declared minimum stays in the DAO.
6. **A beneficiary, once set, can't change.** Only `MerkleClaimAction` sets one; it flows down every branch.
7. **Bound actions (OpenFill, MerkleClaim) are only allowed at the root.**
8. **No action may target the DAO or the plugin itself**, so no node can grant permissions, upgrade the DAO or reconfigure the flow mid-trigger. `setFlow` is also `nonReentrant`.
9. **A parameter change never alters what has already accrued.** Stream setters sync first; price setters restart the auction.
10. **Every component belongs to the plugin's DAO.** The plugin rejects a budget or action whose `dao()` isn't its own, so an implementation (bound to no DAO) or another DAO's component can never run in a flow. `SplitTransferAction` applies the same rule to its splitter.

## Components

### `CapitalPipelinePlugin` (PluginCloneable, PausableUpgradeable, ReentrancyGuardUpgradeable)

- Storage: `IBudget budget`, `Node[] nodes`.
- `trigger(bytes[] data)`: `auth(TRIGGER_PERMISSION_ID)` (granted to `ANY_ADDR`), `nonReentrant`, `whenNotPaused`.
- `setFlow(budget, nodes)`: `auth(CONFIGURE_PERMISSION_ID)`, DAO only, `nonReentrant`. Validates the tree.
- `pause()`, `unpause()`: `auth(MANAGER_PERMISSION_ID)`.

### Budgets

- `FundedStreamBudget`: streaming pot that never jumps, `min(baseAmount + rate × elapsed, lastSeenBalance, daoBalance, maxBudget)`. Setters sync first. Commits `writeCheckpoint()`.
- `BalanceBudget`: the DAO's whole balance of a token; commits nothing.

### Actions

| Action | Kind | Behaviour |
|---|---|---|
| `OpenFillAction` | root, bound | Dutch-auction swap: offers `min(input, maxOffered())`, demands `demandPerFill`, calls the filler back (`IFiller.fillOffer`, payable). Postcondition `assertReceived`. Price setters restart the auction. ETH on either side. |
| `MerkleClaimAction` | root, bound | Cumulative Merkle claim of `(account, cumulative)` leaves (OpenZeppelin StandardMerkleTree format). Only the account can claim; it may name another beneficiary (not the DAO). Outputs only what's owed. `recordClaim` needs `RECORD_CLAIM_PERMISSION_ID` (granted to the DAO); `setRoot` needs `MANAGER_PERMISSION_ID`. |
| `TransferAction` | leaf | Sends its input to a fixed recipient; postcondition checks receipt. |
| `TransferToBeneficiaryAction` | leaf | Sends its input to the flow's beneficiary. |
| `SplitTransferAction` | leaf | Pays a dynamic list from an `ISplitter`; postcondition checks receipts summed per recipient. Dust stays in the DAO. |
| `BurnAction` | leaf | `ERC20Burnable.burn` of its input. |
| `KeepAction` | leaf | Leaves its input in the DAO. |

### Splitters

- `RatioSplitter`: fixed ratios, remainder to the largest share; recipients tunable by the manager.

### `ComponentRegistry`

One per chain, maintained by a managing DAO.

- Maps ids (`"OpenFillAction@1"`) to an implementation and its metadata. Entries are write-once, so an id always means the same code and a recipe can't change under a vote.
- The first batch is registered at deployment; later entries need `REGISTER_PERMISSION_ID` on the managing DAO.

### `CapitalPipelinePluginSetup`

Installs any flow from a recipe:

```solidity
struct Component { bytes32 id; bytes initData; }   // registry id and its initialize call
struct Grant { address where; address who; bytes32 permissionId; }
struct InstallParams { Component[] components; IBudget budget; Node[] nodes; Grant[] grants; }
```

Recipes name contracts that don't exist yet with placeholders: `DAO_REF`, `PLUGIN_REF` and `ref(i)` for component `i`. The setup:

1. Clones the plugin and every component from its registered implementation.
2. Initializes the components in recipe order, with the placeholders in their init data replaced. A component is listed after the ones its initializer checks.
3. Initializes the plugin with the resolved budget and tree, which the plugin validates as usual.
4. Grants `EXECUTE` and `CONFIGURE` itself, then the recipe's grants. A recipe grant may only target the plugin or the recipe's components, and never `CONFIGURE`.
5. Stores a hash of the recipe's grants. Uninstalling passes them again and revokes exactly those.

| Permission | Where | Who | Granted by |
|---|---|---|---|
| `EXECUTE_PERMISSION_ID` | DAO | plugin | setup, always |
| `CONFIGURE_PERMISSION_ID` | plugin | DAO | setup, always |
| `TRIGGER_PERMISSION_ID` | plugin | `ANY_ADDR`, or a keeper | recipe |
| `MANAGER_PERMISSION_ID` | plugin, components with setters | manager | recipe |
| `CHECKPOINT_PERMISSION_ID` | stream budget | DAO, OpenFill | recipe |
| `RECORD_CLAIM_PERMISSION_ID` | `MerkleClaimAction` | DAO | recipe |
| `REGISTER_PERMISSION_ID` | registry | whoever the managing DAO picks | managing DAO |

`script/Recipes.sol` builds the common flows (swap and split, buyback, Merkle claim, payroll). `script/Deploy.s.sol` deploys every implementation, the registry and the setup.

## Failure handling

- Any revert in any node, hook or balance check reverts the whole `trigger`.
- Paused plugin: `Pausable: paused`. Re-entry: `ReentrancyGuard: reentrant call`.
- Setup errors: `UnknownComponent` (registry), `UnknownReference`, `GrantOutsideInstallation`, `ReservedPermission`, `GrantsMismatch` (uninstall).
- Plugin errors: configuration (`NoBudget`, `ForeignComponent`, `InvalidNodeCount`, `MissingAction`, `InvalidChild`, `UnreachableNode`, `InvalidWeights`, `BudgetMismatch`) and trigger (`DataLengthMismatch`, `EmptyInput`, `InAmountExceedsInput`, `NodeIncomplete`, `InputTokenMismatch`, `LeafLeftOutput`, `InvalidOutToken`, `BeneficiaryChanged`, `ActionTargetsDao`, `ActionTargetsPlugin`, `UnexpectedBalance`).

## Constraints and known limits

- **OpenFill and inflows:** the balance checks see that the demanded token arrived, not who sent it. Don't use OpenFill with a demanded token that can reach the DAO without its involvement (vesting, streams, rewards claimable by anyone): a filler could pay with the DAO's own money.
- No fee-on-transfer or rebasing tokens: the balance and receipt checks reject them.
- An ETH recipient without `receive()` reverts the whole flow.
- A trigger with nothing to do reverts (empty budget, closed gate), so keepers and fillers should simulate first.
- One claim per trigger, by the account itself.
- Manager power is spend power within installed flows (prices, splitter recipients, Merkle roots).
- Gas: one `dao.execute` per action node (a swap-and-split fill is about 565k gas).
- 256 actions per `execute`, per node.
- `FundedStreamBudget` freezes after deposits until someone calls `sync()`.

## Testing (Foundry)

- **Plugin:** tree validation, flows (swap and split, buyback with burn and fee, action-less branches, keep), every-node-must-succeed rules, guards (DAO and plugin targets, reentrancy), balance checks (lying and overspending actions). The balance and whole-input tests fail when those checks are removed.
- **Components:** budgets, splitters, OpenFill, Merkle (account-only, redirect, new rounds, insolvency, empty DAO, claim then swap, claim with a fee branch, claim stays open when a later node can't run), leaf actions (including silent transfer failures and repeated recipients), native ETH.
- **Invariant:** across random fills, deposits, syncs and tweaks, the DAO's pre-existing B is never spent and proceeds are split exactly.
- **Installation:** every recipe installed through the deploy script and run end to end; fresh clones per install; recipe grants applied and revoked exactly; rejected recipes (unregistered id, unknown reference, grants on the DAO or outside contracts, `CONFIGURE`); registry write-once and permissioned. The DAO-binding, grant and registry tests fail when those checks are removed.

## Future work

- Relayed (gasless) claims, with a signature from the account over the beneficiary and every node's data.
- Pulling OpenFill payments from the filler (`transferFrom`) to remove the inflow constraint.
- Publishing the setup to an Aragon plugin repo on each network, with build metadata.
- Registry metadata (names, initializer ABIs) so UIs can show recipes as named fields.
- Uniswap, CowSwap and oracle-priced swap actions (working versions exist in the coverage POC).
