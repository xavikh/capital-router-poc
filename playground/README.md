# Playground

A local fork of Sepolia with the whole system deployed, and a page to build, install and run
recipes on it.

```shell
playground/up.sh
```

Then open http://127.0.0.1:5173/playground/. The script:

1. Starts `anvil --fork-url <Sepolia RPC> --hardfork prague`, unless something already listens on
   port 8545. Set `FORK_URL` to use another RPC.
2. Deploys the playground with `script/playground/Playground.s.sol`, unless it's already on the fork:
   - a DAO that Anvil's first account controls directly (it holds ROOT and EXECUTE),
   - two test tokens, A (1,000,000 held by the DAO) and B (burnable, held by the filler),
   - a filler that takes any flow's open-fill offer and pays from its own B,
   - every component, the registry and the setup, published to Aragon's v1.4 plugin repo factory.
3. Writes the addresses to `playground/deployment.json` and the ABIs to `playground/abis.json`.
4. Serves the repo root on port 5173.

Stopping the script stops the Anvil it started, and the fork's state goes with it.

## The page

| Section | What you can do |
|---|---|
| Status | See the block time and balances; advance time by an hour, a day or a week |
| Create a recipe | Start from a recipe in `script/Recipes.sol` or from scratch; edit components, the tree and permissions; save recipes in this browser; install into the DAO |
| Installed flows | See every flow's budget and tree; fill, trigger or claim |
| Components | Every registered component, with its `initialize` inputs |

Installing runs the real Aragon path: `PluginSetupProcessor.prepareInstallation`, then the DAO
executes the proposal's three actions (grant ROOT, `applyInstallation`, revoke ROOT). The Merkle
recipe uses a one-leaf tree for the first Anvil account, so claims need no proof.

The page loads viem from esm.sh, so the browser needs internet access.
