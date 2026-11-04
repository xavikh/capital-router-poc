# Capital Pipeline

Aragon OSx plugin that runs one treasury flow per install: a **budget**, then a chain of
**stages** (action → splitter), where each stage passes what it produced and didn't transfer out
to the next one. After every stage the plugin checks balances, so a stage can only ever spend what
the budget released or what the previous stage really produced.

```
budget → [action → splitter] → [action → splitter] → … → budget commit
```

Examples: sell token A in a Dutch auction and split the proceeds 95% burn / 5% fee; swap, keep
part of the output and pay it on; let accounts claim cumulative Merkle allocations, optionally
swapped before they're paid.

Design: [`docs/plans/2026-11-04-capital-pipeline-design.md`](docs/plans/2026-11-04-capital-pipeline-design.md)

## Layout

| Path | What |
|---|---|
| `src/CapitalPipelinePlugin.sol` | Runs the flow, checks balances after every stage |
| `src/budgets/FundedStreamBudget.sol` | Streaming pot that never jumps |
| `src/budgets/BalanceBudget.sol` | The DAO's whole balance of a token |
| `src/actions/OpenFillAction.sol` | Open-fill swap with Dutch-auction pricing |
| `src/actions/MerkleClaimAction.sol` | Cumulative Merkle claims with a redirectable beneficiary |
| `src/splitters/RatioSplitter.sol` | Fixed-ratio split; a share to the DAO carries to the next stage |
| `src/splitters/PayBeneficiary.sol` | Pays a stage's output to the flow's beneficiary |
| `src/periphery/TriggerBatch.sol` | Triggers several plugins in one transaction, with allowed failures |
| `src/setup/CapitalPipelinePluginSetup.sol` | Installs the swap-and-split flow |

## Permissions

| Permission | Holder | Allows |
|---|---|---|
| `TRIGGER_PERMISSION_ID` | anyone | `trigger()` |
| `CONFIGURE_PERMISSION_ID` | DAO only | `setFlow()` |
| `MANAGER_PERMISSION_ID` | manager | parameter setters, Merkle `setRoot()`, `pause()`, `unpause()` |
| `CHECKPOINT_PERMISSION_ID` | DAO, swap action | restarting the stream budget |

## Develop

```shell
git submodule update --init --recursive
forge build
forge test
```

Never set `via_ir = true`; fix stack-too-deep errors by restructuring the code.
