// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {DaoUnauthorized} from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {CapitalPipelinePlugin} from "../src/CapitalPipelinePlugin.sol";
import {FundedStreamBudget} from "../src/budgets/FundedStreamBudget.sol";
import {BalanceBudget} from "../src/budgets/BalanceBudget.sol";
import {OpenFillAction} from "../src/actions/OpenFillAction.sol";
import {MerkleClaimAction} from "../src/actions/MerkleClaimAction.sol";
import {RatioSplitter} from "../src/splitters/RatioSplitter.sol";
import {IBudget} from "../src/interfaces/IBudget.sol";
import {IStageAction} from "../src/interfaces/IStageAction.sol";
import {Stage} from "../src/lib/types.sol";
import {CONFIGURE_PERMISSION_ID, MANAGER_PERMISSION_ID} from "../src/lib/constants.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {MockFiller} from "./mocks/MockFiller.sol";
import {
    BadAction,
    OverAllocatingSplitter,
    DuplicateRecipientSplitter,
    FalseReturnToken
} from "./mocks/BadComponents.sol";

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
        plugin = _deployPlugin(budget, _one(action, splitter));

        filler = new MockFiller(plugin);
        tokenB.mint(address(filler), 1_000_000 ether);

        vm.warp(block.timestamp + EPOCH); // 10 A on offer
    }

    // Configuration

    function test_StoresTheFlow() public view {
        Stage[] memory _stored = plugin.stages();

        assertEq(address(plugin.budget()), address(budget));
        assertEq(_stored.length, 1);
        assertEq(address(_stored[0].action), address(action));
        assertEq(address(_stored[0].splitter), address(splitter));
    }

    function test_DaoReplacesTheFlow() public {
        vm.prank(address(dao));
        plugin.setFlow(budget, _one(NO_ACTION, splitter));

        assertEq(address(plugin.stages()[0].action), address(0));
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

    function test_RevertWhen_ManagerSetsTheFlow() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector, address(dao), address(plugin), manager, CONFIGURE_PERMISSION_ID
            )
        );
        vm.prank(manager);
        plugin.setFlow(budget, _one(action, splitter));
    }

    function test_RevertWhen_NoBudget() public {
        CapitalPipelinePlugin _plugin = _clone();

        vm.expectRevert(CapitalPipelinePlugin.NoBudget.selector);
        _plugin.initialize(dao, IBudget(address(0)), _one(action, splitter));
    }

    function test_RevertWhen_NoStages() public {
        CapitalPipelinePlugin _plugin = _clone();

        vm.expectRevert(CapitalPipelinePlugin.NoStages.selector);
        _plugin.initialize(dao, budget, new Stage[](0));
    }

    function test_RevertWhen_StageIsEmpty() public {
        CapitalPipelinePlugin _plugin = _clone();

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.EmptyStage.selector, 0));
        _plugin.initialize(dao, budget, _one(NO_ACTION, NO_SPLITTER));
    }

    function test_RevertWhen_ActionBoundToAnotherBudget() public {
        FundedStreamBudget _other = _deployBudget(RATE, 0);

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.BudgetMismatch.selector, 0));
        vm.prank(address(dao));
        plugin.setFlow(_other, _one(action, splitter));
    }

    function test_RevertWhen_BoundActionIsNotTheFirstStage() public {
        Stage[] memory _flow = _two(NO_ACTION, _deployRatio(address(dao)), action, splitter);

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.BudgetMismatch.selector, 1));
        vm.prank(address(dao));
        plugin.setFlow(budget, _flow);
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

    function test_StageWithoutActionPaysOutTheBudget() public {
        FundedStreamBudget _budget = _deployBudget(RATE, 0);
        CapitalPipelinePlugin _plugin = _deployPlugin(_budget, _one(NO_ACTION, splitter));
        vm.warp(block.timestamp + EPOCH);

        _plugin.trigger(noData);

        assertEq(tokenA.balanceOf(BURN), 9.5 ether);
        assertEq(tokenA.balanceOf(fee), 0.5 ether);
        assertEq(_budget.available(), 0);
    }

    function test_PreconditionsCanBlockAStage() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _one(_bad(BadAction.Mode.Block), splitter));

        vm.expectRevert(BadAction.Blocked.selector);
        _plugin.trigger(noData);
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

    function test_RevertWhen_ActionSpendsMoreThanItsInput() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _one(_bad(BadAction.Mode.Overspend), splitter));

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.InAmountExceedsInput.selector, 0, RATE + 1, RATE));
        _plugin.trigger(noData);
    }

    function test_RevertWhen_ActionChangesTheInputToken() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _one(_bad(BadAction.Mode.SwapInputToken), splitter));

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.InputTokenMismatch.selector, 0));
        _plugin.trigger(noData);
    }

    function test_RevertWhen_AllocationsExceedTheOutput() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _one(NO_ACTION, new OverAllocatingSplitter()));

        vm.expectRevert(
            abi.encodeWithSelector(CapitalPipelinePlugin.AllocationExceedsOutput.selector, 0, RATE + 1, RATE)
        );
        _plugin.trigger(noData);
    }

    function test_RevertWhen_AnActionTargetsTheDao() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _one(_bad(BadAction.Mode.TargetDao), splitter));

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.ActionTargetsDao.selector, 0, 0));
        _plugin.trigger(noData);
    }

    function test_FillerCannotReenterTrigger() public {
        filler.setReenter(true);

        filler.fill("");

        assertEq(filler.reentryError(), abi.encodeWithSignature("Error(string)", "ReentrancyGuard: reentrant call"));
        assertEq(tokenB.balanceOf(BURN), 950 ether, "the outer fill still completes");
    }

    // Chaining

    function test_KeptShareFeedsTheNextStage() public {
        // Stage 0: swap, 5% fee, 95% kept by the DAO. Stage 1: pay the kept 95% to alice.
        CapitalPipelinePlugin _plugin = _deployPlugin(
            budget, _two(action, _deployRatio(fee, 50_000, address(dao), 950_000), NO_ACTION, _deployRatio(alice))
        );
        MockFiller _filler = new MockFiller(_plugin);
        tokenB.mint(address(_filler), DEMAND);

        _filler.fillWithoutData();

        assertEq(tokenB.balanceOf(fee), 50 ether);
        assertEq(tokenB.balanceOf(alice), 950 ether);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B, "only the swap output moved, never the treasury's B");
    }

    function test_UnsplitOutputFeedsTheNextStage() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _two(action, NO_SPLITTER, NO_ACTION, _deployRatio(alice)));
        MockFiller _filler = new MockFiller(_plugin);
        tokenB.mint(address(_filler), DEMAND);

        _filler.fillWithoutData();

        assertEq(tokenB.balanceOf(alice), DEMAND);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B);
    }

    function test_SkippedFirstStageLeavesTheBudgetUntouched() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _one(_bad(BadAction.Mode.Skip), splitter));

        _plugin.trigger(noData);

        assertEq(budget.available(), RATE, "no checkpoint");
    }

    function test_SkippedLaterStageKeepsTheLeftoverInTheDao() public {
        CapitalPipelinePlugin _plugin =
            _deployPlugin(budget, _two(action, NO_SPLITTER, _bad(BadAction.Mode.Skip), _deployRatio(alice)));
        MockFiller _filler = new MockFiller(_plugin);
        tokenB.mint(address(_filler), DEMAND);

        _filler.fillWithoutData();

        assertEq(tokenB.balanceOf(address(dao)), DAO_B + DEMAND);
        assertEq(budget.available(), 0, "the budget is still committed: stage 0 spent it");
    }

    function test_BudgetCommitsOnceAfterTheLastStage() public {
        // Both stages spend A: half to alice, then the kept half to bob
        FundedStreamBudget _budget = _deployBudget(RATE, 0);
        CapitalPipelinePlugin _plugin = _deployPlugin(
            _budget, _two(NO_ACTION, _deployRatio(alice, 500_000, address(dao), 500_000), NO_ACTION, _deployRatio(bob))
        );
        vm.warp(block.timestamp + EPOCH);

        _plugin.trigger(noData);

        assertEq(tokenA.balanceOf(alice), RATE / 2);
        assertEq(tokenA.balanceOf(bob), RATE / 2);
        assertEq(_budget.lastSeenBalance(), DAO_A - RATE, "checkpoint sees the balance after both stages");
    }

    function test_RevertWhen_ALaterStageChangesTheBeneficiary() public {
        BalanceBudget _budget = _deployBalanceBudget(tokenA);
        MerkleClaimAction _merkle = _deployMerkle(_budget, _singleLeafRoot(alice, 1 ether));
        CapitalPipelinePlugin _plugin =
            _deployPlugin(_budget, _two(_merkle, NO_SPLITTER, _bad(BadAction.Mode.Redirect), _deployRatio(alice)));

        bytes[] memory _data = new bytes[](2);
        _data[0] = abi.encode(alice, 1 ether, new bytes32[](0), address(0));

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.BeneficiaryChanged.selector, 1));
        _plugin.trigger(_data);
    }

    // Balance checks

    function test_RevertWhen_ActionDeclaresOutputItNeverProduced() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _one(_bad(BadAction.Mode.Lie), NO_SPLITTER));

        vm.expectRevert(
            abi.encodeWithSelector(
                CapitalPipelinePlugin.UnexpectedBalance.selector,
                0,
                address(dao),
                address(tokenB),
                DAO_B + 10 ether,
                DAO_B
            )
        );
        _plugin.trigger(noData);
    }

    function test_RevertWhen_ActionSpendsMoreThanItDeclared() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _one(_bad(BadAction.Mode.Drain), NO_SPLITTER));

        // Declared RATE / 2, actually moved RATE
        vm.expectRevert(
            abi.encodeWithSelector(
                CapitalPipelinePlugin.UnexpectedBalance.selector,
                0,
                address(dao),
                address(tokenA),
                DAO_A - RATE / 2,
                DAO_A - RATE
            )
        );
        _plugin.trigger(noData);
    }

    function test_RevertWhen_ATransferSilentlyFails() public {
        FalseReturnToken _token = new FalseReturnToken(0);
        _token.mint(address(dao), 100 ether);
        CapitalPipelinePlugin _plugin =
            _deployPlugin(_deployBalanceBudget(IERC20(address(_token))), _one(NO_ACTION, _deployRatio(alice)));

        vm.expectRevert(
            abi.encodeWithSelector(
                CapitalPipelinePlugin.UnexpectedBalance.selector, 0, alice, address(_token), 100 ether, 0
            )
        );
        _plugin.trigger(noData);
    }

    /// capital-router checks each transfer against a snapshot taken before any of them, so a
    /// recipient listed twice can miss a silent failure. Here expectations add up per recipient.
    function test_RevertWhen_ARepeatedRecipientMissesATransfer() public {
        FalseReturnToken _token = new FalseReturnToken(1); // the second transfer silently fails
        _token.mint(address(dao), 100 ether);
        CapitalPipelinePlugin _plugin = _deployPlugin(
            _deployBalanceBudget(IERC20(address(_token))), _one(NO_ACTION, new DuplicateRecipientSplitter(alice))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                CapitalPipelinePlugin.UnexpectedBalance.selector, 0, alice, address(_token), 100 ether, 50 ether
            )
        );
        _plugin.trigger(noData);
    }

    // Helpers

    function _bad(BadAction.Mode _mode) internal returns (IStageAction) {
        return new BadAction(_mode, address(dao), tokenB);
    }

    function _clone() internal returns (CapitalPipelinePlugin) {
        return CapitalPipelinePlugin(ProxyLib.deployMinimalProxy(address(new CapitalPipelinePlugin()), ""));
    }

    /// @dev A one-leaf tree: the root is the leaf itself and the proof is empty
    function _singleLeafRoot(address _account, uint256 _cumulative) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(_account, _cumulative))));
    }
}
