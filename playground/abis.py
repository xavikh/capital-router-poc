"""Collects the ABIs the playground UI needs from forge's out/ into playground/abis.json."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONTRACTS = {
    "plugin": "CapitalPipelinePlugin.sol/CapitalPipelinePlugin.json",
    "setup": "CapitalPipelinePluginSetup.sol/CapitalPipelinePluginSetup.json",
    "registry": "ComponentRegistry.sol/ComponentRegistry.json",
    "psp": "PluginSetupProcessor.sol/PluginSetupProcessor.json",
    "dao": "DAO.sol/DAO.json",
    "token": "ERC20Mock.sol/ERC20Mock.json",
    "filler": "PlaygroundFiller.sol/PlaygroundFiller.json",
    "FundedStreamBudget": "FundedStreamBudget.sol/FundedStreamBudget.json",
    "BalanceBudget": "BalanceBudget.sol/BalanceBudget.json",
    "OpenFillAction": "OpenFillAction.sol/OpenFillAction.json",
    "MerkleClaimAction": "MerkleClaimAction.sol/MerkleClaimAction.json",
    "TransferAction": "TransferAction.sol/TransferAction.json",
    "TransferToBeneficiaryAction": "TransferToBeneficiaryAction.sol/TransferToBeneficiaryAction.json",
    "BurnAction": "BurnAction.sol/BurnAction.json",
    "KeepAction": "KeepAction.sol/KeepAction.json",
}

abis = {name: json.loads((ROOT / "out" / path).read_text())["abi"] for name, path in CONTRACTS.items()}
(ROOT / "playground" / "abis.json").write_text(json.dumps(abis))
print(f"wrote playground/abis.json ({len(abis)} contracts)")
