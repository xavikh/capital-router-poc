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
///         `MANAGING_DAO` maintains the registry. `metadata/uris.json` holds each component's
///         metadata link: upload `metadata/components/*.json` to IPFS and fill it in first.
/// @dev Run: `forge script script/Deploy.s.sol --rpc-url <rpc> --broadcast` with `MANAGING_DAO` set
contract Deploy is Script {
    /// @notice Thrown when a component has no metadata link. Registry entries are write-once,
    ///         so a component is never registered without one.
    error MissingMetadata(string component);

    function run() external returns (ComponentRegistry registry, CapitalPipelinePluginSetup setup) {
        IDAO _managingDao = IDAO(vm.envAddress("MANAGING_DAO"));
        string memory _uris = vm.readFile("metadata/uris.json");

        vm.startBroadcast();
        (registry, setup) = deploy(_managingDao, _uris);
        vm.stopBroadcast();
    }

    /// @param _uris JSON object mapping each component name to its metadata link (`ipfs://...`)
    function deploy(IDAO _managingDao, string memory _uris)
        public
        returns (ComponentRegistry registry, CapitalPipelinePluginSetup setup)
    {
        ComponentRegistry.Registration[] memory _components = new ComponentRegistry.Registration[](8);
        _components[0] =
            _registration(Recipes.FUNDED_STREAM_BUDGET, "FundedStreamBudget", address(new FundedStreamBudget()), _uris);
        _components[1] = _registration(Recipes.BALANCE_BUDGET, "BalanceBudget", address(new BalanceBudget()), _uris);
        _components[2] = _registration(Recipes.OPEN_FILL, "OpenFillAction", address(new OpenFillAction()), _uris);
        _components[3] =
            _registration(Recipes.MERKLE_CLAIM, "MerkleClaimAction", address(new MerkleClaimAction()), _uris);
        _components[4] = _registration(Recipes.TRANSFER, "TransferAction", address(new TransferAction()), _uris);
        _components[5] = _registration(
            Recipes.TRANSFER_TO_BENEFICIARY,
            "TransferToBeneficiaryAction",
            address(new TransferToBeneficiaryAction()),
            _uris
        );
        _components[6] = _registration(Recipes.BURN, "BurnAction", address(new BurnAction()), _uris);
        _components[7] = _registration(Recipes.KEEP, "KeepAction", address(new KeepAction()), _uris);

        registry = new ComponentRegistry(_managingDao, _components);
        setup = new CapitalPipelinePluginSetup(registry);
    }

    function _registration(bytes32 _id, string memory _name, address _implementation, string memory _uris)
        internal
        pure
        returns (ComponentRegistry.Registration memory)
    {
        bytes memory _metadata = bytes(vm.parseJsonString(_uris, string.concat(".", _name)));
        if (_metadata.length == 0) revert MissingMetadata(_name);
        return ComponentRegistry.Registration(_id, _implementation, _metadata);
    }
}
