# Capital Pipeline

Aragon OSx plugin that runs treasury flows as a list of steps. Each step is
**budget → action (preconditions → build → postconditions) → splitter**, executed by the DAO in a
single `execute`. v1 ships one flow: an open-fill Dutch auction that sells token A for token B, then
splits the B received (for example 95% to a burn address, 5% to a fee address).

Design: [`docs/plans/2026-11-04-capital-pipeline-design.md`](docs/plans/2026-11-04-capital-pipeline-design.md)

## Layout

| Path | What |
|---|---|
| `src/CapitalPipelinePlugin.sol` | Runs the steps and enforces the shared guards |
| `src/budgets/FundedStreamBudget.sol` | Streaming pot that never jumps |
| `src/actions/OpenFillAction.sol` | Open-fill swap with Dutch-auction pricing |
| `src/splitters/RatioSplitter.sol` | Fixed-ratio split, remainder to the largest share |
| `src/setup/CapitalPipelinePluginSetup.sol` | Installs the swap-and-split flow |

## Permissions

| Permission | Holder | Allows |
|---|---|---|
| `TRIGGER_PERMISSION_ID` | anyone | `trigger()` |
| `CONFIGURE_PERMISSION_ID` | DAO only | `setSteps()` |
| `MANAGER_PERMISSION_ID` | manager | parameter setters, `setPaused()` |
| `CHECKPOINT_PERMISSION_ID` | DAO, swap action | restarting the budget |

## Develop

```shell
git submodule update --init --recursive
forge build
forge test
```

Never set `via_ir = true`; fix stack-too-deep errors by restructuring the code.
