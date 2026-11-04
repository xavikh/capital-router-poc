// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {PermissionLib} from "@aragon/osx-commons-contracts/src/permission/PermissionLib.sol";
import {IPluginSetup} from "@aragon/osx-commons-contracts/src/plugin/setup/IPluginSetup.sol";
import {PluginSetup} from "@aragon/osx-commons-contracts/src/plugin/setup/PluginSetup.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {CapitalPipelinePlugin} from "../CapitalPipelinePlugin.sol";
import {FundedStreamBudget} from "../budgets/FundedStreamBudget.sol";
import {OpenFillAction} from "../actions/OpenFillAction.sol";
import {RatioSplitter} from "../splitters/RatioSplitter.sol";
import {ICheckpointedBudget} from "../interfaces/IBudget.sol";
import {Step} from "../lib/types.sol";
import {
    TRIGGER_PERMISSION_ID,
    CONFIGURE_PERMISSION_ID,
    MANAGER_PERMISSION_ID,
    CHECKPOINT_PERMISSION_ID
} from "../lib/constants.sol";

/// @title CapitalPipelinePluginSetup
/// @notice Installs a plugin with one swap-and-split step: FundedStreamBudget → OpenFillAction →
///         RatioSplitter. Deploys every component as a clone bound to the installing DAO.
contract CapitalPipelinePluginSetup is PluginSetup {
    /// @notice Installation parameters
    struct InstallParams {
        address manager;
        IERC20 offeredToken;
        uint256 amountPerEpoch;
        uint256 maxBudget;
        uint256 epochInterval;
        IERC20 demandedToken;
        uint256 demandPerFill;
        uint256 minDemandedPerOffered;
        address[] recipients;
        uint32[] ratios;
    }

    /// @dev Same value as OSx PermissionManager.ANY_ADDR
    address internal constant ANY_ADDR = address(type(uint160).max);

    /// @dev EXECUTE_PERMISSION_ID on the OSx DAO
    bytes32 internal constant EXECUTE_PERMISSION_ID = keccak256("EXECUTE_PERMISSION");

    address public immutable budgetImplementation;
    address public immutable actionImplementation;
    address public immutable splitterImplementation;

    constructor() PluginSetup(address(new CapitalPipelinePlugin())) {
        budgetImplementation = address(new FundedStreamBudget());
        actionImplementation = address(new OpenFillAction());
        splitterImplementation = address(new RatioSplitter());
    }

    /// @inheritdoc IPluginSetup
    /// @dev `_data` is `abi.encode(InstallParams)`. Helpers: [budget, action, splitter].
    function prepareInstallation(address _dao, bytes calldata _data)
        external
        returns (address plugin, PreparedSetupData memory preparedSetupData)
    {
        InstallParams memory _params = abi.decode(_data, (InstallParams));

        address[] memory _helpers = _deployComponents(IDAO(_dao), _params);

        Step[] memory _steps = new Step[](1);
        _steps[0] = Step({
            budget: FundedStreamBudget(_helpers[0]),
            action: OpenFillAction(_helpers[1]),
            splitter: RatioSplitter(_helpers[2])
        });

        plugin = ProxyLib.deployMinimalProxy(
            implementation(), abi.encodeCall(CapitalPipelinePlugin.initialize, (IDAO(_dao), _steps))
        );

        preparedSetupData.helpers = _helpers;
        preparedSetupData.permissions =
            _permissions(PermissionLib.Operation.Grant, _dao, plugin, _params.manager, _helpers);
    }

    /// @inheritdoc IPluginSetup
    /// @dev `_payload.data` is `abi.encode(address manager)`: the manager to revoke.
    function prepareUninstallation(address _dao, SetupPayload calldata _payload)
        external
        pure
        returns (PermissionLib.MultiTargetPermission[] memory)
    {
        address _manager = abi.decode(_payload.data, (address));
        return _permissions(PermissionLib.Operation.Revoke, _dao, _payload.plugin, _manager, _payload.currentHelpers);
    }

    // Internal

    function _deployComponents(IDAO _dao, InstallParams memory _params) internal returns (address[] memory _helpers) {
        _helpers = new address[](3);
        _helpers[0] = ProxyLib.deployMinimalProxy(
            budgetImplementation,
            abi.encodeCall(
                FundedStreamBudget.initialize,
                (_dao, _params.offeredToken, _params.amountPerEpoch, _params.maxBudget, _params.epochInterval)
            )
        );
        _helpers[1] = ProxyLib.deployMinimalProxy(
            actionImplementation,
            abi.encodeCall(
                OpenFillAction.initialize,
                (
                    _dao,
                    ICheckpointedBudget(_helpers[0]),
                    _params.demandedToken,
                    _params.demandPerFill,
                    _params.minDemandedPerOffered
                )
            )
        );
        _helpers[2] = ProxyLib.deployMinimalProxy(
            splitterImplementation, abi.encodeCall(RatioSplitter.initialize, (_dao, _params.recipients, _params.ratios))
        );
    }

    /// @dev The same nine permissions, granted at install and revoked at uninstall
    function _permissions(
        PermissionLib.Operation _op,
        address _dao,
        address _plugin,
        address _manager,
        address[] memory _helpers
    ) internal pure returns (PermissionLib.MultiTargetPermission[] memory _perms) {
        (address _budget, address _action, address _splitter) = (_helpers[0], _helpers[1], _helpers[2]);

        _perms = new PermissionLib.MultiTargetPermission[](9);
        _perms[0] = _permission(_op, _dao, _plugin, EXECUTE_PERMISSION_ID);
        _perms[1] = _permission(_op, _plugin, ANY_ADDR, TRIGGER_PERMISSION_ID);
        _perms[2] = _permission(_op, _plugin, _dao, CONFIGURE_PERMISSION_ID);
        _perms[3] = _permission(_op, _plugin, _manager, MANAGER_PERMISSION_ID);
        _perms[4] = _permission(_op, _budget, _manager, MANAGER_PERMISSION_ID);
        _perms[5] = _permission(_op, _action, _manager, MANAGER_PERMISSION_ID);
        _perms[6] = _permission(_op, _splitter, _manager, MANAGER_PERMISSION_ID);
        _perms[7] = _permission(_op, _budget, _dao, CHECKPOINT_PERMISSION_ID);
        _perms[8] = _permission(_op, _budget, _action, CHECKPOINT_PERMISSION_ID);
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
}
