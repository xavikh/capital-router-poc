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
| `src/actions/base/LeafAction.sol` | Base for leaves: spends the whole input, outputs nothing |
| `src/actions/TransferAction.sol` | Leaf: sends its input to a fixed recipient |
| `src/actions/TransferToBeneficiaryAction.sol` | Leaf: sends its input to the flow's beneficiary |
| `src/actions/BurnAction.sol` | Leaf: burns its input |
| `src/actions/KeepAction.sol` | Leaf: leaves its input in the DAO |
| `src/registry/ComponentRegistry.sol` | Write-once ids for the implementations recipes can clone |
| `src/setup/CapitalPipelinePluginSetup.sol` | Installs any flow from a recipe |
| `script/Recipes.sol` | Recipes for buy and burn, buyback with a fee, Merkle claim and payroll |
| `script/Deploy.s.sol` | Deploys every implementation, the registry and the setup |
| `metadata/components/` | One JSON per component: name, description, `initialize` inputs |
| `metadata/uris.json` | The IPFS link of each metadata file, read by the deploy script |

## Permissions

| Permission | Holder | Allows |
|---|---|---|
| `TRIGGER_PERMISSION_ID` | anyone | `trigger()` |
| `CONFIGURE_PERMISSION_ID` | DAO only | `setFlow()` |
| `MANAGER_PERMISSION_ID` | manager | parameter setters, Merkle `setRoot()`, `pause()`, `unpause()` |
| `CHECKPOINT_PERMISSION_ID` | DAO, swap action | restarting the stream budget |
| `RECORD_CLAIM_PERMISSION_ID` | DAO | Merkle `recordClaim()`, run by the plugin through the DAO |
| `REGISTER_PERMISSION_ID` | picked by the managing DAO | registering new components |

The setup always grants `EXECUTE` and `CONFIGURE`; a recipe lists the rest.

## Develop

```shell
git submodule update --init --recursive
forge build
forge test
```

Never set `via_ir = true`; fix stack-too-deep errors by restructuring the code.

## Deploy

1. Upload each file in `metadata/components/` to IPFS (any pinning service).
2. Put its `ipfs://...` link under the component's name in `metadata/uris.json`. The script refuses
   to deploy while a link is empty, because registry entries can't be changed later.
3. Run:

```shell
MANAGING_DAO=0x... forge script script/Deploy.s.sol --rpc-url <rpc> --broadcast
```

Then install a flow by calling `prepareInstallation` with a recipe from `script/Recipes.sol`.
Every component is a fresh clone bound to the installing DAO.
