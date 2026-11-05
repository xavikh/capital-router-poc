// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {DaoUnauthorized} from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {CapitalPipelinePlugin} from "../src/CapitalPipelinePlugin.sol";
import {FundedStreamBudget} from "../src/budgets/FundedStreamBudget.sol";
import {BalanceBudget} from "../src/budgets/BalanceBudget.sol";
import {OpenFillAction} from "../src/actions/OpenFillAction.sol";
import {MerkleClaimAction} from "../src/actions/MerkleClaimAction.sol";
import {KeepAction} from "../src/actions/KeepAction.sol";
import {IBudget} from "../src/interfaces/IBudget.sol";
import {INodeAction} from "../src/interfaces/INodeAction.sol";
import {Node} from "../src/lib/types.sol";
import {CONFIGURE_PERMISSION_ID, MANAGER_PERMISSION_ID} from "../src/lib/constants.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockFiller} from "./mocks/MockFiller.sol";
import {MockExchange, MockSwapAction} from "./mocks/MockSwap.sol";
import {BadAction} from "./mocks/BadComponents.sol";

contract CapitalPipelinePluginTest is Fixture {
    FundedStreamBudget internal budget;
    OpenFillAction internal action;
    CapitalPipelinePlugin internal plugin;
    MockFiller internal filler;

    /// @dev Swap 10 A for 1,000 B, then pay 95% to the burn address and 5% to the fee address
    function setUp() public override {
        super.setUp();
        budget = _deployBudget(RATE, 0);
        action = _deployAction(budget);
        plugin = _deployPlugin(budget, _splitToBurnAndFee(action));

        filler = new MockFiller(plugin);
        tokenB.mint(address(filler), 1_000_000 ether);

        vm.warp(block.timestamp + EPOCH); // 10 A on offer
    }

    // =========================================================================================
    // Configuration
    // =========================================================================================

    function test_StoresTheFlow() public view {
        Node[] memory _stored = plugin.nodes();

        assertEq(address(plugin.budget()), address(budget));
        assertEq(_stored.length, 3);
        assertEq(address(_stored[0].action), address(action));
        assertEq(_stored[0].children[1], 2);
        assertEq(_stored[0].weights[0], 950_000);
        assertEq(_stored[2].children.length, 0);
    }

    function test_DaoReplacesTheFlow() public {
        vm.prank(address(dao));
        plugin.setFlow(budget, _one(keep));

        assertEq(plugin.nodes().length, 1);
        assertEq(address(plugin.nodes()[0].action), address(keep));
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
        plugin.setFlow(budget, _one(keep));
    }

    function test_RevertWhen_NoBudget() public {
        _expectInitRevert(
            IBudget(address(0)), _one(keep), abi.encodeWithSelector(CapitalPipelinePlugin.NoBudget.selector)
        );
    }

    function test_RevertWhen_NoNodes() public {
        _expectInitRevert(
            budget, new Node[](0), abi.encodeWithSelector(CapitalPipelinePlugin.InvalidNodeCount.selector, 0)
        );
    }

    function test_RevertWhen_TooManyNodes() public {
        Node[] memory _tree = new Node[](17);
        for (uint32 i; i < 16; ++i) {
            _tree[i] = _then(keep, i + 1);
        }
        _tree[16] = _leaf(keep);

        _expectInitRevert(budget, _tree, abi.encodeWithSelector(CapitalPipelinePlugin.InvalidNodeCount.selector, 17));
    }

    function test_RevertWhen_ALeafHasNoAction() public {
        _expectInitRevert(
            budget, _one(NO_ACTION), abi.encodeWithSelector(CapitalPipelinePlugin.MissingAction.selector, 0)
        );
    }

    function test_RevertWhen_AChildDoesNotComeAfterItsParent() public {
        Node[] memory _tree = new Node[](1);
        _tree[0] = _then(keep, 0);

        _expectInitRevert(budget, _tree, abi.encodeWithSelector(CapitalPipelinePlugin.InvalidChild.selector, 0, 0));
    }

    function test_RevertWhen_ANodeHasTwoParents() public {
        Node[] memory _tree = new Node[](3);
        (_tree[0], _tree[1], _tree[2]) = (_branch(NO_ACTION, 1, 500_000, 2, 500_000), _then(keep, 2), _leaf(keep));

        _expectInitRevert(budget, _tree, abi.encodeWithSelector(CapitalPipelinePlugin.InvalidChild.selector, 1, 2));
    }

    function test_RevertWhen_ANodeIsUnreachable() public {
        Node[] memory _tree = new Node[](2);
        (_tree[0], _tree[1]) = (_leaf(keep), _leaf(keep));

        _expectInitRevert(budget, _tree, abi.encodeWithSelector(CapitalPipelinePlugin.UnreachableNode.selector, 1));
    }

    function test_RevertWhen_WeightsDoNotSumTo100() public {
        _expectInitRevert(
            budget,
            _fork(NO_ACTION, 600_000, keep, 300_000, keep),
            abi.encodeWithSelector(CapitalPipelinePlugin.InvalidWeights.selector, 0)
        );
    }

    function test_ABoundActionCanSitBelowNestedBranchesWithoutAction() public {
        Node[] memory _tree = new Node[](6);
        _tree[0] = _branch(NO_ACTION, 1, 500_000, 2, 500_000);
        _tree[1] = _leaf(keep);
        _tree[2] = _branch(NO_ACTION, 3, 500_000, 5, 500_000);
        _tree[3] = _then(action, 4);
        (_tree[4], _tree[5]) = (_leaf(keep), _leaf(keep));

        assertEq(address(_deployPlugin(budget, _tree).nodes()[3].action), address(action));
    }

    function test_RevertWhen_ABoundActionIsBelowAnAction() public {
        Node[] memory _tree = new Node[](5);
        _tree[0] = _then(_bad(BadAction.Mode.Pass), 1);
        _tree[1] = _branch(NO_ACTION, 2, 500_000, 4, 500_000);
        _tree[2] = _then(action, 3);
        (_tree[3], _tree[4]) = (_leaf(keep), _leaf(keep));

        _expectInitRevert(budget, _tree, abi.encodeWithSelector(CapitalPipelinePlugin.BudgetMismatch.selector, 2));
    }

    function test_RevertWhen_ANodeIsAnImplementation() public {
        KeepAction _implementation = new KeepAction();

        _expectInitRevert(
            budget,
            _one(_implementation),
            abi.encodeWithSelector(CapitalPipelinePlugin.ForeignComponent.selector, address(_implementation))
        );
    }

    function test_RevertWhen_ANodeBelongsToAnotherDao() public {
        KeepAction _foreign = _deployKeep(IDAO(makeAddr("otherDao")));

        _expectInitRevert(
            budget,
            _one(_foreign),
            abi.encodeWithSelector(CapitalPipelinePlugin.ForeignComponent.selector, address(_foreign))
        );
    }

    function test_RevertWhen_TheBudgetBelongsToAnotherDao() public {
        BalanceBudget _foreign = BalanceBudget(
            ProxyLib.deployMinimalProxy(
                address(new BalanceBudget()),
                abi.encodeCall(BalanceBudget.initialize, (IDAO(makeAddr("otherDao")), tokenA))
            )
        );

        _expectInitRevert(
            _foreign,
            _one(keep),
            abi.encodeWithSelector(CapitalPipelinePlugin.ForeignComponent.selector, address(_foreign))
        );
    }

    function test_RevertWhen_TheRootIsBoundToAnotherBudget() public {
        _expectInitRevert(
            _deployBudget(RATE, 0),
            _chain(action, keep),
            abi.encodeWithSelector(CapitalPipelinePlugin.BudgetMismatch.selector, 0)
        );
    }

    // =========================================================================================
    // Running flows
    // =========================================================================================

    function test_FillSwapsAndSplitsTheProceeds() public {
        filler.fill("");

        assertEq(tokenA.balanceOf(address(dao)), DAO_A - RATE, "DAO hands over the offer");
        assertEq(tokenA.balanceOf(address(filler)), RATE, "filler receives the offer");
        assertEq(tokenA.allowance(address(dao), address(filler)), 0, "no approval survives");
        assertEq(tokenB.balanceOf(BURN), 950 ether, "95% to the burn address");
        assertEq(tokenB.balanceOf(fee), 50 ether, "5% fee");
        assertEq(tokenB.balanceOf(address(dao)), DAO_B, "pre-existing B untouched");
        assertEq(budget.available(), 0, "auction restarts");
    }

    /// The example tree: swap, burn 95%, send 5% to a fee address
    function test_BuybackBurnsAndPaysAFee() public {
        CapitalPipelinePlugin _plugin =
            _deployPlugin(budget, _fork(action, 950_000, burn, 50_000, _deployTransfer(fee)));
        MockFiller _filler = new MockFiller(_plugin);
        tokenB.mint(address(_filler), DEMAND);
        uint256 _supply = tokenB.totalSupply();

        _filler.fillWithoutData();

        assertEq(tokenB.totalSupply(), _supply - 950 ether, "950 B burned");
        assertEq(tokenB.balanceOf(fee), 50 ether);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B);
    }

    function test_ABranchWithoutActionSplitsTheBudget() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(
            _deployBalanceBudget(tokenA),
            _fork(NO_ACTION, 500_000, _deployTransfer(alice), 500_000, _deployTransfer(bob))
        );

        _plugin.trigger(noData);

        assertEq(tokenA.balanceOf(alice), 50 ether);
        assertEq(tokenA.balanceOf(bob), 50 ether);
    }

    function test_KeepIsAnExplicitLeaf() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _chain(action, keep));
        MockFiller _filler = new MockFiller(_plugin);
        tokenB.mint(address(_filler), DEMAND);

        _filler.fillWithoutData();

        assertEq(tokenB.balanceOf(address(dao)), DAO_B + DEMAND, "the proceeds stay in the treasury");
    }

    function test_BudgetCommitsOnceAfterTheWholeTree() public {
        FundedStreamBudget _budget = _deployBudget(RATE, 0);
        CapitalPipelinePlugin _plugin =
            _deployPlugin(_budget, _fork(NO_ACTION, 500_000, _deployTransfer(alice), 500_000, _deployTransfer(bob)));
        vm.warp(block.timestamp + EPOCH);

        _plugin.trigger(noData);

        assertEq(_budget.available(), 0);
        assertEq(_budget.lastSeenBalance(), DAO_A - RATE, "the checkpoint sees the balance after both leaves");
    }

    /// A stream split between grants and an auction: the auction's offer grows at half the rate
    function test_ABranchSplitsTheStreamBetweenGrantsAndAnAuction() public {
        MockFiller _filler = new MockFiller(_deployPlugin(budget, _grantsAndAuction()));
        tokenB.mint(address(_filler), DEMAND);

        _filler.fillWithoutData();

        assertEq(tokenA.balanceOf(alice), RATE / 2, "half the stream to grants");
        assertEq(tokenA.balanceOf(address(_filler)), RATE / 2, "half the stream on offer");
        assertEq(tokenB.balanceOf(address(dao)), DAO_B + DEMAND, "the proceeds stay in the treasury");
        assertEq(budget.available(), 0, "the stream restarts for both");
    }

    /// The auction offers at most maxOffered(); the rest of its share never leaves the DAO
    function test_AnAuctionBelowABranchMayTakePartOfItsShare() public {
        MockFiller _filler = new MockFiller(_deployPlugin(budget, _grantsAndAuction()));
        tokenB.mint(address(_filler), DEMAND);
        vm.warp(block.timestamp + 5 * EPOCH); // 60 A: 30 for grants, 30 for the auction

        _filler.fillWithoutData();

        assertEq(tokenA.balanceOf(alice), 30 ether, "grants get their whole share");
        assertEq(tokenA.balanceOf(address(_filler)), action.maxOffered(), "the auction offers 20 A");
        assertEq(tokenA.balanceOf(address(dao)), DAO_A - 50 ether, "10 A stay in the DAO");
        assertEq(budget.available(), 0, "the stream restarts");
    }

    function test_RevertWhen_FillerUnderDelivers() public {
        filler.setFillDelta(-1);

        // Action 3 is OpenFill's postcondition: assertReceived
        vm.expectRevert(abi.encodeWithSelector(DAO.ActionFailed.selector, 3));
        filler.fill("");

        assertEq(budget.available(), RATE, "offer not consumed");
    }

    function test_PreconditionsCanBlockANode() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _chain(_bad(BadAction.Mode.Block), keep));

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
        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.DataLengthMismatch.selector, 3, 1));
        plugin.trigger(new bytes[](1));
    }

    // =========================================================================================
    // Every node must succeed
    // =========================================================================================

    function test_RevertWhen_TheBudgetIsEmpty() public {
        filler.fillWithoutData(); // the auction restarts at 0

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.EmptyInput.selector, 0));
        filler.fillWithoutData();
    }

    /// Every node must run, so a share that rounds to zero reverts the whole trigger
    function test_RevertWhen_AShareRoundsToZero() public {
        ERC20Mock _dust = new ERC20Mock("Dust", "D");
        _dust.mint(address(dao), 19); // 5% of 19 rounds to 0
        CapitalPipelinePlugin _plugin = _deployPlugin(
            _deployBalanceBudget(IERC20(address(_dust))),
            _fork(NO_ACTION, 950_000, _deployTransfer(alice), 50_000, _deployTransfer(bob))
        );

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.EmptyInput.selector, 2));
        _plugin.trigger(noData);
    }

    function test_RevertWhen_TheRootTakesNothing() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _chain(_bad(BadAction.Mode.Skip), keep));

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.NodeIncomplete.selector, 0, 0, RATE));
        _plugin.trigger(noData);
    }

    function test_RevertWhen_AChildTakesPartOfItsInput() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(
            _deployBalanceBudget(tokenA), _chain(_bad(BadAction.Mode.Pass), _bad(BadAction.Mode.TakeHalf), keep)
        );

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.NodeIncomplete.selector, 1, DAO_A / 2, DAO_A));
        _plugin.trigger(noData);
    }

    function test_RevertWhen_AChildSkips() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(
            _deployBalanceBudget(tokenA), _chain(_bad(BadAction.Mode.Pass), _bad(BadAction.Mode.Skip), keep)
        );

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.NodeIncomplete.selector, 1, 0, DAO_A));
        _plugin.trigger(noData);
    }

    function test_RevertWhen_ANodeTakesMoreThanItsInput() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _chain(_bad(BadAction.Mode.Overspend), keep));

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.InAmountExceedsInput.selector, 0, RATE + 1, RATE));
        _plugin.trigger(noData);
    }

    function test_RevertWhen_ALeafLeavesOutputBehind() public {
        MockSwapAction _swap = new MockSwapAction(new MockExchange(2e18), tokenB, address(dao));
        CapitalPipelinePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _one(_swap));

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.LeafLeftOutput.selector, 0, 2 * DAO_A));
        _plugin.trigger(noData);
    }

    function test_RevertWhen_ANodeChangesTheInputToken() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _chain(_bad(BadAction.Mode.SwapInputToken), keep));

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.InputTokenMismatch.selector, 0));
        _plugin.trigger(noData);
    }

    function test_RevertWhen_ALaterNodeChangesTheBeneficiary() public {
        BalanceBudget _budget = _deployBalanceBudget(tokenA);
        MerkleClaimAction _merkle =
            _deployMerkle(_budget, keccak256(bytes.concat(keccak256(abi.encode(alice, 1 ether)))));
        CapitalPipelinePlugin _plugin =
            _deployPlugin(_budget, _chain(_merkle, _bad(BadAction.Mode.Redirect), toBeneficiary));

        bytes[] memory _data = new bytes[](3);
        _data[0] = abi.encode(alice, 1 ether, new bytes32[](0), address(0));

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.BeneficiaryChanged.selector, 1));
        vm.prank(alice);
        _plugin.trigger(_data);
    }

    // =========================================================================================
    // Guards
    // =========================================================================================

    function test_RevertWhen_AnActionTargetsTheDao() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _chain(_bad(BadAction.Mode.TargetDao), keep));

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.ActionTargetsDao.selector, 0, 0));
        _plugin.trigger(noData);
    }

    function test_RevertWhen_AnActionTargetsThePlugin() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _chain(_bad(BadAction.Mode.TargetPlugin), keep));

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.ActionTargetsPlugin.selector, 0, 0));
        _plugin.trigger(noData);
    }

    function test_FillerCannotReenterTrigger() public {
        filler.setReenter(true);

        filler.fill("");

        assertEq(filler.reentryError(), abi.encodeWithSignature("Error(string)", "ReentrancyGuard: reentrant call"));
        assertEq(tokenB.balanceOf(BURN), 950 ether, "the outer fill still completes");
    }

    // =========================================================================================
    // Balance checks
    // =========================================================================================

    function test_RevertWhen_AnActionDeclaresOutputItNeverProduced() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _chain(_bad(BadAction.Mode.Lie), keep));

        vm.expectRevert(
            abi.encodeWithSelector(
                CapitalPipelinePlugin.UnexpectedBalance.selector, 0, address(tokenB), DAO_B + 10 ether, DAO_B
            )
        );
        _plugin.trigger(noData);
    }

    function test_RevertWhen_AnActionSpendsMoreThanItDeclared() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _one(_bad(BadAction.Mode.Drain)));

        // The root declared RATE / 2 but moved RATE
        vm.expectRevert(
            abi.encodeWithSelector(
                CapitalPipelinePlugin.UnexpectedBalance.selector, 0, address(tokenA), DAO_A - RATE / 2, DAO_A - RATE
            )
        );
        _plugin.trigger(noData);
    }

    // =========================================================================================
    // Helpers
    // =========================================================================================

    function _bad(BadAction.Mode _mode) internal returns (INodeAction) {
        return new BadAction(_mode, address(dao), tokenB);
    }

    /// @dev A branch without an action: 50% to alice (grants), 50% to the auction, whose proceeds are kept
    function _grantsAndAuction() internal returns (Node[] memory _tree) {
        _tree = new Node[](4);
        _tree[0] = _branch(NO_ACTION, 1, 500_000, 2, 500_000);
        _tree[1] = _leaf(_deployTransfer(alice));
        _tree[2] = _then(action, 3);
        _tree[3] = _leaf(keep);
    }

    function _expectInitRevert(IBudget _budget, Node[] memory _tree, bytes memory _error) internal {
        CapitalPipelinePlugin _plugin =
            CapitalPipelinePlugin(ProxyLib.deployMinimalProxy(address(new CapitalPipelinePlugin()), ""));
        vm.expectRevert(_error);
        _plugin.initialize(dao, _budget, _tree);
    }
}
