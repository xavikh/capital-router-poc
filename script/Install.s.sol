// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IPluginSetup} from "@aragon/osx-commons-contracts/src/plugin/setup/IPluginSetup.sol";
import {PermissionManager} from "@aragon/osx/core/permission/PermissionManager.sol";
import {PluginRepo} from "@aragon/osx/framework/plugin/repo/PluginRepo.sol";
import {PluginSetupProcessor} from "@aragon/osx/framework/plugin/setup/PluginSetupProcessor.sol";
import {PluginSetupRef, hashHelpers} from "@aragon/osx/framework/plugin/setup/PluginSetupProcessorHelpers.sol";
import {CapitalPipelinePluginSetup} from "../src/setup/CapitalPipelinePluginSetup.sol";
import {Recipes} from "./Recipes.sol";

/// @notice Prepares the installation of a flow described by a config file, and prints the three
///         actions the DAO's proposal must execute: grant ROOT to Aragon's PluginSetupProcessor,
///         apply the installation, revoke ROOT.
/// @dev Run: `forge script script/Install.s.sol --rpc-url <rpc> --broadcast` with
///      - `INSTALL_CONFIG`: a file in `installs/` (see the examples there)
///      - `PLUGIN_SETUP_PROCESSOR`: Aragon's `PluginSetupProcessor` on that network
///      - `PLUGIN_REPO`: the plugin repo published by `Deploy.s.sol`
///      Preparing is permissionless; nothing is installed until the DAO executes the actions.
contract Install is Script {
    using stdJson for string;

    bytes32 internal constant ROOT_PERMISSION_ID = keccak256("ROOT_PERMISSION");

    /// @notice Thrown when the config names a recipe that doesn't exist
    error UnknownRecipe(string recipe);

    function run() external returns (address plugin, Action[] memory actions) {
        string memory _config = vm.readFile(vm.envString("INSTALL_CONFIG"));
        PluginSetupProcessor _psp = PluginSetupProcessor(vm.envAddress("PLUGIN_SETUP_PROCESSOR"));
        PluginRepo _repo = PluginRepo(vm.envAddress("PLUGIN_REPO"));

        vm.startBroadcast();
        (plugin, actions) = install(_psp, _repo, _config.readAddress(".dao"), _config);
        vm.stopBroadcast();

        console.log("Plugin:", plugin);
        for (uint256 i; i < actions.length; ++i) {
            console.log("Action", i, "to:", actions[i].to);
            console.logBytes(actions[i].data);
        }
    }

    /// @notice Prepares the installation of version 1.1 and returns the proposal's actions
    function install(PluginSetupProcessor _psp, PluginRepo _repo, address _dao, string memory _config)
        public
        returns (address plugin, Action[] memory actions)
    {
        PluginSetupRef memory _ref = PluginSetupRef(PluginRepo.Tag(1, 1), _repo);
        IPluginSetup.PreparedSetupData memory _prepared;
        (plugin, _prepared) = _psp.prepareInstallation(
            _dao, PluginSetupProcessor.PrepareInstallationParams(_ref, abi.encode(recipe(_config)))
        );

        PluginSetupProcessor.ApplyInstallationParams memory _apply = PluginSetupProcessor.ApplyInstallationParams(
            _ref, plugin, _prepared.permissions, hashHelpers(_prepared.helpers)
        );
        actions = new Action[](3);
        actions[0] = Action(_dao, 0, abi.encodeCall(PermissionManager.grant, (_dao, address(_psp), ROOT_PERMISSION_ID)));
        actions[1] = Action(address(_psp), 0, abi.encodeCall(PluginSetupProcessor.applyInstallation, (_dao, _apply)));
        actions[2] =
            Action(_dao, 0, abi.encodeCall(PermissionManager.revoke, (_dao, address(_psp), ROOT_PERMISSION_ID)));
    }

    /// @notice The recipe a config describes: `.recipe` names it, the other keys are its parameters
    function recipe(string memory _config) public pure returns (CapitalPipelinePluginSetup.InstallParams memory) {
        string memory _name = _config.readString(".recipe");
        address _manager = _config.readAddress(".manager");
        bytes32 _hash = keccak256(bytes(_name));

        if (_hash == keccak256("buyAndBurn")) return Recipes.buyAndBurn(_manager, _stream(_config), _swap(_config));
        if (_hash == keccak256("buyback")) {
            return Recipes.buyback(
                _manager,
                _stream(_config),
                _swap(_config),
                _config.readAddress(".fee.recipient"),
                uint32(_config.readUint(".fee.weight"))
            );
        }
        if (_hash == keccak256("merkleClaim")) {
            return Recipes.merkleClaim(_manager, IERC20(_config.readAddress(".token")), _config.readBytes32(".root"));
        }
        if (_hash == keccak256("payroll")) {
            return
                Recipes.payroll(_manager, _stream(_config), _config.readAddressArray(".recipients"), _weights(_config));
        }
        revert UnknownRecipe(_name);
    }

    function _stream(string memory _config) internal pure returns (Recipes.Stream memory) {
        return Recipes.Stream({
            token: IERC20(_config.readAddress(".stream.token")),
            amountPerEpoch: _config.readUint(".stream.amountPerEpoch"),
            maxBudget: _config.readUint(".stream.maxBudget"),
            epochInterval: _config.readUint(".stream.epochInterval")
        });
    }

    function _swap(string memory _config) internal pure returns (Recipes.Swap memory) {
        return Recipes.Swap({
            demandedToken: IERC20(_config.readAddress(".swap.demandedToken")),
            demandPerFill: _config.readUint(".swap.demandPerFill"),
            minDemandedPerOffered: _config.readUint(".swap.minDemandedPerOffered")
        });
    }

    function _weights(string memory _config) internal pure returns (uint32[] memory _out) {
        uint256[] memory _in = _config.readUintArray(".weights");
        _out = new uint32[](_in.length);
        for (uint256 i; i < _in.length; ++i) {
            _out[i] = uint32(_in[i]);
        }
    }
}
