// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {DaoUnauthorized} from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {CapitalPipelinePlugin} from "../src/CapitalPipelinePlugin.sol";
import {FundedStreamBudget} from "../src/budgets/FundedStreamBudget.sol";
import {OpenFillAction} from "../src/actions/OpenFillAction.sol";
import {RatioSplitter} from "../src/splitters/RatioSplitter.sol";
import {IBudget} from "../src/interfaces/IBudget.sol";
import {IStepAction} from "../src/interfaces/IStepAction.sol";
import {ISplitter} from "../src/interfaces/ISplitter.sol";
import {Step} from "../src/lib/types.sol";
import {CONFIGURE_PERMISSION_ID} from "../src/lib/constants.sol";
import {Fixture} from "./helpers/Fixture.sol";

contract CapitalPipelinePluginTest is Fixture {
    FundedStreamBudget internal budget;
    OpenFillAction internal action;
    RatioSplitter internal splitter;
    CapitalPipelinePlugin internal plugin;

    function setUp() public override {
        super.setUp();
        budget = _deployBudget(RATE, 0);
        action = _deployAction(budget);
        splitter = _deploySplitter();
        plugin = _deployPlugin(_steps(budget, action, splitter));
    }

    // Configuration

    function test_StoresSteps() public view {
        Step[] memory _stored = plugin.steps();

        assertEq(_stored.length, 1);
        assertEq(address(_stored[0].budget), address(budget));
        assertEq(address(_stored[0].action), address(action));
        assertEq(address(_stored[0].splitter), address(splitter));
    }

    function test_DaoReplacesSteps() public {
        vm.prank(address(dao));
        plugin.setSteps(_steps(budget, IStepAction(address(0)), ISplitter(address(0))));

        assertEq(address(plugin.steps()[0].action), address(0));
    }

    function test_ManagerPauses() public {
        vm.prank(manager);
        plugin.setPaused(true);

        assertTrue(plugin.paused());
    }

    function test_RevertWhen_ManagerSetsSteps() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector, address(dao), address(plugin), manager, CONFIGURE_PERMISSION_ID
            )
        );
        vm.prank(manager);
        plugin.setSteps(_steps(budget, action, splitter));
    }

    function test_RevertWhen_NoSteps() public {
        CapitalPipelinePlugin _plugin = _clone();

        vm.expectRevert(CapitalPipelinePlugin.NoSteps.selector);
        _plugin.initialize(dao, new Step[](0));
    }

    function test_RevertWhen_StepHasNoBudget() public {
        CapitalPipelinePlugin _plugin = _clone();

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.NoBudget.selector, 0));
        _plugin.initialize(dao, _steps(IBudget(address(0)), action, splitter));
    }

    function test_RevertWhen_ActionBoundToAnotherBudget() public {
        FundedStreamBudget _other = _deployBudget(RATE, 0);

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.BudgetMismatch.selector, 0));
        vm.prank(address(dao));
        plugin.setSteps(_steps(_other, action, splitter));
    }

    function _clone() internal returns (CapitalPipelinePlugin) {
        return CapitalPipelinePlugin(ProxyLib.deployMinimalProxy(address(new CapitalPipelinePlugin()), ""));
    }
}
