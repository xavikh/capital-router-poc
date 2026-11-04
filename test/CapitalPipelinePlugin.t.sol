// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {DAO} from "@aragon/osx/core/dao/DAO.sol";
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
import {CONFIGURE_PERMISSION_ID, MANAGER_PERMISSION_ID} from "../src/lib/constants.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {MockFiller} from "./mocks/MockFiller.sol";
import {BadAction, OverAllocatingSplitter} from "./mocks/BadComponents.sol";

contract CapitalPipelinePluginTest is Fixture {
    FundedStreamBudget internal budget;
    OpenFillAction internal action;
    RatioSplitter internal splitter;
    CapitalPipelinePlugin internal plugin;
    MockFiller internal filler;

    function setUp() public override {
        super.setUp();
        budget = _deployBudget(RATE, 0);
        action = _deployAction(budget);
        splitter = _deploySplitter();
        plugin = _deployPlugin(_steps(budget, action, splitter));

        filler = new MockFiller(plugin);
        tokenB.mint(address(filler), 1_000_000 ether);

        vm.warp(block.timestamp + EPOCH); // 10 A on offer
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

    function test_ManagerPausesAndUnpauses() public {
        vm.prank(manager);
        plugin.pause();
        assertTrue(plugin.paused());

        vm.prank(manager);
        plugin.unpause();
        assertFalse(plugin.paused());
    }

    function test_RevertWhen_PauseUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector, address(dao), address(plugin), address(this), MANAGER_PERMISSION_ID
            )
        );
        plugin.pause();
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

    // Trigger

    function test_FillSwapsAndSplitsTheProceeds() public {
        filler.fill("");

        assertEq(tokenA.balanceOf(address(dao)), DAO_A - RATE, "DAO hands over the offer");
        assertEq(tokenA.balanceOf(address(filler)), RATE, "filler receives the offer");
        assertEq(tokenA.allowance(address(dao), address(filler)), 0, "no approval survives");
        assertEq(tokenB.balanceOf(BURN), 950 ether, "95% burned");
        assertEq(tokenB.balanceOf(fee), 50 ether, "5% fee");
        assertEq(tokenB.balanceOf(address(dao)), DAO_B, "pre-existing B untouched");
        assertEq(budget.available(), 0, "auction restarts");
    }

    function test_SecondFillInTheSameBlockGetsNothing() public {
        filler.fill("");
        filler.fill("");

        assertEq(tokenA.balanceOf(address(filler)), RATE);
        assertEq(tokenB.balanceOf(BURN), 950 ether);
    }

    function test_RevertWhen_FillerUnderDelivers() public {
        filler.setFillDelta(-1);

        // Action 3 is the postcondition: assertReceived
        vm.expectRevert(abi.encodeWithSelector(DAO.ActionFailed.selector, 3));
        filler.fill("");

        assertEq(budget.available(), RATE, "offer not consumed");
    }

    function test_StepWithoutActionTransfersTheBudget() public {
        FundedStreamBudget _budget = _deployBudget(RATE, 0);
        CapitalPipelinePlugin _plugin = _deployPlugin(_steps(_budget, IStepAction(address(0)), splitter));
        vm.warp(block.timestamp + EPOCH);

        _plugin.trigger(new bytes[](0));

        assertEq(tokenA.balanceOf(BURN), 9.5 ether);
        assertEq(tokenA.balanceOf(fee), 0.5 ether);
        assertEq(_budget.available(), 0);
    }

    function test_PreconditionsCanBlockAStep() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(_steps(budget, _bad(BadAction.Mode.Block), splitter));

        vm.expectRevert(BadAction.Blocked.selector);
        _plugin.trigger(new bytes[](0));
    }

    function test_RevertWhen_Paused() public {
        vm.prank(manager);
        plugin.pause();

        vm.expectRevert("Pausable: paused");
        filler.fill("");
    }

    function test_RevertWhen_DataLengthMismatch() public {
        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.DataLengthMismatch.selector, 1, 2));
        plugin.trigger(new bytes[](2));
    }

    function test_RevertWhen_ActionSpendsMoreThanTheBudget() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(_steps(budget, _bad(BadAction.Mode.Overspend), splitter));

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.InAmountExceedsBudget.selector, 0, RATE + 1, RATE));
        _plugin.trigger(new bytes[](0));
    }

    function test_RevertWhen_AllocationsExceedTheOutput() public {
        CapitalPipelinePlugin _plugin =
            _deployPlugin(_steps(budget, IStepAction(address(0)), new OverAllocatingSplitter()));

        vm.expectRevert(
            abi.encodeWithSelector(CapitalPipelinePlugin.AllocationExceedsOutput.selector, 0, RATE + 1, RATE)
        );
        _plugin.trigger(new bytes[](0));
    }

    // Guards

    function test_RevertWhen_AnActionTargetsTheDao() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(_steps(budget, _bad(BadAction.Mode.TargetDao), splitter));

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.ActionTargetsDao.selector, 0, 0));
        _plugin.trigger(new bytes[](0));
    }

    function test_FillerCannotReenterTrigger() public {
        filler.setReenter(true);

        filler.fill("");

        assertEq(filler.reentryError(), abi.encodeWithSignature("Error(string)", "ReentrancyGuard: reentrant call"));
        assertEq(tokenB.balanceOf(BURN), 950 ether, "the outer fill still completes");
    }

    function _bad(BadAction.Mode _mode) internal returns (IStepAction) {
        return new BadAction(_mode, address(dao));
    }

    function _clone() internal returns (CapitalPipelinePlugin) {
        return CapitalPipelinePlugin(ProxyLib.deployMinimalProxy(address(new CapitalPipelinePlugin()), ""));
    }
}
