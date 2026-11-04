// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPluginSetup} from "@aragon/osx-commons-contracts/src/plugin/setup/IPluginSetup.sol";
import {PermissionLib} from "@aragon/osx-commons-contracts/src/permission/PermissionLib.sol";
import {CapitalPipelinePluginSetup} from "../src/setup/CapitalPipelinePluginSetup.sol";
import {CapitalPipelinePlugin} from "../src/CapitalPipelinePlugin.sol";
import {
    TRIGGER_PERMISSION_ID,
    CONFIGURE_PERMISSION_ID,
    MANAGER_PERMISSION_ID,
    CHECKPOINT_PERMISSION_ID
} from "../src/lib/constants.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {MockFiller} from "./mocks/MockFiller.sol";

contract CapitalPipelinePluginSetupTest is Fixture {
    CapitalPipelinePluginSetup internal setup;

    function setUp() public override {
        super.setUp();
        setup = new CapitalPipelinePluginSetup();
    }

    function test_InstalledPluginFillsAndSplits() public {
        (CapitalPipelinePlugin _plugin,) = _install();
        MockFiller _filler = new MockFiller(_plugin);
        tokenB.mint(address(_filler), 1_000_000 ether);
        vm.warp(block.timestamp + EPOCH);

        _filler.fill("");

        assertEq(tokenB.balanceOf(BURN), 950 ether);
        assertEq(tokenB.balanceOf(fee), 50 ether);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B);
    }

    function test_GrantsTheDesignedPermissions() public {
        (CapitalPipelinePlugin _plugin, address[] memory _helpers) = _install();

        _assertPermissions(address(_plugin), _helpers, true);
        assertFalse(
            dao.hasPermission(address(_plugin), manager, CONFIGURE_PERMISSION_ID, ""), "manager can't set steps"
        );
    }

    function test_UninstallRevokesEverything() public {
        (CapitalPipelinePlugin _plugin, address[] memory _helpers) = _install();

        PermissionLib.MultiTargetPermission[] memory _revokes = setup.prepareUninstallation(
            address(dao),
            IPluginSetup.SetupPayload({plugin: address(_plugin), currentHelpers: _helpers, data: abi.encode(manager)})
        );
        dao.applyMultiTargetPermissions(_revokes);

        _assertPermissions(address(_plugin), _helpers, false);
    }

    function _install() internal returns (CapitalPipelinePlugin _plugin, address[] memory _helpers) {
        address[] memory _recipients = new address[](2);
        (_recipients[0], _recipients[1]) = (BURN, fee);
        uint32[] memory _ratios = new uint32[](2);
        (_ratios[0], _ratios[1]) = (950_000, 50_000);

        bytes memory _params = abi.encode(
            CapitalPipelinePluginSetup.InstallParams({
                manager: manager,
                offeredToken: IERC20(tokenA),
                amountPerEpoch: RATE,
                maxBudget: 0,
                epochInterval: EPOCH,
                demandedToken: IERC20(tokenB),
                demandPerFill: DEMAND,
                minDemandedPerOffered: MIN_PRICE,
                recipients: _recipients,
                ratios: _ratios
            })
        );

        (address _pluginAddress, IPluginSetup.PreparedSetupData memory _prepared) =
            setup.prepareInstallation(address(dao), _params);
        dao.applyMultiTargetPermissions(_prepared.permissions);

        return (CapitalPipelinePlugin(_pluginAddress), _prepared.helpers);
    }

    function _assertPermissions(address _plugin, address[] memory _helpers, bool _expected) internal view {
        (address _budget, address _action, address _splitter) = (_helpers[0], _helpers[1], _helpers[2]);

        assertEq(dao.hasPermission(address(dao), _plugin, dao.EXECUTE_PERMISSION_ID(), ""), _expected, "execute");
        assertEq(dao.hasPermission(_plugin, address(0xA11CE), TRIGGER_PERMISSION_ID, ""), _expected, "trigger");
        assertEq(dao.hasPermission(_plugin, address(dao), CONFIGURE_PERMISSION_ID, ""), _expected, "configure");
        assertEq(dao.hasPermission(_plugin, manager, MANAGER_PERMISSION_ID, ""), _expected, "manage plugin");
        assertEq(dao.hasPermission(_budget, manager, MANAGER_PERMISSION_ID, ""), _expected, "manage budget");
        assertEq(dao.hasPermission(_action, manager, MANAGER_PERMISSION_ID, ""), _expected, "manage action");
        assertEq(dao.hasPermission(_splitter, manager, MANAGER_PERMISSION_ID, ""), _expected, "manage splitter");
        assertEq(dao.hasPermission(_budget, address(dao), CHECKPOINT_PERMISSION_ID, ""), _expected, "dao checkpoint");
        assertEq(dao.hasPermission(_budget, _action, CHECKPOINT_PERMISSION_ID, ""), _expected, "action checkpoint");
    }
}
