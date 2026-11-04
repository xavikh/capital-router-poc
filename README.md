# Capital Pipeline

Aragon OSx plugin that runs one treasury flow per install: a **budget** feeding a **tree of
actions**. Every node passes its output to its children, split by fixed weights when there are
several, and every branch ends in a leaf that consumes what it receives (transfer, burn, keep).
Each node runs in its own `dao.execute`, followed by balance checks, so a node can only ever spend
what the budget released or what its parent really produced.

```
budget  FundedStreamBudget(A)
└─ OpenFill (A → B)
   ├─ 95% → Burn
   └─  5% → Transfer(feeAddr)
```

Examples: sell token A in a Dutch auction and burn 95% of the proceeds, paying 5% as a fee; let
accounts claim cumulative Merkle allocations, optionally swapped before they're paid; pay a
payroll from a stream. Any ERC20 works, and native ETH as `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`.

Design: [`docs/plans/2026-11-04-capital-pipeline-design.md`](docs/plans/2026-11-04-capital-pipeline-design.md)

## Layout

| Path | What |
|---|---|
| `src/CapitalPipelinePlugin.sol` | Runs the tree, checks balances after every node |
| `src/budgets/FundedStreamBudget.sol` | Streaming pot that never jumps |
| `src/budgets/BalanceBudget.sol` | The DAO's whole balance of a token |
| `src/actions/OpenFillAction.sol` | Open-fill swap with Dutch-auction pricing (root only) |
| `src/actions/MerkleClaimAction.sol` | Cumulative Merkle claims with a redirectable beneficiary (root only) |
| `src/actions/TransferAction.sol` | Leaf: sends its input to a fixed recipient |
| `src/actions/TransferToBeneficiaryAction.sol` | Leaf: sends its input to the flow's beneficiary |
| `src/actions/SplitTransferAction.sol` | Leaf: pays a dynamic list of recipients from a splitter |
| `src/actions/BurnAction.sol` | Leaf: burns its input |
| `src/actions/KeepAction.sol` | Leaf: leaves its input in the DAO |
| `src/splitters/RatioSplitter.sol` | Fixed-ratio recipient list for `SplitTransferAction` |
| `src/setup/CapitalPipelinePluginSetup.sol` | Installs the swap-and-split flow |

## Permissions

| Permission | Holder | Allows |
|---|---|---|
| `TRIGGER_PERMISSION_ID` | anyone | `trigger()` |
| `CONFIGURE_PERMISSION_ID` | DAO only | `setFlow()` |
| `MANAGER_PERMISSION_ID` | manager | parameter setters, Merkle `setRoot()`, `pause()`, `unpause()` |
| `CHECKPOINT_PERMISSION_ID` | DAO, swap action | restarting the stream budget |
| `RECORD_CLAIM_PERMISSION_ID` | DAO | Merkle `recordClaim()`, run by the plugin through the DAO |

## Develop

```shell
git submodule update --init --recursive
forge build
forge test
```

Never set `via_ir = true`; fix stack-too-deep errors by restructuring the code.
