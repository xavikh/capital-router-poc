// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {PluginRepo} from "@aragon/osx/framework/plugin/repo/PluginRepo.sol";
import {PluginRepoFactory} from "@aragon/osx/framework/plugin/repo/PluginRepoFactory.sol";
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

/// @notice Deploys every component implementation, a registry naming them and the plugin setup,
///         then publishes the setup as version 1.1 of a new Aragon plugin repo.
///         `metadata/uris.json` holds the metadata links: upload the files in `metadata/` to IPFS
///         and fill it in first.
/// @dev Run: `forge script script/Deploy.s.sol --rpc-url <rpc> --broadcast` with
///      - `MANAGING_DAO`: maintains the registry, and the plugin repo unless `PLUGIN_REPO_MAINTAINER` is set
///      - `PLUGIN_REPO_FACTORY`: Aragon's `PluginRepoFactory` on that network
///      - `PLUGIN_REPO_SUBDOMAIN` (optional): defaults to `capital-pipeline`
contract Deploy is Script {
    /// @notice Thrown when a metadata link is empty. Registry entries and plugin repo versions
    ///         can't be changed later, so nothing is published without one.
    error MissingMetadata(string key);

    function run() external returns (ComponentRegistry registry, CapitalPipelinePluginSetup setup, PluginRepo repo) {
        IDAO _managingDao = IDAO(vm.envAddress("MANAGING_DAO"));
        PluginRepoFactory _factory = PluginRepoFactory(vm.envAddress("PLUGIN_REPO_FACTORY"));
        string memory _subdomain = vm.envOr("PLUGIN_REPO_SUBDOMAIN", string("capital-pipeline"));
        address _maintainer = vm.envOr("PLUGIN_REPO_MAINTAINER", address(_managingDao));
        string memory _uris = vm.readFile("metadata/uris.json");

        vm.startBroadcast();
        (registry, setup) = deploy(_managingDao, _uris);
        repo = publish(_factory, setup, _subdomain, _maintainer, _uris);
        vm.stopBroadcast();
    }

    /// @param _uris The contents of `metadata/uris.json`
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

    /// @notice Publishes `_setup` as version 1.1 of a new plugin repo, which DAOs install from
    /// @param _subdomain The ENS name under `plugin.dao.eth`, or empty on networks without ENS
    /// @param _uris The contents of `metadata/uris.json`
    function publish(
        PluginRepoFactory _factory,
        CapitalPipelinePluginSetup _setup,
        string memory _subdomain,
        address _maintainer,
        string memory _uris
    ) public returns (PluginRepo) {
        return _factory.createPluginRepoWithFirstVersion(
            _subdomain, address(_setup), _maintainer, _link(_uris, "release"), _link(_uris, "build")
        );
    }

    function _registration(bytes32 _id, string memory _name, address _implementation, string memory _uris)
        internal
        pure
        returns (ComponentRegistry.Registration memory)
    {
        return ComponentRegistry.Registration(_id, _implementation, _link(_uris, string.concat("components.", _name)));
    }

    /// @dev The metadata link at `_key` in `metadata/uris.json`; reverts if it's empty
    function _link(string memory _uris, string memory _key) internal pure returns (bytes memory _uri) {
        _uri = bytes(vm.parseJsonString(_uris, string.concat(".", _key)));
        if (_uri.length == 0) revert MissingMetadata(_key);
    }
}
