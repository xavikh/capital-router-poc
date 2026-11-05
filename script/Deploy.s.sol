// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {ComponentRegistry} from "../src/registry/ComponentRegistry.sol";
import {CapitalPipelinePluginSetup} from "../src/setup/CapitalPipelinePluginSetup.sol";
import {FundedStreamBudget} from "../src/budgets/FundedStreamBudget.sol";
import {BalanceBudget} from "../src/budgets/BalanceBudget.sol";
import {OpenFillAction} from "../src/actions/OpenFillAction.sol";
import {MerkleClaimAction} from "../src/actions/MerkleClaimAction.sol";
import {TransferAction} from "../src/actions/TransferAction.sol";
import {TransferToBeneficiaryAction} from "../src/actions/TransferToBeneficiaryAction.sol";
import {BurnAction} from "../src/actions/BurnAction.sol";
import {KeepAction} from "../src/actions/KeepAction.sol";
import {Recipes} from "./Recipes.sol";

/// @notice Deploys every component implementation, a registry naming them and the plugin setup.
///         `MANAGING_DAO` maintains the registry.
/// @dev Run: `forge script script/Deploy.s.sol --rpc-url <rpc> --broadcast` with `MANAGING_DAO` set
contract Deploy is Script {
    function run() external returns (ComponentRegistry registry, CapitalPipelinePluginSetup setup) {
        IDAO _managingDao = IDAO(vm.envAddress("MANAGING_DAO"));

        vm.startBroadcast();
        (registry, setup) = deploy(_managingDao);
        vm.stopBroadcast();
    }

    function deploy(IDAO _managingDao) public returns (ComponentRegistry registry, CapitalPipelinePluginSetup setup) {
        ComponentRegistry.Registration[] memory _components = new ComponentRegistry.Registration[](8);
        _components[0] = _registration(Recipes.FUNDED_STREAM_BUDGET, address(new FundedStreamBudget()));
        _components[1] = _registration(Recipes.BALANCE_BUDGET, address(new BalanceBudget()));
        _components[2] = _registration(Recipes.OPEN_FILL, address(new OpenFillAction()));
        _components[3] = _registration(Recipes.MERKLE_CLAIM, address(new MerkleClaimAction()));
        _components[4] = _registration(Recipes.TRANSFER, address(new TransferAction()));
        _components[5] = _registration(Recipes.TRANSFER_TO_BENEFICIARY, address(new TransferToBeneficiaryAction()));
        _components[6] = _registration(Recipes.BURN, address(new BurnAction()));
        _components[7] = _registration(Recipes.KEEP, address(new KeepAction()));

        registry = new ComponentRegistry(_managingDao, _components);
        setup = new CapitalPipelinePluginSetup(registry);
    }

    function _registration(bytes32 _id, address _implementation)
        internal
        pure
        returns (ComponentRegistry.Registration memory)
    {
        return ComponentRegistry.Registration(_id, _implementation, "");
    }
}
