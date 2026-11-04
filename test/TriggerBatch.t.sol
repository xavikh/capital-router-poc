// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {CapitalPipelinePlugin} from "../src/CapitalPipelinePlugin.sol";
import {TriggerBatch} from "../src/periphery/TriggerBatch.sol";
import {Fixture} from "./helpers/Fixture.sol";

contract TriggerBatchTest is Fixture {
    TriggerBatch internal batch = new TriggerBatch();
    CapitalPipelinePlugin internal pluginOnDao1;
    CapitalPipelinePlugin internal pluginOnDao2;
    CapitalPipelinePlugin internal pausedPlugin;

    function setUp() public override {
        super.setUp();
        pluginOnDao1 = _deployPlugin(_deployBalanceBudget(tokenA), _one(NO_ACTION, _deployRatio(alice)));

        DAO _dao1 = dao;
        dao = _newDao();
        tokenA.mint(address(dao), 50 ether);
        pluginOnDao2 = _deployPlugin(_deployBalanceBudget(tokenA), _one(NO_ACTION, _deployRatio(alice)));
        pausedPlugin = _deployPlugin(_deployBalanceBudget(tokenA), _one(NO_ACTION, _deployRatio(bob)));
        vm.prank(manager);
        pausedPlugin.pause();
        dao = _dao1;
    }

    function test_TriggersPluginsOnSeveralDaos() public {
        (CapitalPipelinePlugin[] memory _plugins, bytes[][] memory _data, bool[] memory _allowFailure) = _batch();

        batch.triggerAll(_plugins, _data, _allowFailure);

        assertEq(tokenA.balanceOf(alice), DAO_A + 50 ether, "both DAOs paid");
        assertEq(tokenA.balanceOf(bob), 0, "the paused plugin was skipped");
    }

    function test_RevertWhen_APluginThatMustSucceedFails() public {
        (CapitalPipelinePlugin[] memory _plugins, bytes[][] memory _data, bool[] memory _allowFailure) = _batch();
        _allowFailure[2] = false;

        vm.expectRevert("Pausable: paused");
        batch.triggerAll(_plugins, _data, _allowFailure);
    }

    function test_RevertWhen_LengthsDiffer() public {
        vm.expectRevert(TriggerBatch.LengthMismatch.selector);
        batch.triggerAll(new CapitalPipelinePlugin[](1), new bytes[][](0), new bool[](1));
    }

    function _batch()
        internal
        view
        returns (CapitalPipelinePlugin[] memory _plugins, bytes[][] memory _data, bool[] memory _allowFailure)
    {
        _plugins = new CapitalPipelinePlugin[](3);
        (_plugins[0], _plugins[1], _plugins[2]) = (pluginOnDao1, pluginOnDao2, pausedPlugin);
        _data = new bytes[][](3);
        _allowFailure = new bool[](3);
        _allowFailure[2] = true;
    }

    function _newDao() internal returns (DAO) {
        return DAO(
            payable(ProxyLib.deployUUPSProxy(
                    address(new DAO()), abi.encodeCall(DAO.initialize, ("", address(this), address(0), ""))
                ))
        );
    }
}
