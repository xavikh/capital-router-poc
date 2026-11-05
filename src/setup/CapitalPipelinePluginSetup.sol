// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {PermissionLib} from "@aragon/osx-commons-contracts/src/permission/PermissionLib.sol";
import {IPluginSetup} from "@aragon/osx-commons-contracts/src/plugin/setup/IPluginSetup.sol";
import {PluginSetup} from "@aragon/osx-commons-contracts/src/plugin/setup/PluginSetup.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {CapitalPipelinePlugin} from "../CapitalPipelinePlugin.sol";
import {ComponentRegistry} from "../registry/ComponentRegistry.sol";
import {IBudget} from "../interfaces/IBudget.sol";
import {INodeAction} from "../interfaces/INodeAction.sol";
import {Node} from "../lib/types.sol";
import {CONFIGURE_PERMISSION_ID} from "../lib/constants.sol";
import {DAO_INDEX, PLUGIN_INDEX, isPlaceholder} from "../lib/placeholders.sol";

/// @title CapitalPipelinePluginSetup
/// @notice Installs any flow from a recipe: the components to clone (by registry id), the tree and
///         the permissions. Recipes name contracts that don't exist yet with placeholders
///         (`DAO_REF`, `PLUGIN_REF`, `ref(i)` for component i), which the setup replaces.
/// @dev Every component is a fresh clone of a registered implementation. Clones are created first
///      and initialized in recipe order, so list a component after the ones its initializer
///      checks. The setup always grants EXECUTE (the plugin on the DAO) and CONFIGURE (the DAO on
///      the plugin); recipe grants may only target the plugin or its components, and never CONFIGURE.
contract CapitalPipelinePluginSetup is PluginSetup {
    struct Component {
        bytes32 id;
        bytes initData;
    }

    struct Grant {
        address where;
        address who;
        bytes32 permissionId;
    }

    struct InstallParams {
        Component[] components;
        IBudget budget;
        Node[] nodes;
        Grant[] grants;
    }

    /// @dev The addresses placeholders stand for
    struct Context {
        address dao;
        address plugin;
        address[] components;
    }

    /// @dev EXECUTE_PERMISSION_ID on the OSx DAO
    bytes32 internal constant EXECUTE_PERMISSION_ID = keccak256("EXECUTE_PERMISSION");

    /// @notice Where component implementations come from
    ComponentRegistry public immutable registry;

    /// @notice Hash of each installed plugin's recipe grants, so uninstalling revokes exactly them
    mapping(address plugin => bytes32) public grantsHash;

    error UnknownReference(uint256 index);
    error GrantOutsideInstallation(address where);
    error ReservedPermission(bytes32 permissionId);
    error GrantsMismatch();

    constructor(ComponentRegistry _registry) PluginSetup(address(new CapitalPipelinePlugin())) {
        registry = _registry;
    }

    /// @inheritdoc IPluginSetup
    /// @dev `_data` is `abi.encode(InstallParams)`. Helpers are the components, in recipe order.
    function prepareInstallation(address _dao, bytes calldata _data)
        external
        returns (address plugin, PreparedSetupData memory preparedSetupData)
    {
        InstallParams memory _params = abi.decode(_data, (InstallParams));

        plugin = ProxyLib.deployMinimalProxy(implementation(), "");
        Context memory _ctx = Context(_dao, plugin, _clone(_params.components));
        for (uint256 i; i < _params.components.length; ++i) {
            Address.functionCall(_ctx.components[i], _resolveCall(_params.components[i].initData, _ctx));
        }
        CapitalPipelinePlugin(plugin)
            .initialize(
                IDAO(_dao), IBudget(_resolve(address(_params.budget), _ctx)), _resolveNodes(_params.nodes, _ctx)
            );

        grantsHash[plugin] = keccak256(abi.encode(_params.grants));
        preparedSetupData.helpers = _ctx.components;
        preparedSetupData.permissions = _permissions(PermissionLib.Operation.Grant, _params.grants, _ctx);
    }

    /// @inheritdoc IPluginSetup
    /// @dev `_payload.data` is `abi.encode(Grant[])`: the recipe grants used at installation
    function prepareUninstallation(address _dao, SetupPayload calldata _payload)
        external
        view
        returns (PermissionLib.MultiTargetPermission[] memory)
    {
        Grant[] memory _grants = abi.decode(_payload.data, (Grant[]));
        if (keccak256(abi.encode(_grants)) != grantsHash[_payload.plugin]) revert GrantsMismatch();

        Context memory _ctx = Context(_dao, _payload.plugin, _payload.currentHelpers);
        return _permissions(PermissionLib.Operation.Revoke, _grants, _ctx);
    }

    // Internal

    function _clone(Component[] memory _components) internal returns (address[] memory _clones) {
        _clones = new address[](_components.length);
        for (uint256 i; i < _components.length; ++i) {
            _clones[i] = ProxyLib.deployMinimalProxy(registry.implementation(_components[i].id), "");
        }
    }

    function _resolveNodes(Node[] memory _nodes, Context memory _ctx) internal pure returns (Node[] memory _resolved) {
        _resolved = new Node[](_nodes.length);
        for (uint256 i; i < _nodes.length; ++i) {
            address _action = _resolve(address(_nodes[i].action), _ctx);
            _resolved[i] = Node(INodeAction(_action), _nodes[i].children, _nodes[i].weights);
        }
    }

    /// @dev EXECUTE and CONFIGURE, then the recipe grants
    function _permissions(PermissionLib.Operation _op, Grant[] memory _grants, Context memory _ctx)
        internal
        pure
        returns (PermissionLib.MultiTargetPermission[] memory _perms)
    {
        _perms = new PermissionLib.MultiTargetPermission[](2 + _grants.length);
        _perms[0] = _permission(_op, _ctx.dao, _ctx.plugin, EXECUTE_PERMISSION_ID);
        _perms[1] = _permission(_op, _ctx.plugin, _ctx.dao, CONFIGURE_PERMISSION_ID);

        for (uint256 i; i < _grants.length; ++i) {
            Grant memory _grant = _grants[i];
            if (_grant.permissionId == CONFIGURE_PERMISSION_ID) revert ReservedPermission(_grant.permissionId);
            if (!_isOwnContract(_grant.where)) revert GrantOutsideInstallation(_grant.where);

            _perms[2 + i] =
                _permission(_op, _resolve(_grant.where, _ctx), _resolve(_grant.who, _ctx), _grant.permissionId);
        }
    }

    function _permission(PermissionLib.Operation _op, address _where, address _who, bytes32 _id)
        internal
        pure
        returns (PermissionLib.MultiTargetPermission memory)
    {
        return PermissionLib.MultiTargetPermission({
            operation: _op, where: _where, who: _who, condition: PermissionLib.NO_CONDITION, permissionId: _id
        });
    }

    // Placeholders

    /// @dev The plugin or one of the recipe's components (not the DAO, not an outside address)
    function _isOwnContract(address _where) internal pure returns (bool) {
        return isPlaceholder(uint160(_where)) && uint160(_where) & 0xFFFF != DAO_INDEX;
    }

    /// @dev The address a placeholder stands for; any other address is returned as is
    function _resolve(address _value, Context memory _ctx) internal pure returns (address) {
        if (!isPlaceholder(uint160(_value))) return _value;

        uint256 _index = uint160(_value) & 0xFFFF;
        if (_index == DAO_INDEX) return _ctx.dao;
        if (_index == PLUGIN_INDEX) return _ctx.plugin;
        if (_index >= _ctx.components.length) revert UnknownReference(_index);
        return _ctx.components[_index];
    }

    /// @dev A copy of ABI-encoded call data with every placeholder word replaced
    function _resolveCall(bytes memory _data, Context memory _ctx) internal pure returns (bytes memory _resolved) {
        _resolved = bytes.concat(_data);
        for (uint256 _offset = 4; _offset + 32 <= _resolved.length; _offset += 32) {
            uint256 _word;
            assembly ("memory-safe") {
                _word := mload(add(add(_resolved, 32), _offset))
            }
            if (!isPlaceholder(_word)) continue;

            address _address = _resolve(address(uint160(_word)), _ctx);
            assembly ("memory-safe") {
                mstore(add(add(_resolved, 32), _offset), _address)
            }
        }
    }
}
