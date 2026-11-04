# Capital Pipeline v2 (Flows) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use /executing-plans to implement this plan task-by-task.

**Goal:** Restructure the plugin around flows (one budget → chained stages → budget commit), check balances after every stage like capital-router's `assertReceived` but per recipient, and add Merkle claims with a redirectable beneficiary.

**Architecture:** `CapitalPipelinePlugin` stores one `IBudget` and a `Stage[]` (`{action, splitter}`). `trigger` reads the budget once, then for each stage plans (action hooks + splitter), snapshots balances, runs one `dao.execute`, verifies balances, and passes `outAmount − transferred` to the next stage. The budget commits once at the end. Splitters receive the whole `Plan`, which now carries a `beneficiary` that a Merkle claim sets and later stages can't change.

**Tech Stack:** Solidity 0.8.28 (cancun, optimizer 200, **never via_ir**), Foundry, Aragon OSx 1.4, OpenZeppelin 4.9.6. Testing patterns: @sol-test.

**Design:** `docs/plans/2026-11-04-capital-pipeline-design.md` (v2). **Branch:** `feat/flow-stages`.

**Verified:** every code block below was compiled and tested in a scratch copy of this repo, including the state after each task. The balance-check tests were also confirmed to fail when the checks are removed.

---

## Tasks

| # | Task | End state | Time |
|---|---|---|---|
| 1 | Core restructure: flows, stages, balance checks | 66 tests pass | 25 min |
| 2 | Merkle claims: BalanceBudget, PayBeneficiary, MerkleClaimAction | 86 tests pass | 15 min |
| 3 | TriggerBatch | 89 tests pass | 5 min |
| 4 | README | unchanged | 5 min |

Conventions:
- Copy every code block verbatim; each file block replaces the whole file.
- Test names: `test_<Behavior>`, `test_RevertWhen_<Condition>`, `testFuzz_<Property>`, `invariant_<Property>`.
- Commit messages have no `Co-Authored-By` line.
- Unchanged and not touched by this plan: `src/budgets/FundedStreamBudget.sol`, `src/interfaces/IBudget.sol`, `src/interfaces/IFiller.sol`, `src/lib/constants.sol`, `test/FundedStreamBudget.t.sol`, `test/CapitalPipelinePluginSetup.t.sol`, `test/mocks/ERC20Mock.sol`.

---

### Task 1: Core restructure: flows, stages, balance checks

Replaces the step model. `IStepAction` becomes `IStageAction`; `ISplitter.split` takes the whole `Plan`; `Plan` gains `beneficiary`; the plugin runs one flow with per-stage execution and balance checks.

**Files:**
- Modify (tests first): `test/helpers/Fixture.sol`, `test/mocks/BadComponents.sol`, `test/mocks/MockFiller.sol`, `test/CapitalPipelinePlugin.t.sol`, `test/RatioSplitter.t.sol`, `test/OpenFillAction.t.sol`, `test/invariant/PipelineInvariant.t.sol`
- Modify: `src/lib/types.sol`, `src/interfaces/ISplitter.sol`, `src/actions/OpenFillAction.sol`, `src/splitters/RatioSplitter.sol`, `src/CapitalPipelinePlugin.sol`, `src/setup/CapitalPipelinePluginSetup.sol`
- Create: `src/interfaces/IStageAction.sol`
- Delete: `src/interfaces/IStepAction.sol`

**Step 1: Replace `test/helpers/Fixture.sol`**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {FundedStreamBudget} from "../../src/budgets/FundedStreamBudget.sol";
import {RatioSplitter} from "../../src/splitters/RatioSplitter.sol";
import {OpenFillAction} from "../../src/actions/OpenFillAction.sol";
import {CapitalPipelinePlugin} from "../../src/CapitalPipelinePlugin.sol";
import {IBudget} from "../../src/interfaces/IBudget.sol";
import {IStageAction} from "../../src/interfaces/IStageAction.sol";
import {ISplitter} from "../../src/interfaces/ISplitter.sol";
import {Stage} from "../../src/lib/types.sol";
import {
    MANAGER_PERMISSION_ID,
    CHECKPOINT_PERMISSION_ID,
    TRIGGER_PERMISSION_ID,
    CONFIGURE_PERMISSION_ID
} from "../../src/lib/constants.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

/// @notice A DAO holding the offered token A and some pre-existing demanded token B.
///         The test contract is the DAO's ROOT, so it can grant permissions directly.
abstract contract Fixture is Test {
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;
    address internal constant ANY_ADDR = address(type(uint160).max);
    IStageAction internal constant NO_ACTION = IStageAction(address(0));
    ISplitter internal constant NO_SPLITTER = ISplitter(address(0));

    uint256 internal constant DAO_A = 100 ether; // offered token held by the DAO
    uint256 internal constant DAO_B = 500 ether; // pre-existing demanded token: must never be spent
    uint256 internal constant RATE = 10 ether; // offer growth per epoch
    uint256 internal constant EPOCH = 1 days;
    uint256 internal constant DEMAND = 1000 ether; // B demanded per fill
    uint256 internal constant MIN_PRICE = 50 ether; // 50 B per A, 1e18-scaled → maxOffered = 20 A

    address internal manager = makeAddr("manager");
    address internal fee = makeAddr("fee");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    DAO internal dao;
    ERC20Mock internal tokenA;
    ERC20Mock internal tokenB;
    bytes[] internal noData;

    function setUp() public virtual {
        vm.warp(1_000_000);

        dao = DAO(
            payable(ProxyLib.deployUUPSProxy(
                    address(new DAO()), abi.encodeCall(DAO.initialize, ("", address(this), address(0), ""))
                ))
        );

        tokenA = new ERC20Mock("Offered", "A");
        tokenB = new ERC20Mock("Demanded", "B");
        tokenA.mint(address(dao), DAO_A);
        tokenB.mint(address(dao), DAO_B);
    }

    // Budgets

    /// @dev Deploy after funding the DAO: the budget records the balance it sees at init
    function _deployBudget(uint256 _rate, uint256 _maxBudget) internal returns (FundedStreamBudget _budget) {
        _budget = FundedStreamBudget(
            ProxyLib.deployMinimalProxy(
                address(new FundedStreamBudget()),
                abi.encodeCall(FundedStreamBudget.initialize, (dao, tokenA, _rate, _maxBudget, EPOCH))
            )
        );
        dao.grant(address(_budget), manager, MANAGER_PERMISSION_ID);
        dao.grant(address(_budget), address(dao), CHECKPOINT_PERMISSION_ID);
    }

    // Splitters

    /// @dev 95% to the burn address, 5% to the fee address
    function _deploySplitter() internal returns (RatioSplitter) {
        return _deployRatio(BURN, 950_000, fee, 50_000);
    }

    function _deployRatio(address _a, uint32 _ratioA, address _b, uint32 _ratioB) internal returns (RatioSplitter) {
        address[] memory _recipients = new address[](2);
        (_recipients[0], _recipients[1]) = (_a, _b);
        uint32[] memory _ratios = new uint32[](2);
        (_ratios[0], _ratios[1]) = (_ratioA, _ratioB);
        return _deployRatio(_recipients, _ratios);
    }

    /// @dev 100% to one recipient
    function _deployRatio(address _recipient) internal returns (RatioSplitter) {
        address[] memory _recipients = new address[](1);
        _recipients[0] = _recipient;
        uint32[] memory _ratios = new uint32[](1);
        _ratios[0] = 1_000_000;
        return _deployRatio(_recipients, _ratios);
    }

    function _deployRatio(address[] memory _recipients, uint32[] memory _ratios)
        internal
        returns (RatioSplitter _splitter)
    {
        _splitter = RatioSplitter(
            ProxyLib.deployMinimalProxy(
                address(new RatioSplitter()), abi.encodeCall(RatioSplitter.initialize, (dao, _recipients, _ratios))
            )
        );
        dao.grant(address(_splitter), manager, MANAGER_PERMISSION_ID);
    }

    // Actions

    /// @dev Bound to `_budget`, which it may restart when its price terms change
    function _deployAction(FundedStreamBudget _budget) internal returns (OpenFillAction _action) {
        _action = OpenFillAction(
            ProxyLib.deployMinimalProxy(
                address(new OpenFillAction()),
                abi.encodeCall(OpenFillAction.initialize, (dao, _budget, tokenB, DEMAND, MIN_PRICE))
            )
        );
        dao.grant(address(_action), manager, MANAGER_PERMISSION_ID);
        dao.grant(address(_budget), address(_action), CHECKPOINT_PERMISSION_ID);
    }

    // Plugin

    /// @dev Same grants as CapitalPipelinePluginSetup: anyone triggers, the DAO configures, the manager pauses
    function _deployPlugin(IBudget _budget, Stage[] memory _flow) internal returns (CapitalPipelinePlugin _plugin) {
        _plugin = CapitalPipelinePlugin(
            ProxyLib.deployMinimalProxy(
                address(new CapitalPipelinePlugin()),
                abi.encodeCall(CapitalPipelinePlugin.initialize, (dao, _budget, _flow))
            )
        );
        dao.grant(address(dao), address(_plugin), dao.EXECUTE_PERMISSION_ID());
        dao.grant(address(_plugin), ANY_ADDR, TRIGGER_PERMISSION_ID);
        dao.grant(address(_plugin), address(dao), CONFIGURE_PERMISSION_ID);
        dao.grant(address(_plugin), manager, MANAGER_PERMISSION_ID);
    }

    function _one(IStageAction _action, ISplitter _splitter) internal pure returns (Stage[] memory _flow) {
        _flow = new Stage[](1);
        _flow[0] = Stage({action: _action, splitter: _splitter});
    }

    function _two(IStageAction _action0, ISplitter _splitter0, IStageAction _action1, ISplitter _splitter1)
        internal
        pure
        returns (Stage[] memory _flow)
    {
        _flow = new Stage[](2);
        _flow[0] = Stage({action: _action0, splitter: _splitter0});
        _flow[1] = Stage({action: _action1, splitter: _splitter1});
    }
}
```

**Step 2: Replace `test/mocks/BadComponents.sol`**

`FalseReturnToken` and `DuplicateRecipientSplitter` are used from Task 2 on.

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IBudget} from "../../src/interfaces/IBudget.sol";
import {IStageAction} from "../../src/interfaces/IStageAction.sol";
import {ISplitter} from "../../src/interfaces/ISplitter.sol";
import {Plan, Allocation} from "../../src/lib/types.sol";

/// @notice An action that misbehaves in one chosen way
contract BadAction is IStageAction {
    enum Mode {
        Block, // preconditions revert
        Skip, // returns inAmount 0
        TargetDao, // returns an action whose target is the DAO
        Overspend, // claims 1 wei more than its input
        Redirect, // sets a different beneficiary than the one already set
        SwapInputToken, // declares a different input token
        Lie, // declares 10 B of output it never produces
        Drain // declares half the input but transfers all of it away
    }

    address internal constant THIEF = address(0xBEEF);

    error Blocked();

    Mode public immutable mode;
    address public immutable dao;
    IERC20 public immutable tokenB;

    constructor(Mode _mode, address _dao, IERC20 _tokenB) {
        (mode, dao, tokenB) = (_mode, _dao, _tokenB);
    }

    function budget() external pure returns (IBudget) {}

    function preconditions(address, Plan calldata) external view {
        if (mode == Mode.Block) revert Blocked();
    }

    function build(address, bytes calldata, Plan calldata _draft)
        external
        view
        returns (Plan memory _plan, Action[] memory _actions)
    {
        if (mode == Mode.Skip) return (_plan, _actions);

        _plan = _draft;
        if (mode == Mode.Overspend) _plan.inAmount += 1;
        if (mode == Mode.Redirect) _plan.beneficiary = THIEF;
        if (mode == Mode.SwapInputToken) _plan.inToken = IERC20(THIEF);
        if (mode == Mode.Lie) (_plan.outToken, _plan.outAmount) = (tokenB, 10 ether);
        if (mode == Mode.TargetDao) {
            _actions = new Action[](1);
            _actions[0] = Action({to: dao, value: 0, data: ""});
        }
        if (mode == Mode.Drain) {
            (_plan.inAmount, _plan.outAmount) = (_draft.inAmount / 2, 0);
            _actions = new Action[](1);
            _actions[0] = Action({
                to: address(_draft.inToken), value: 0, data: abi.encodeCall(IERC20.transfer, (THIEF, _draft.inAmount))
            });
        }
    }

    function postconditions(address, Plan calldata) external pure returns (Action[] memory) {}
}

/// @notice A splitter that allocates 1 wei more than the output
contract OverAllocatingSplitter is ISplitter {
    function split(Plan calldata _plan) external pure returns (Allocation[] memory _allocations) {
        _allocations = new Allocation[](1);
        _allocations[0] = Allocation({recipient: address(0xBEEF), amount: _plan.outAmount + 1});
    }
}

/// @notice Lists the same recipient twice, splitting the output 50/50 between the two entries
contract DuplicateRecipientSplitter is ISplitter {
    address public immutable recipient;

    constructor(address _recipient) {
        recipient = _recipient;
    }

    function split(Plan calldata _plan) external view returns (Allocation[] memory _allocations) {
        _allocations = new Allocation[](2);
        _allocations[0] = Allocation({recipient: recipient, amount: _plan.outAmount / 2});
        _allocations[1] = Allocation({recipient: recipient, amount: _plan.outAmount - _plan.outAmount / 2});
    }
}

/// @notice USDT-family failure mode: after `successfulTransfers` transfers, `transfer` returns
///         false without moving anything
contract FalseReturnToken is ERC20 {
    uint256 public successfulTransfers;

    constructor(uint256 _successfulTransfers) ERC20("False", "FALSE") {
        successfulTransfers = _successfulTransfers;
    }

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }

    function transfer(address _to, uint256 _amount) public override returns (bool) {
        if (successfulTransfers == 0) return false;
        --successfulTransfers;
        return super.transfer(_to, _amount);
    }
}
```

**Step 3: Replace `test/mocks/MockFiller.sol`** (adds `fillWithoutData` for multi-stage flows)

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFiller} from "../../src/interfaces/IFiller.sol";
import {CapitalPipelinePlugin} from "../../src/CapitalPipelinePlugin.sol";

/// @notice Triggers the plugin and fills the offer, delivering `demandedAmount + fillDelta`
contract MockFiller is IFiller {
    CapitalPipelinePlugin public immutable plugin;

    /// @notice Added to the demanded amount when delivering (negative = under-deliver)
    int256 public fillDelta;

    /// @notice When true, tries to re-enter `trigger` from inside the callback
    bool public reenter;

    /// @notice The revert data of the last re-entry attempt
    bytes public reentryError;

    /// @notice Total demanded token delivered to the DAO
    uint256 public totalDelivered;

    constructor(CapitalPipelinePlugin _plugin) {
        plugin = _plugin;
    }

    function setFillDelta(int256 _delta) external {
        fillDelta = _delta;
    }

    function setReenter(bool _reenter) external {
        reenter = _reenter;
    }

    /// @notice This contract becomes the trigger caller, so the DAO calls it back
    function fill(bytes memory _data) external {
        bytes[] memory _perStep = new bytes[](1);
        _perStep[0] = _data;
        plugin.trigger(_perStep);
    }

    /// @notice Triggers with no data at all, which works for flows of any length
    function fillWithoutData() external {
        plugin.trigger(new bytes[](0));
    }

    function fillOffer(
        IERC20 _offeredToken,
        uint256 _offeredAmount,
        IERC20 _demandedToken,
        uint256 _demandedAmount,
        bytes calldata
    ) external {
        if (reenter) {
            try plugin.trigger(new bytes[](0)) {}
            catch (bytes memory _reason) {
                reentryError = _reason;
            }
        }

        _offeredToken.transferFrom(msg.sender, address(this), _offeredAmount);

        uint256 _amount = uint256(int256(_demandedAmount) + fillDelta);
        _demandedToken.transfer(msg.sender, _amount);
        totalDelivered += _amount;
    }
}
```

**Step 4: Replace `test/CapitalPipelinePlugin.t.sol`**

```solidity
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
import {IStageAction} from "../src/interfaces/IStageAction.sol";
import {Stage} from "../src/lib/types.sol";
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

    // Helpers

    function _bad(BadAction.Mode _mode) internal returns (IStageAction) {
        return new BadAction(_mode, address(dao), tokenB);
    }

    function _clone() internal returns (CapitalPipelinePlugin) {
        return CapitalPipelinePlugin(ProxyLib.deployMinimalProxy(address(new CapitalPipelinePlugin()), ""));
    }
}
```

**Step 5: Replace `test/RatioSplitter.t.sol`**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {DaoUnauthorized} from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import {RatioSplitter} from "../src/splitters/RatioSplitter.sol";
import {Allocation, Plan} from "../src/lib/types.sol";
import {MANAGER_PERMISSION_ID, RATIO_BASE} from "../src/lib/constants.sol";
import {Fixture} from "./helpers/Fixture.sol";

contract RatioSplitterTest is Fixture {
    RatioSplitter internal splitter;

    function setUp() public override {
        super.setUp();
        splitter = _deploySplitter();
    }

    function test_SplitsNinetyFiveFive() public view {
        Allocation[] memory _allocations = splitter.split(_output(1000 ether));

        assertEq(_allocations.length, 2);
        assertEq(_allocations[0].recipient, BURN);
        assertEq(_allocations[0].amount, 950 ether);
        assertEq(_allocations[1].recipient, fee);
        assertEq(_allocations[1].amount, 50 ether);
    }

    function test_RemainderGoesToLargestShare() public view {
        Allocation[] memory _allocations = splitter.split(_output(1)); // both shares round down to 0

        assertEq(_allocations[0].amount, 1);
        assertEq(_allocations[1].amount, 0);
    }

    function testFuzz_AllocationsSumToAmount(uint256 _amount, uint256 _ratio) public {
        _amount = bound(_amount, 0, type(uint128).max);
        _ratio = bound(_ratio, 0, RATIO_BASE);
        _set(uint32(_ratio), uint32(RATIO_BASE - _ratio));

        Allocation[] memory _allocations = splitter.split(_output(_amount));

        assertEq(_allocations[0].amount + _allocations[1].amount, _amount);
    }

    function test_ManagerReplacesRecipients() public {
        _set(500_000, 500_000);

        Allocation[] memory _allocations = splitter.split(_output(10));
        assertEq(_allocations[0].amount, 5);
        assertEq(_allocations[1].amount, 5);
    }

    function test_RevertWhen_RatiosDoNotSumToBase() public {
        vm.expectRevert(RatioSplitter.InvalidRatios.selector);
        _set(500_000, 400_000);
    }

    function test_RevertWhen_LengthMismatch() public {
        vm.expectRevert(RatioSplitter.LengthMismatch.selector);
        vm.prank(manager);
        splitter.setRecipients(new address[](2), new uint32[](1));
    }

    function test_RevertWhen_NoRecipients() public {
        vm.expectRevert(RatioSplitter.NoRecipients.selector);
        vm.prank(manager);
        splitter.setRecipients(new address[](0), new uint32[](0));
    }

    function test_RevertWhen_ZeroRecipient() public {
        uint32[] memory _ratios = new uint32[](1);
        _ratios[0] = uint32(RATIO_BASE);

        vm.expectRevert(RatioSplitter.ZeroRecipient.selector);
        vm.prank(manager);
        splitter.setRecipients(new address[](1), _ratios);
    }

    function test_RevertWhen_SetRecipientsUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector, address(dao), address(splitter), address(this), MANAGER_PERMISSION_ID
            )
        );
        splitter.setRecipients(new address[](0), new uint32[](0));
    }

    function _output(uint256 _amount) internal view returns (Plan memory) {
        return Plan({inToken: tokenB, inAmount: 0, outToken: tokenB, outAmount: _amount, beneficiary: address(0)});
    }

    function _set(uint32 _burnRatio, uint32 _feeRatio) internal {
        address[] memory _recipients = new address[](2);
        (_recipients[0], _recipients[1]) = (BURN, fee);
        uint32[] memory _ratios = new uint32[](2);
        (_ratios[0], _ratios[1]) = (_burnRatio, _feeRatio);

        vm.prank(manager);
        splitter.setRecipients(_recipients, _ratios);
    }
}
```

**Step 6: Replace `test/OpenFillAction.t.sol`**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {DaoUnauthorized} from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {FundedStreamBudget} from "../src/budgets/FundedStreamBudget.sol";
import {OpenFillAction} from "../src/actions/OpenFillAction.sol";
import {IFiller} from "../src/interfaces/IFiller.sol";
import {Plan} from "../src/lib/types.sol";
import {MANAGER_PERMISSION_ID} from "../src/lib/constants.sol";
import {Fixture} from "./helpers/Fixture.sol";

contract OpenFillActionTest is Fixture {
    FundedStreamBudget internal budget;
    OpenFillAction internal action;
    address internal filler = makeAddr("filler");

    function setUp() public override {
        super.setUp();
        budget = _deployBudget(RATE, 0);
        action = _deployAction(budget);
    }

    function test_MaxOfferedHoldsTheMinimumPrice() public view {
        assertEq(action.maxOffered(), 20 ether); // 1000 B / 50 B-per-A
    }

    function test_BuildCapsTheOfferAtMaxOffered() public view {
        (Plan memory _plan,) = action.build(filler, "", _draft(50 ether));

        assertEq(_plan.inAmount, 20 ether);
        assertEq(address(_plan.outToken), address(tokenB));
        assertEq(_plan.outAmount, DEMAND);
        assertEq(_plan.beneficiary, alice, "carries the beneficiary on");
    }

    function test_BuildApprovesCallsBackAndClearsApproval() public view {
        (, Action[] memory _actions) = action.build(filler, "solver-data", _draft(10 ether));

        assertEq(_actions.length, 3);
        assertEq(_actions[0].to, address(tokenA));
        assertEq(_actions[0].data, abi.encodeCall(IERC20.approve, (filler, 10 ether)));
        assertEq(_actions[1].to, filler);
        assertEq(
            _actions[1].data,
            abi.encodeCall(IFiller.fillOffer, (IERC20(tokenA), 10 ether, IERC20(tokenB), DEMAND, "solver-data"))
        );
        assertEq(_actions[2].to, address(tokenA));
        assertEq(_actions[2].data, abi.encodeCall(IERC20.approve, (filler, 0)));
    }

    function test_BuildReturnsNothingForAnEmptyBudget() public view {
        (Plan memory _plan, Action[] memory _actions) = action.build(filler, "", _draft(0));

        assertEq(_plan.inAmount, 0);
        assertEq(_actions.length, 0);
    }

    function test_PostconditionsAssertTheDaoReceivedTheDemand() public view {
        (Plan memory _plan,) = action.build(filler, "", _draft(10 ether));
        Action[] memory _checks = action.postconditions(filler, _plan);

        assertEq(_checks.length, 1);
        assertEq(_checks[0].to, address(action));
        assertEq(_checks[0].data, abi.encodeCall(action.assertReceived, (IERC20(tokenB), DAO_B + DEMAND)));
    }

    function test_RevertWhen_DemandNotReceived() public {
        vm.expectRevert(abi.encodeWithSelector(OpenFillAction.DemandNotMet.selector, DAO_B + DEMAND, DAO_B));
        action.assertReceived(tokenB, DAO_B + DEMAND);
    }

    function test_SetDemandPerFillRestartsTheAuction() public {
        vm.warp(block.timestamp + EPOCH);
        assertEq(budget.available(), RATE);

        vm.prank(manager);
        action.setDemandPerFill(500 ether);

        assertEq(action.demandPerFill(), 500 ether);
        assertEq(budget.available(), 0);
    }

    function test_SetMinDemandedPerOfferedRestartsTheAuction() public {
        vm.warp(block.timestamp + EPOCH);

        vm.prank(manager);
        action.setMinDemandedPerOffered(25 ether);

        assertEq(action.maxOffered(), 40 ether);
        assertEq(budget.available(), 0);
    }

    function test_RevertWhen_SetterUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector, address(dao), address(action), address(this), MANAGER_PERMISSION_ID
            )
        );
        action.setDemandPerFill(1);
    }

    function test_RevertWhen_DemandedTokenIsOfferedToken() public {
        OpenFillAction _action = _clone();
        vm.expectRevert(OpenFillAction.SameToken.selector);
        _action.initialize(dao, budget, tokenA, DEMAND, MIN_PRICE);
    }

    function test_RevertWhen_DemandedTokenHasNoCode() public {
        OpenFillAction _action = _clone();
        vm.expectRevert(OpenFillAction.InvalidToken.selector);
        _action.initialize(dao, budget, IERC20(address(0)), DEMAND, MIN_PRICE);
    }

    function test_RevertWhen_ZeroDemand() public {
        vm.expectRevert(OpenFillAction.ZeroDemand.selector);
        vm.prank(manager);
        action.setDemandPerFill(0);
    }

    function test_RevertWhen_ZeroMinimumPrice() public {
        vm.expectRevert(OpenFillAction.ZeroMinDemandedPerOffered.selector);
        vm.prank(manager);
        action.setMinDemandedPerOffered(0);
    }

    function test_RevertWhen_MinimumPriceTooHigh() public {
        vm.expectRevert(OpenFillAction.MinDemandedPerOfferedTooHigh.selector);
        vm.prank(manager);
        action.setMinDemandedPerOffered(DEMAND * 1e18 + 1);
    }

    function _draft(uint256 _available) internal view returns (Plan memory) {
        return
            Plan({inToken: tokenA, inAmount: _available, outToken: tokenA, outAmount: _available, beneficiary: alice});
    }

    function _clone() internal returns (OpenFillAction) {
        return OpenFillAction(ProxyLib.deployMinimalProxy(address(new OpenFillAction()), ""));
    }
}
```

**Step 7: Replace `test/invariant/PipelineInvariant.t.sol`**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {FundedStreamBudget} from "../../src/budgets/FundedStreamBudget.sol";
import {OpenFillAction} from "../../src/actions/OpenFillAction.sol";
import {CapitalPipelinePlugin} from "../../src/CapitalPipelinePlugin.sol";
import {Fixture} from "../helpers/Fixture.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockFiller} from "../mocks/MockFiller.sol";

/// @notice Random fills, deposits, syncs and manager tweaks. No call may revert.
/// @dev Read anything a bound needs before `vm.prank`: the prank applies to the very next call.
contract Handler is Test {
    FundedStreamBudget internal budget;
    OpenFillAction internal action;
    MockFiller internal filler;
    ERC20Mock internal tokenA;
    address internal dao;
    address internal manager;

    constructor(
        FundedStreamBudget _budget,
        OpenFillAction _action,
        MockFiller _filler,
        ERC20Mock _tokenA,
        address _dao,
        address _manager
    ) {
        (budget, action, filler, tokenA, dao, manager) = (_budget, _action, _filler, _tokenA, _dao, _manager);
    }

    function warp(uint256 _seconds) external {
        vm.warp(block.timestamp + bound(_seconds, 0, 30 days));
    }

    function fill() external {
        filler.fill("");
    }

    function deposit(uint256 _amount) external {
        tokenA.mint(dao, bound(_amount, 0, 1_000 ether));
    }

    function sync() external {
        budget.sync();
    }

    function setAmountPerEpoch(uint256 _rate) external {
        vm.prank(manager);
        budget.setAmountPerEpoch(bound(_rate, 0, 1_000 ether));
    }

    function setMaxBudget(uint256 _max) external {
        vm.prank(manager);
        budget.setMaxBudget(bound(_max, 0, 1_000 ether));
    }

    function setDemandPerFill(uint256 _demand) external {
        uint256 _lowest = action.minDemandedPerOffered() / 1e18 + 1; // keeps maxOffered() >= 1
        vm.prank(manager);
        action.setDemandPerFill(bound(_demand, _lowest, 2_000_000 ether));
    }

    function setMinDemandedPerOffered(uint256 _price) external {
        uint256 _highest = action.demandPerFill() * 1e18; // keeps maxOffered() >= 1
        vm.prank(manager);
        action.setMinDemandedPerOffered(bound(_price, 1, _highest));
    }
}

contract PipelineInvariantTest is Fixture {
    MockFiller internal filler;

    function setUp() public override {
        super.setUp();
        FundedStreamBudget _budget = _deployBudget(RATE, 0);
        OpenFillAction _action = _deployAction(_budget);
        CapitalPipelinePlugin _plugin = _deployPlugin(_budget, _one(_action, _deploySplitter()));

        filler = new MockFiller(_plugin);
        tokenB.mint(address(filler), type(uint128).max);

        targetContract(address(new Handler(_budget, _action, filler, tokenA, address(dao), manager)));
    }

    function invariant_DaoNeverSpendsItsPreexistingB() public view {
        assertEq(tokenB.balanceOf(address(dao)), DAO_B);
    }

    function invariant_ProceedsAreSplitExactly() public view {
        assertEq(tokenB.balanceOf(BURN) + tokenB.balanceOf(fee), filler.totalDelivered());
    }

    function invariant_NoApprovalSurvives() public view {
        assertEq(tokenA.allowance(address(dao), address(filler)), 0);
    }
}
```

**Step 8: Run the tests to make sure they fail**

Run: `forge test`
Expected: compilation fails with `Source "src/interfaces/IStageAction.sol" not found`

**Step 9: Replace `src/lib/types.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStageAction} from "../interfaces/IStageAction.sol";
import {ISplitter} from "../interfaces/ISplitter.sol";

/// @notice What a stage spends and what it produces. Passed from component to component and,
///         as the leftover, from stage to stage.
/// @param beneficiary Who the flowing amount belongs to, once an action sets it (e.g. a Merkle
///        claim). Carried to later stages; it can't be changed once set.
struct Plan {
    IERC20 inToken;
    uint256 inAmount;
    IERC20 outToken;
    uint256 outAmount;
    address beneficiary;
}

/// @notice An amount of a stage's output for one recipient. An allocation to the DAO itself is
///         kept for the next stage instead of transferred.
struct Allocation {
    address recipient;
    uint256 amount;
}

/// @notice One stage of a flow. Either may be address(0), not both.
struct Stage {
    IStageAction action;
    ISplitter splitter;
}
```

**Step 10: Create `src/interfaces/IStageAction.sol` and delete the old interface**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IBudget} from "./IBudget.sol";
import {Plan} from "../lib/types.sol";

/// @title IStageAction
/// @notice Converts a stage's input into its output. The plugin calls all three hooks, in order,
///         on every stage that has an action, so an action's safety checks can't be left out.
interface IStageAction {
    /// @notice The budget this action is bound to, or address(0) if it works with any input.
    ///         A bound action can only be the first stage of a flow on that budget.
    function budget() external view returns (IBudget);

    /// @notice Reverts if the action must not run
    function preconditions(address caller, Plan calldata draft) external view;

    /// @notice Caps `inAmount`, sets `outToken`/`outAmount` (and optionally `beneficiary`),
    ///         returns the actions that do the work. Returning `inAmount == 0` skips the stage.
    /// @dev `outAmount` must be known here: the splitter divides it before anything executes
    function build(address caller, bytes calldata data, Plan calldata draft)
        external
        view
        returns (Plan memory plan, Action[] memory actions);

    /// @notice The checks that make the work safe, executed by the DAO right after it
    function postconditions(address caller, Plan calldata plan) external view returns (Action[] memory);
}
```

```bash
git rm src/interfaces/IStepAction.sol
```

**Step 11: Replace `src/interfaces/ISplitter.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Allocation, Plan} from "../lib/types.sol";

/// @title ISplitter
/// @notice Divides a stage's output among recipients
interface ISplitter {
    /// @notice Allocations of `plan.outAmount`. The plugin rejects allocations that add up to more.
    ///         Whatever isn't transferred out (including allocations to the DAO) passes to the next stage.
    function split(Plan calldata plan) external view returns (Allocation[] memory);
}
```

**Step 12: Replace `src/actions/OpenFillAction.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {
    DaoAuthorizableUpgradeable
} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizableUpgradeable.sol";
import {IStageAction} from "../interfaces/IStageAction.sol";
import {IBudget, ICheckpointedBudget} from "../interfaces/IBudget.sol";
import {IFiller} from "../interfaces/IFiller.sol";
import {Plan} from "../lib/types.sol";
import {MANAGER_PERMISSION_ID, EXCHANGE_RATE_SCALE} from "../lib/constants.sol";

/// @title OpenFillAction
/// @notice Take-it-or-leave-it swap priced as a Dutch auction. The bound budget grows the offer
///         from zero; the DAO demands a flat `demandPerFill` back; any filler can take it.
/// @dev The price obtained is `demandPerFill / offered`, so it worsens as the offer grows.
///      `maxOffered()` caps the offer at `demandPerFill / minDemandedPerOffered`, which holds the
///      worst acceptable price. Price terms are 1e18-scaled: `demanded_raw * 1e18 / offered_raw`.
///      Changing either price term restarts the auction, so a filler cannot take an offer that
///      accumulated under the old terms at the new price.
contract OpenFillAction is IStageAction, Initializable, DaoAuthorizableUpgradeable {
    /// @inheritdoc IStageAction
    IBudget public budget;

    /// @notice The token the DAO must receive back
    IERC20 public demandedToken;

    /// @notice How much of the demanded token must come back per fill
    uint256 public demandPerFill;

    /// @notice The lowest acceptable price, 1e18-scaled demanded per offered
    uint256 public minDemandedPerOffered;

    /// @notice Emitted when the price terms are set or updated
    event TermsUpdated(uint256 demandPerFill, uint256 minDemandedPerOffered);

    /// @notice Thrown when the budget is address(0)
    error NoBudget();

    /// @notice Thrown when the demanded token has no code (includes native ETH, unsupported in v1)
    error InvalidToken();

    /// @notice Thrown when the demanded token is the budget's token
    error SameToken();

    /// @notice Thrown when the demand is zero (it would give the offered token away)
    error ZeroDemand();

    /// @notice Thrown when no minimum price is given
    error ZeroMinDemandedPerOffered();

    /// @notice Thrown when the minimum price is so high that not even 1 wei could be offered
    error MinDemandedPerOfferedTooHigh();

    /// @notice Thrown when the DAO holds less of the demanded token than the fill requires
    error DemandNotMet(uint256 required, uint256 actual);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param _dao The DAO executing the fills
    /// @param _budget The budget growing the offer; this action restarts it when terms change
    /// @param _demandedToken The token the DAO must receive back (ERC20 only)
    /// @param _demandPerFill How much of the demanded token must come back per fill
    /// @param _minDemandedPerOffered The lowest acceptable price, 1e18-scaled
    function initialize(
        IDAO _dao,
        ICheckpointedBudget _budget,
        IERC20 _demandedToken,
        uint256 _demandPerFill,
        uint256 _minDemandedPerOffered
    ) external initializer {
        if (address(_budget) == address(0)) revert NoBudget();
        if (address(_demandedToken).code.length == 0) revert InvalidToken();
        if (_demandedToken == _budget.token()) revert SameToken();

        __DaoAuthorizableUpgradeable_init(_dao);

        budget = _budget;
        demandedToken = _demandedToken;
        _setTerms(_demandPerFill, _minDemandedPerOffered);
    }

    // IStepAction

    /// @inheritdoc IStageAction
    /// @dev None in v1
    function preconditions(address, Plan calldata) external view virtual {}

    /// @inheritdoc IStageAction
    /// @dev Approves the offer to the caller, calls it back, and clears the approval
    function build(address _caller, bytes calldata _data, Plan calldata _draft)
        external
        view
        virtual
        returns (Plan memory _plan, Action[] memory _actions)
    {
        uint256 _offered = Math.min(_draft.inAmount, maxOffered());
        if (_offered == 0) return (_plan, _actions);

        _plan = Plan({
            inToken: _draft.inToken,
            inAmount: _offered,
            outToken: demandedToken,
            outAmount: demandPerFill,
            beneficiary: _draft.beneficiary
        });

        address _in = address(_draft.inToken);
        _actions = new Action[](3);
        _actions[0] = Action({to: _in, value: 0, data: abi.encodeCall(IERC20.approve, (_caller, _offered))});
        _actions[1] = Action({
            to: _caller,
            value: 0,
            data: abi.encodeCall(IFiller.fillOffer, (_draft.inToken, _offered, demandedToken, demandPerFill, _data))
        });
        _actions[2] = Action({to: _in, value: 0, data: abi.encodeCall(IERC20.approve, (_caller, 0))});
    }

    /// @inheritdoc IStageAction
    /// @dev Reverts the whole step unless the DAO received at least `outAmount`
    function postconditions(address, Plan calldata _plan) external view virtual returns (Action[] memory _actions) {
        uint256 _minBalance = _plan.outToken.balanceOf(address(dao())) + _plan.outAmount;

        _actions = new Action[](1);
        _actions[0] = Action({
            to: address(this), value: 0, data: abi.encodeCall(this.assertReceived, (_plan.outToken, _minBalance))
        });
    }

    /// @notice Reverts unless the DAO holds at least `_minBalance` of `_token`
    /// @dev Executed by the DAO as the postcondition of a fill. View, so harmless to call from anywhere.
    function assertReceived(IERC20 _token, uint256 _minBalance) external view virtual {
        uint256 _balance = _token.balanceOf(address(dao()));
        if (_balance < _minBalance) revert DemandNotMet(_minBalance, _balance);
    }

    /// @notice The most the DAO hands over in one fill: `demandPerFill / minDemandedPerOffered`
    /// @dev Rounded down, so the price obtained lands at or above `minDemandedPerOffered`
    function maxOffered() public view virtual returns (uint256) {
        return (demandPerFill * EXCHANGE_RATE_SCALE) / minDemandedPerOffered;
    }

    // Manager settings. Both restart the auction.

    /// @notice Updates how much must come back per fill, and restarts the auction
    function setDemandPerFill(uint256 _demandPerFill) external virtual auth(MANAGER_PERMISSION_ID) {
        _setTerms(_demandPerFill, minDemandedPerOffered);
        _restartAuction();
    }

    /// @notice Updates the lowest acceptable price, and restarts the auction
    function setMinDemandedPerOffered(uint256 _minDemandedPerOffered) external virtual auth(MANAGER_PERMISSION_ID) {
        _setTerms(demandPerFill, _minDemandedPerOffered);
        _restartAuction();
    }

    // Internal

    /// @dev Bound at init to an ICheckpointedBudget, so the cast is safe
    function _restartAuction() internal virtual {
        ICheckpointedBudget(address(budget)).writeCheckpoint();
    }

    function _setTerms(uint256 _demandPerFill, uint256 _minDemandedPerOffered) internal virtual {
        if (_demandPerFill == 0) revert ZeroDemand();
        if (_minDemandedPerOffered == 0) revert ZeroMinDemandedPerOffered();
        // Keeps maxOffered() >= 1, so a zero offer always means an empty budget
        if (_demandPerFill * EXCHANGE_RATE_SCALE < _minDemandedPerOffered) revert MinDemandedPerOfferedTooHigh();

        demandPerFill = _demandPerFill;
        minDemandedPerOffered = _minDemandedPerOffered;

        emit TermsUpdated(_demandPerFill, _minDemandedPerOffered);
    }
}
```

**Step 13: Replace `src/splitters/RatioSplitter.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {
    DaoAuthorizableUpgradeable
} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizableUpgradeable.sol";
import {ISplitter} from "../interfaces/ISplitter.sol";
import {Allocation, Plan} from "../lib/types.sol";
import {MANAGER_PERMISSION_ID, RATIO_BASE} from "../lib/constants.sol";

/// @title RatioSplitter
/// @notice Splits an amount by fixed ratios (fractions of RATIO_BASE)
/// @dev The rounding remainder goes to the largest share, so allocations sum to exactly `amount`.
contract RatioSplitter is ISplitter, Initializable, DaoAuthorizableUpgradeable {
    address[] internal _recipients;
    uint32[] internal _ratios;

    /// @notice Emitted when recipients or ratios change
    event RecipientsUpdated(address[] recipients, uint32[] ratios);

    error NoRecipients();
    error LengthMismatch();
    error ZeroRecipient();
    error InvalidRatios();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IDAO _dao, address[] calldata _newRecipients, uint32[] calldata _newRatios)
        external
        initializer
    {
        __DaoAuthorizableUpgradeable_init(_dao);
        _setRecipients(_newRecipients, _newRatios);
    }

    /// @inheritdoc ISplitter
    function split(Plan calldata _plan) external view virtual returns (Allocation[] memory _allocations) {
        uint256 _amount = _plan.outAmount;
        uint256 _len = _recipients.length;
        _allocations = new Allocation[](_len);

        uint256 _assigned;
        uint256 _largest;
        for (uint256 i; i < _len; ++i) {
            uint256 _share = (_amount * _ratios[i]) / RATIO_BASE;
            _allocations[i] = Allocation({recipient: _recipients[i], amount: _share});
            _assigned += _share;
            if (_ratios[i] > _ratios[_largest]) _largest = i;
        }
        _allocations[_largest].amount += _amount - _assigned;
    }

    /// @notice Replaces recipients and ratios. Safe at any time: a sweep keeps no memory.
    function setRecipients(address[] calldata _newRecipients, uint32[] calldata _newRatios)
        external
        virtual
        auth(MANAGER_PERMISSION_ID)
    {
        _setRecipients(_newRecipients, _newRatios);
    }

    function recipients() external view returns (address[] memory, uint32[] memory) {
        return (_recipients, _ratios);
    }

    function _setRecipients(address[] calldata _newRecipients, uint32[] calldata _newRatios) internal virtual {
        if (_newRecipients.length == 0) revert NoRecipients();
        if (_newRecipients.length != _newRatios.length) revert LengthMismatch();

        uint256 _sum;
        for (uint256 i; i < _newRecipients.length; ++i) {
            if (_newRecipients[i] == address(0)) revert ZeroRecipient();
            _sum += _newRatios[i];
        }
        if (_sum != RATIO_BASE) revert InvalidRatios();

        _recipients = _newRecipients;
        _ratios = _newRatios;

        emit RecipientsUpdated(_newRecipients, _newRatios);
    }
}
```

**Step 14: Replace `src/CapitalPipelinePlugin.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {IExecutor, Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {PluginCloneable} from "@aragon/osx-commons-contracts/src/plugin/PluginCloneable.sol";
import {IBudget} from "./interfaces/IBudget.sol";
import {ISplitter} from "./interfaces/ISplitter.sol";
import {Plan, Allocation, Stage} from "./lib/types.sol";
import {TRIGGER_PERMISSION_ID, CONFIGURE_PERMISSION_ID, MANAGER_PERMISSION_ID} from "./lib/constants.sol";

/// @title CapitalPipelinePlugin
/// @notice Runs one flow: the budget is read once, then each stage runs its action
///         (preconditions → build → postconditions) and its splitter, and passes what it didn't
///         transfer out to the next stage. The budget commits once, after the last stage.
/// @dev Each stage is planned (view) right before it executes in its own `dao.execute`, so it
///      always sees real balances. After every stage the plugin checks balances: each recipient
///      received its allocation, the DAO received the declared output, and the DAO spent no more
///      than the declared input. That makes each stage's leftover safe for the next stage to spend.
contract CapitalPipelinePlugin is PluginCloneable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    /// @dev Balances taken right before a stage executes
    struct Snapshot {
        uint256 inBalance;
        uint256 outBalance;
        uint256 transferred;
        uint256 recipientCount;
        address[] recipients;
        uint256[] expected;
    }

    /// @notice What the flow may spend; read at the start, committed at the end
    IBudget public budget;

    Stage[] internal _stages;

    /// @dev Makes every execution ID unique
    uint256 internal _nonce;

    event FlowUpdated(IBudget budget, Stage[] stages);
    event StageExecuted(uint256 indexed stageIndex, address indexed caller, bytes32 executionId, Plan plan);
    event BudgetCommitted(bytes32 executionId);

    error NoBudget();
    error NoStages();
    error EmptyStage(uint256 stageIndex);
    error BudgetMismatch(uint256 stageIndex);
    error DataLengthMismatch(uint256 expected, uint256 actual);
    error InputTokenMismatch(uint256 stageIndex);
    error InAmountExceedsInput(uint256 stageIndex, uint256 inAmount, uint256 input);
    error BeneficiaryChanged(uint256 stageIndex);
    error AllocationExceedsOutput(uint256 stageIndex, uint256 allocated, uint256 outAmount);
    error InvalidOutToken(uint256 stageIndex);
    error ActionTargetsDao(uint256 stageIndex, uint256 actionIndex);
    error UnexpectedBalance(uint256 stageIndex, address account, address token, uint256 expected, uint256 actual);

    function initialize(IDAO _dao, IBudget _budget, Stage[] calldata _newStages) external initializer {
        __PluginCloneable_init(_dao);
        __Pausable_init();
        __ReentrancyGuard_init();
        _setFlow(_budget, _newStages);
    }

    /// @notice Runs the flow
    /// @param _data Empty, or one entry per stage (passed to that stage's action)
    function trigger(bytes[] calldata _data) external nonReentrant whenNotPaused auth(TRIGGER_PERMISSION_ID) {
        uint256 _len = _stages.length;
        if (_data.length != 0 && _data.length != _len) revert DataLengthMismatch(_len, _data.length);

        uint256 _callNonce = _nonce++;
        IERC20 _token = budget.token();
        uint256 _available = budget.available();
        Plan memory _input = Plan(_token, _available, _token, _available, address(0));
        Plan memory _first;

        for (uint256 i; i < _len && _input.inAmount != 0; ++i) {
            Plan memory _plan;
            (_plan, _input) = _runStage(i, _input, _data.length == 0 ? msg.data[0:0] : _data[i], _callNonce);
            if (_plan.inAmount == 0) break; // this stage and the rest are skipped
            if (i == 0) _first = _plan;
        }

        // The budget is consumed once the first stage ran. A skipped first stage leaves it untouched.
        if (_first.inAmount != 0) _commitBudget(_first, _callNonce);
    }

    /// @notice Replaces the flow. DAO only: an action can return arbitrary DAO actions.
    function setFlow(IBudget _budget, Stage[] calldata _newStages) external auth(CONFIGURE_PERMISSION_ID) {
        _setFlow(_budget, _newStages);
    }

    /// @notice Stops the flow until `unpause`
    function pause() external auth(MANAGER_PERMISSION_ID) {
        _pause();
    }

    /// @notice Resumes the flow
    function unpause() external auth(MANAGER_PERMISSION_ID) {
        _unpause();
    }

    function stages() external view returns (Stage[] memory) {
        return _stages;
    }

    // Stage execution

    /// @return _plan What the stage did (`inAmount == 0` if it was skipped)
    /// @return _next The next stage's input: what this stage produced and didn't transfer out
    function _runStage(uint256 _index, Plan memory _draft, bytes calldata _data, uint256 _callNonce)
        internal
        returns (Plan memory _plan, Plan memory _next)
    {
        Action[] memory _actions;
        Allocation[] memory _transfers;
        (_plan, _actions, _transfers) = _planStage(_index, _stages[_index], _draft, _data);
        if (_plan.inAmount == 0) return (_plan, _next);

        Snapshot memory _before = _snapshot(_plan, _transfers);

        bytes32 _executionId = keccak256(abi.encode(address(this), _callNonce, _index));
        _execute(_index, _actions, _executionId);
        _verify(_index, _plan, _before);

        uint256 _leftover = _plan.outAmount - _before.transferred;
        _next = Plan(_plan.outToken, _leftover, _plan.outToken, _leftover, _plan.beneficiary);

        emit StageExecuted(_index, msg.sender, _executionId, _plan);
    }

    /// @dev Calls the stage's components in order and concatenates their actions
    function _planStage(uint256 _index, Stage memory _stage, Plan memory _draft, bytes calldata _data)
        internal
        view
        returns (Plan memory _plan, Action[] memory _actions, Allocation[] memory _transfers)
    {
        _plan = _draft;
        Action[] memory _work;
        Action[] memory _checks;

        if (address(_stage.action) != address(0)) {
            _stage.action.preconditions(msg.sender, _draft);
            (_plan, _work) = _stage.action.build(msg.sender, _data, _draft);
            if (_plan.inAmount == 0) return (_plan, _actions, _transfers);

            if (_plan.inToken != _draft.inToken) revert InputTokenMismatch(_index);
            _plan.beneficiary = _keepBeneficiary(_index, _draft.beneficiary, _plan.beneficiary);
            _checks = _stage.action.postconditions(msg.sender, _plan);
        }
        if (_plan.inAmount > _draft.inAmount) revert InAmountExceedsInput(_index, _plan.inAmount, _draft.inAmount);
        if (_plan.outAmount != 0 && address(_plan.outToken).code.length == 0) revert InvalidOutToken(_index);

        _transfers = _split(_index, _stage.splitter, _plan);
        _actions = _concat(_work, _checks, _transferActions(_plan.outToken, _transfers));
    }

    /// @dev Non-zero allocations to anyone but the DAO. Allocations to the DAO stay as leftover.
    function _split(uint256 _index, ISplitter _splitter, Plan memory _plan)
        internal
        view
        returns (Allocation[] memory _transfers)
    {
        if (address(_splitter) == address(0) || _plan.outAmount == 0) return _transfers;

        Allocation[] memory _allocations = _splitter.split(_plan);
        address _dao = address(dao());

        uint256 _total;
        uint256 _count;
        for (uint256 i; i < _allocations.length; ++i) {
            _total += _allocations[i].amount;
            if (_allocations[i].amount != 0 && _allocations[i].recipient != _dao) ++_count;
        }
        if (_total > _plan.outAmount) revert AllocationExceedsOutput(_index, _total, _plan.outAmount);

        _transfers = new Allocation[](_count);
        uint256 _j;
        for (uint256 i; i < _allocations.length; ++i) {
            if (_allocations[i].amount != 0 && _allocations[i].recipient != _dao) _transfers[_j++] = _allocations[i];
        }
    }

    function _execute(uint256 _index, Action[] memory _actions, bytes32 _executionId) internal {
        if (_actions.length == 0) return;

        address _dao = address(dao());
        for (uint256 i; i < _actions.length; ++i) {
            if (_actions[i].to == _dao) revert ActionTargetsDao(_index, i);
        }
        IExecutor(_dao).execute(_executionId, _actions, 0);
    }

    function _commitBudget(Plan memory _first, uint256 _callNonce) internal {
        Action[] memory _actions = budget.commitActions(_first);
        if (_actions.length == 0) return;

        bytes32 _executionId = keccak256(abi.encode(address(this), _callNonce, type(uint256).max));
        _execute(_stages.length, _actions, _executionId);
        emit BudgetCommitted(_executionId);
    }

    // Balance checks

    /// @dev Records the DAO's in/out balances and, per unique recipient, the balance it must reach
    function _snapshot(Plan memory _plan, Allocation[] memory _transfers) internal view returns (Snapshot memory _s) {
        address _dao = address(dao());
        _s.inBalance = _plan.inToken.balanceOf(_dao);
        if (_plan.outToken != _plan.inToken && _plan.outAmount != 0) _s.outBalance = _plan.outToken.balanceOf(_dao);

        _s.recipients = new address[](_transfers.length);
        _s.expected = new uint256[](_transfers.length);
        for (uint256 i; i < _transfers.length; ++i) {
            _s.transferred += _transfers[i].amount;

            uint256 k;
            while (k < _s.recipientCount && _s.recipients[k] != _transfers[i].recipient) ++k;
            if (k == _s.recipientCount) {
                _s.recipients[k] = _transfers[i].recipient;
                _s.expected[k] = _plan.outToken.balanceOf(_transfers[i].recipient);
                ++_s.recipientCount;
            }
            _s.expected[k] += _transfers[i].amount;
        }
    }

    function _verify(uint256 _index, Plan memory _plan, Snapshot memory _s) internal view {
        for (uint256 k; k < _s.recipientCount; ++k) {
            uint256 _actual = _plan.outToken.balanceOf(_s.recipients[k]);
            if (_actual < _s.expected[k]) {
                revert UnexpectedBalance(_index, _s.recipients[k], address(_plan.outToken), _s.expected[k], _actual);
            }
        }

        if (_plan.outToken == _plan.inToken) {
            // One token: it may drop by at most the input, and must gain the output, net of transfers
            _checkDao(_index, _plan.inToken, _s.inBalance + _plan.outAmount, _plan.inAmount + _s.transferred);
        } else {
            _checkDao(_index, _plan.inToken, _s.inBalance, _plan.inAmount);
            if (_plan.outAmount != 0) {
                _checkDao(_index, _plan.outToken, _s.outBalance + _plan.outAmount, _s.transferred);
            }
        }
    }

    /// @dev Reverts unless `balance + spent >= target`
    function _checkDao(uint256 _index, IERC20 _token, uint256 _target, uint256 _spent) internal view {
        address _dao = address(dao());
        uint256 _actual = _token.balanceOf(_dao);
        if (_actual + _spent < _target) {
            revert UnexpectedBalance(_index, _dao, address(_token), _target > _spent ? _target - _spent : 0, _actual);
        }
    }

    // Helpers

    /// @dev Once set, the beneficiary carries on; an action may leave it unset but not change it
    function _keepBeneficiary(uint256 _index, address _current, address _proposed) internal pure returns (address) {
        if (_current == address(0) || _proposed == _current) return _proposed;
        if (_proposed == address(0)) return _current;
        revert BeneficiaryChanged(_index);
    }

    function _transferActions(IERC20 _token, Allocation[] memory _transfers)
        internal
        pure
        returns (Action[] memory _actions)
    {
        _actions = new Action[](_transfers.length);
        for (uint256 i; i < _transfers.length; ++i) {
            _actions[i] = Action({
                to: address(_token),
                value: 0,
                data: abi.encodeCall(IERC20.transfer, (_transfers[i].recipient, _transfers[i].amount))
            });
        }
    }

    function _concat(Action[] memory _a, Action[] memory _b, Action[] memory _c)
        internal
        pure
        returns (Action[] memory _out)
    {
        _out = new Action[](_a.length + _b.length + _c.length);
        uint256 _k;
        for (uint256 i; i < _a.length; ++i) {
            _out[_k++] = _a[i];
        }
        for (uint256 i; i < _b.length; ++i) {
            _out[_k++] = _b[i];
        }
        for (uint256 i; i < _c.length; ++i) {
            _out[_k++] = _c[i];
        }
    }

    function _setFlow(IBudget _budget, Stage[] calldata _newStages) internal {
        if (address(_budget) == address(0)) revert NoBudget();
        if (_newStages.length == 0) revert NoStages();

        delete _stages;
        for (uint256 i; i < _newStages.length; ++i) {
            Stage calldata _stage = _newStages[i];
            if (address(_stage.action) == address(0) && address(_stage.splitter) == address(0)) revert EmptyStage(i);
            if (address(_stage.action) != address(0)) {
                IBudget _bound = _stage.action.budget();
                if (address(_bound) != address(0) && (i != 0 || _bound != _budget)) revert BudgetMismatch(i);
            }
            _stages.push(_stage);
        }
        budget = _budget;

        emit FlowUpdated(_budget, _newStages);
    }
}
```

**Step 15: Replace `src/setup/CapitalPipelinePluginSetup.sol`**

```solidity
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
import {Stage} from "../lib/types.sol";
import {
    TRIGGER_PERMISSION_ID,
    CONFIGURE_PERMISSION_ID,
    MANAGER_PERMISSION_ID,
    CHECKPOINT_PERMISSION_ID
} from "../lib/constants.sol";

/// @title CapitalPipelinePluginSetup
/// @notice Installs a plugin with a swap-and-split flow: FundedStreamBudget, then one stage of
///         OpenFillAction → RatioSplitter. Deploys every component as a clone bound to the installing DAO.
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

        Stage[] memory _stages = new Stage[](1);
        _stages[0] = Stage({action: OpenFillAction(_helpers[1]), splitter: RatioSplitter(_helpers[2])});

        plugin = ProxyLib.deployMinimalProxy(
            implementation(),
            abi.encodeCall(CapitalPipelinePlugin.initialize, (IDAO(_dao), FundedStreamBudget(_helpers[0]), _stages))
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
```

**Step 16: Run the tests**

Run: `forge test`
Expected: `66 tests passed, 0 failed` (the plugin suite alone: `29 passed`)

Run: `forge fmt --check`
Expected: no output

**Step 17: Commit**

```bash
git add -A src test
git commit -m "Run one flow per plugin: chained stages with balance checks after each

A stage's leftover (output minus transfers) feeds the next stage, and
the budget commits once at the end. After every stage the plugin checks
that recipients received their allocations (summed per recipient), that
the declared output arrived and that no more than the declared input was
spent, so a later stage can never spend treasury holdings. Plans carry a
beneficiary for claim flows; splitters receive the whole plan."
```

---

### Task 2: Merkle claims: BalanceBudget, PayBeneficiary, MerkleClaimAction

**Files:**
- Modify (tests first): `test/helpers/Fixture.sol`, `test/CapitalPipelinePlugin.t.sol`
- Create (tests first): `test/mocks/MockSwap.sol`, `test/BudgetsAndSplitters.t.sol`, `test/MerkleClaimAction.t.sol`
- Create: `src/budgets/BalanceBudget.sol`, `src/splitters/PayBeneficiary.sol`, `src/actions/MerkleClaimAction.sol`

**Step 1: Replace `test/helpers/Fixture.sol`** (adds `_deployBalanceBudget` and `_deployMerkle`)

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {FundedStreamBudget} from "../../src/budgets/FundedStreamBudget.sol";
import {BalanceBudget} from "../../src/budgets/BalanceBudget.sol";
import {RatioSplitter} from "../../src/splitters/RatioSplitter.sol";
import {OpenFillAction} from "../../src/actions/OpenFillAction.sol";
import {MerkleClaimAction} from "../../src/actions/MerkleClaimAction.sol";
import {CapitalPipelinePlugin} from "../../src/CapitalPipelinePlugin.sol";
import {IBudget} from "../../src/interfaces/IBudget.sol";
import {IStageAction} from "../../src/interfaces/IStageAction.sol";
import {ISplitter} from "../../src/interfaces/ISplitter.sol";
import {Stage} from "../../src/lib/types.sol";
import {
    MANAGER_PERMISSION_ID,
    CHECKPOINT_PERMISSION_ID,
    TRIGGER_PERMISSION_ID,
    CONFIGURE_PERMISSION_ID
} from "../../src/lib/constants.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

/// @notice A DAO holding the offered token A and some pre-existing demanded token B.
///         The test contract is the DAO's ROOT, so it can grant permissions directly.
abstract contract Fixture is Test {
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;
    address internal constant ANY_ADDR = address(type(uint160).max);
    IStageAction internal constant NO_ACTION = IStageAction(address(0));
    ISplitter internal constant NO_SPLITTER = ISplitter(address(0));

    uint256 internal constant DAO_A = 100 ether; // offered token held by the DAO
    uint256 internal constant DAO_B = 500 ether; // pre-existing demanded token: must never be spent
    uint256 internal constant RATE = 10 ether; // offer growth per epoch
    uint256 internal constant EPOCH = 1 days;
    uint256 internal constant DEMAND = 1000 ether; // B demanded per fill
    uint256 internal constant MIN_PRICE = 50 ether; // 50 B per A, 1e18-scaled → maxOffered = 20 A

    address internal manager = makeAddr("manager");
    address internal fee = makeAddr("fee");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    DAO internal dao;
    ERC20Mock internal tokenA;
    ERC20Mock internal tokenB;
    bytes[] internal noData;

    function setUp() public virtual {
        vm.warp(1_000_000);

        dao = DAO(
            payable(ProxyLib.deployUUPSProxy(
                    address(new DAO()), abi.encodeCall(DAO.initialize, ("", address(this), address(0), ""))
                ))
        );

        tokenA = new ERC20Mock("Offered", "A");
        tokenB = new ERC20Mock("Demanded", "B");
        tokenA.mint(address(dao), DAO_A);
        tokenB.mint(address(dao), DAO_B);
    }

    // Budgets

    /// @dev Deploy after funding the DAO: the budget records the balance it sees at init
    function _deployBudget(uint256 _rate, uint256 _maxBudget) internal returns (FundedStreamBudget _budget) {
        _budget = FundedStreamBudget(
            ProxyLib.deployMinimalProxy(
                address(new FundedStreamBudget()),
                abi.encodeCall(FundedStreamBudget.initialize, (dao, tokenA, _rate, _maxBudget, EPOCH))
            )
        );
        dao.grant(address(_budget), manager, MANAGER_PERMISSION_ID);
        dao.grant(address(_budget), address(dao), CHECKPOINT_PERMISSION_ID);
    }

    function _deployBalanceBudget(IERC20 _token) internal returns (BalanceBudget _budget) {
        _budget = BalanceBudget(
            ProxyLib.deployMinimalProxy(
                address(new BalanceBudget()), abi.encodeCall(BalanceBudget.initialize, (dao, _token))
            )
        );
    }

    // Splitters

    /// @dev 95% to the burn address, 5% to the fee address
    function _deploySplitter() internal returns (RatioSplitter) {
        return _deployRatio(BURN, 950_000, fee, 50_000);
    }

    function _deployRatio(address _a, uint32 _ratioA, address _b, uint32 _ratioB) internal returns (RatioSplitter) {
        address[] memory _recipients = new address[](2);
        (_recipients[0], _recipients[1]) = (_a, _b);
        uint32[] memory _ratios = new uint32[](2);
        (_ratios[0], _ratios[1]) = (_ratioA, _ratioB);
        return _deployRatio(_recipients, _ratios);
    }

    /// @dev 100% to one recipient
    function _deployRatio(address _recipient) internal returns (RatioSplitter) {
        address[] memory _recipients = new address[](1);
        _recipients[0] = _recipient;
        uint32[] memory _ratios = new uint32[](1);
        _ratios[0] = 1_000_000;
        return _deployRatio(_recipients, _ratios);
    }

    function _deployRatio(address[] memory _recipients, uint32[] memory _ratios)
        internal
        returns (RatioSplitter _splitter)
    {
        _splitter = RatioSplitter(
            ProxyLib.deployMinimalProxy(
                address(new RatioSplitter()), abi.encodeCall(RatioSplitter.initialize, (dao, _recipients, _ratios))
            )
        );
        dao.grant(address(_splitter), manager, MANAGER_PERMISSION_ID);
    }

    // Actions

    /// @dev Bound to `_budget`, which it may restart when its price terms change
    function _deployAction(FundedStreamBudget _budget) internal returns (OpenFillAction _action) {
        _action = OpenFillAction(
            ProxyLib.deployMinimalProxy(
                address(new OpenFillAction()),
                abi.encodeCall(OpenFillAction.initialize, (dao, _budget, tokenB, DEMAND, MIN_PRICE))
            )
        );
        dao.grant(address(_action), manager, MANAGER_PERMISSION_ID);
        dao.grant(address(_budget), address(_action), CHECKPOINT_PERMISSION_ID);
    }

    function _deployMerkle(IBudget _budget, bytes32 _root) internal returns (MerkleClaimAction _merkle) {
        _merkle = MerkleClaimAction(
            ProxyLib.deployMinimalProxy(
                address(new MerkleClaimAction()), abi.encodeCall(MerkleClaimAction.initialize, (dao, _budget, _root))
            )
        );
        dao.grant(address(_merkle), manager, MANAGER_PERMISSION_ID);
    }

    // Plugin

    /// @dev Same grants as CapitalPipelinePluginSetup: anyone triggers, the DAO configures, the manager pauses
    function _deployPlugin(IBudget _budget, Stage[] memory _flow) internal returns (CapitalPipelinePlugin _plugin) {
        _plugin = CapitalPipelinePlugin(
            ProxyLib.deployMinimalProxy(
                address(new CapitalPipelinePlugin()),
                abi.encodeCall(CapitalPipelinePlugin.initialize, (dao, _budget, _flow))
            )
        );
        dao.grant(address(dao), address(_plugin), dao.EXECUTE_PERMISSION_ID());
        dao.grant(address(_plugin), ANY_ADDR, TRIGGER_PERMISSION_ID);
        dao.grant(address(_plugin), address(dao), CONFIGURE_PERMISSION_ID);
        dao.grant(address(_plugin), manager, MANAGER_PERMISSION_ID);
    }

    function _one(IStageAction _action, ISplitter _splitter) internal pure returns (Stage[] memory _flow) {
        _flow = new Stage[](1);
        _flow[0] = Stage({action: _action, splitter: _splitter});
    }

    function _two(IStageAction _action0, ISplitter _splitter0, IStageAction _action1, ISplitter _splitter1)
        internal
        pure
        returns (Stage[] memory _flow)
    {
        _flow = new Stage[](2);
        _flow[0] = Stage({action: _action0, splitter: _splitter0});
        _flow[1] = Stage({action: _action1, splitter: _splitter1});
    }
}
```

**Step 2: Replace `test/CapitalPipelinePlugin.t.sol`** (adds the beneficiary and silent-transfer tests)

```solidity
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
```

**Step 3: Create `test/mocks/MockSwap.sol`**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IBudget} from "../../src/interfaces/IBudget.sol";
import {IStageAction} from "../../src/interfaces/IStageAction.sol";
import {Plan} from "../../src/lib/types.sol";

/// @notice Pulls `amountIn` and pays `amountIn * rate / 1e18` of `tokenOut` from its own balance
contract MockExchange {
    uint256 public immutable rate;

    constructor(uint256 _rate) {
        rate = _rate;
    }

    function swap(IERC20 _tokenIn, uint256 _amountIn, IERC20 _tokenOut, address _recipient) external {
        _tokenIn.transferFrom(msg.sender, address(this), _amountIn);
        _tokenOut.transfer(_recipient, _amountIn * rate / 1e18);
    }
}

/// @notice A chainable swap: converts whatever it receives at the exchange's fixed rate
contract MockSwapAction is IStageAction {
    MockExchange public immutable exchange;
    IERC20 public immutable tokenOut;
    address public immutable dao;

    constructor(MockExchange _exchange, IERC20 _tokenOut, address _dao) {
        (exchange, tokenOut, dao) = (_exchange, _tokenOut, _dao);
    }

    function budget() external pure returns (IBudget) {}

    function preconditions(address, Plan calldata) external pure {}

    function build(address, bytes calldata, Plan calldata _draft)
        external
        view
        returns (Plan memory _plan, Action[] memory _actions)
    {
        uint256 _out = _draft.inAmount * exchange.rate() / 1e18;
        _plan = Plan(_draft.inToken, _draft.inAmount, tokenOut, _out, _draft.beneficiary);

        _actions = new Action[](2);
        _actions[0] =
            Action(address(_draft.inToken), 0, abi.encodeCall(IERC20.approve, (address(exchange), _draft.inAmount)));
        _actions[1] = Action(
            address(exchange), 0, abi.encodeCall(MockExchange.swap, (_draft.inToken, _draft.inAmount, tokenOut, dao))
        );
    }

    function postconditions(address, Plan calldata) external pure returns (Action[] memory) {}
}
```

**Step 4: Create `test/BudgetsAndSplitters.t.sol`**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {BalanceBudget} from "../src/budgets/BalanceBudget.sol";
import {PayBeneficiary} from "../src/splitters/PayBeneficiary.sol";
import {Allocation, Plan} from "../src/lib/types.sol";
import {Fixture} from "./helpers/Fixture.sol";

contract BalanceBudgetTest is Fixture {
    function test_AvailableIsTheDaoBalance() public {
        BalanceBudget _budget = _deployBalanceBudget(tokenA);

        assertEq(_budget.available(), DAO_A);
        assertEq(address(_budget.token()), address(tokenA));
    }

    function test_CommitsNothing() public {
        Plan memory _plan;
        assertEq(_deployBalanceBudget(tokenA).commitActions(_plan).length, 0);
    }

    function test_RevertWhen_TokenHasNoCode() public {
        BalanceBudget _budget = BalanceBudget(ProxyLib.deployMinimalProxy(address(new BalanceBudget()), ""));

        vm.expectRevert(BalanceBudget.InvalidToken.selector);
        _budget.initialize(dao, IERC20(address(0)));
    }
}

contract PayBeneficiaryTest is Fixture {
    PayBeneficiary internal splitter = new PayBeneficiary();

    function test_PaysTheWholeOutputToTheBeneficiary() public view {
        Allocation[] memory _allocations = splitter.split(Plan(tokenA, 5 ether, tokenB, 7 ether, alice));

        assertEq(_allocations.length, 1);
        assertEq(_allocations[0].recipient, alice);
        assertEq(_allocations[0].amount, 7 ether);
    }

    function test_RevertWhen_NoBeneficiary() public {
        vm.expectRevert(PayBeneficiary.NoBeneficiary.selector);
        splitter.split(Plan(tokenA, 5 ether, tokenB, 7 ether, address(0)));
    }
}
```

**Step 5: Create `test/MerkleClaimAction.t.sol`**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {DaoUnauthorized} from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import {CapitalPipelinePlugin} from "../src/CapitalPipelinePlugin.sol";
import {BalanceBudget} from "../src/budgets/BalanceBudget.sol";
import {MerkleClaimAction} from "../src/actions/MerkleClaimAction.sol";
import {PayBeneficiary} from "../src/splitters/PayBeneficiary.sol";
import {MANAGER_PERMISSION_ID} from "../src/lib/constants.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {MockExchange, MockSwapAction} from "./mocks/MockSwap.sol";

/// @notice Two-leaf tree: alice is owed 10 A, bob 30 A (cumulative)
contract MerkleClaimActionTest is Fixture {
    uint256 internal aliceAmount;
    uint256 internal bobAmount;

    BalanceBudget internal budget;
    MerkleClaimAction internal merkle;
    PayBeneficiary internal payBeneficiary;
    CapitalPipelinePlugin internal plugin;

    function setUp() public override {
        super.setUp();
        budget = _deployBalanceBudget(tokenA);
        merkle = _deployMerkle(budget, _root(10 ether, 30 ether));
        payBeneficiary = new PayBeneficiary();
        plugin = _deployPlugin(budget, _one(merkle, payBeneficiary));
    }

    function test_AccountClaimsItsAmount() public {
        vm.prank(alice);
        plugin.trigger(_claim(alice, 10 ether, address(0)));

        assertEq(tokenA.balanceOf(alice), 10 ether);
        assertEq(tokenA.balanceOf(address(dao)), DAO_A - 10 ether);
        assertEq(merkle.claimed(alice), 10 ether);
    }

    function test_SecondClaimPaysNothing() public {
        vm.startPrank(alice);
        plugin.trigger(_claim(alice, 10 ether, address(0)));
        plugin.trigger(_claim(alice, 10 ether, address(0)));
        vm.stopPrank();

        assertEq(tokenA.balanceOf(alice), 10 ether);
    }

    function test_RelayerClaimsForTheAccount() public {
        vm.prank(carol);
        plugin.trigger(_claim(bob, 30 ether, address(0)));

        assertEq(tokenA.balanceOf(bob), 30 ether, "paid to the account, not the relayer");
        assertEq(tokenA.balanceOf(carol), 0);
    }

    function test_AccountRedirectsToAnotherBeneficiary() public {
        vm.prank(alice);
        plugin.trigger(_claim(alice, 10 ether, carol));

        assertEq(tokenA.balanceOf(carol), 10 ether);
        assertEq(tokenA.balanceOf(alice), 0);
    }

    function test_RevertWhen_RelayerRedirects() public {
        vm.expectRevert(MerkleClaimAction.OnlyAccountCanRedirect.selector);
        vm.prank(carol);
        plugin.trigger(_claim(alice, 10 ether, carol));
    }

    function test_RevertWhen_BeneficiaryIsTheDao() public {
        vm.expectRevert(MerkleClaimAction.InvalidBeneficiary.selector);
        vm.prank(alice);
        plugin.trigger(_claim(alice, 10 ether, address(dao)));
    }

    function test_RevertWhen_ProofIsInvalid() public {
        vm.expectRevert(MerkleClaimAction.InvalidProof.selector);
        plugin.trigger(_claim(alice, 20 ether, address(0))); // the tree says 10
    }

    function test_NewRootPaysTheDifference() public {
        vm.prank(alice);
        plugin.trigger(_claim(alice, 10 ether, address(0)));

        vm.prank(manager);
        merkle.setRoot(_root(25 ether, 30 ether));

        vm.prank(alice);
        plugin.trigger(_claim(alice, 25 ether, address(0)));

        assertEq(tokenA.balanceOf(alice), 25 ether, "10 in round one, 15 more in round two");
    }

    function test_RevertWhen_SetRootUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector, address(dao), address(merkle), address(this), MANAGER_PERMISSION_ID
            )
        );
        merkle.setRoot(bytes32(0));
    }

    function test_RevertWhen_TheDaoCannotPay() public {
        vm.prank(manager);
        merkle.setRoot(_root(1_000 ether, 30 ether));

        vm.expectRevert(
            abi.encodeWithSelector(CapitalPipelinePlugin.InAmountExceedsInput.selector, 0, 1_000 ether, DAO_A)
        );
        plugin.trigger(_claim(alice, 1_000 ether, address(0)));
    }

    function test_RevertWhen_RecordClaimIsNotCalledByTheDao() public {
        vm.expectRevert(MerkleClaimAction.OnlyDao.selector);
        merkle.recordClaim(alice, 10 ether, alice);
    }

    function test_ClaimThenSwap() public {
        // Stage 0: claim 10 A (kept). Stage 1: swap it to B at 2 B per A and pay the beneficiary.
        MockExchange _exchange = new MockExchange(2e18);
        tokenB.mint(address(_exchange), 1_000 ether);
        MockSwapAction _swap = new MockSwapAction(_exchange, tokenB, address(dao));
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _two(merkle, NO_SPLITTER, _swap, payBeneficiary));

        bytes[] memory _data = new bytes[](2);
        _data[0] = _claim(alice, 10 ether, carol)[0];
        vm.prank(alice);
        _plugin.trigger(_data);

        assertEq(tokenB.balanceOf(carol), 20 ether, "beneficiary receives the swapped amount");
        assertEq(tokenA.balanceOf(address(dao)), DAO_A - 10 ether);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B, "treasury B untouched");
    }

    // Helpers

    function _leaf(address _account, uint256 _cumulative) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(_account, _cumulative))));
    }

    /// @dev OpenZeppelin MerkleProof hashes sorted pairs
    function _hashPair(bytes32 _a, bytes32 _b) internal pure returns (bytes32) {
        return _a < _b ? keccak256(abi.encode(_a, _b)) : keccak256(abi.encode(_b, _a));
    }

    function _root(uint256 _alice, uint256 _bob) internal returns (bytes32) {
        (aliceAmount, bobAmount) = (_alice, _bob);
        return _hashPair(_leaf(alice, _alice), _leaf(bob, _bob));
    }

    /// @dev The proof for a leaf in a two-leaf tree is the other leaf
    function _claim(address _account, uint256 _cumulative, address _beneficiary)
        internal
        view
        returns (bytes[] memory _data)
    {
        bytes32[] memory _proof = new bytes32[](1);
        _proof[0] = _account == alice ? _leaf(bob, bobAmount) : _leaf(alice, aliceAmount);

        _data = new bytes[](1);
        _data[0] = abi.encode(_account, _cumulative, _proof, _beneficiary);
    }
}
```

**Step 6: Run the tests to make sure they fail**

Run: `forge test`
Expected: compilation fails with `Source "src/budgets/BalanceBudget.sol" not found`

**Step 7: Create `src/budgets/BalanceBudget.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {
    DaoAuthorizableUpgradeable
} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizableUpgradeable.sol";
import {IBudget} from "../interfaces/IBudget.sol";
import {Plan} from "../lib/types.sol";

/// @title BalanceBudget
/// @notice The DAO's whole balance of a token, with nothing to commit. Used where something else
///         decides the amount, such as a Merkle claim, and the budget only caps it at what the DAO holds.
contract BalanceBudget is IBudget, Initializable, DaoAuthorizableUpgradeable {
    /// @inheritdoc IBudget
    IERC20 public token;

    /// @notice Thrown when the token has no code (includes native ETH, unsupported)
    error InvalidToken();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IDAO _dao, IERC20 _token) external initializer {
        if (address(_token).code.length == 0) revert InvalidToken();

        __DaoAuthorizableUpgradeable_init(_dao);
        token = _token;
    }

    /// @inheritdoc IBudget
    function available() external view returns (uint256) {
        return token.balanceOf(address(dao()));
    }

    /// @inheritdoc IBudget
    function commitActions(Plan calldata) external pure returns (Action[] memory) {}
}
```

**Step 8: Create `src/splitters/PayBeneficiary.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {ISplitter} from "../interfaces/ISplitter.sol";
import {Allocation, Plan} from "../lib/types.sol";

/// @title PayBeneficiary
/// @notice Sends a stage's whole output to the flow's beneficiary (e.g. the account a Merkle claim
///         paid). Stateless: one deployment serves every plugin.
contract PayBeneficiary is ISplitter {
    /// @notice Thrown when no action in the flow set a beneficiary
    error NoBeneficiary();

    /// @inheritdoc ISplitter
    function split(Plan calldata _plan) external pure returns (Allocation[] memory _allocations) {
        if (_plan.beneficiary == address(0)) revert NoBeneficiary();

        _allocations = new Allocation[](1);
        _allocations[0] = Allocation({recipient: _plan.beneficiary, amount: _plan.outAmount});
    }
}
```

**Step 9: Create `src/actions/MerkleClaimAction.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {
    DaoAuthorizableUpgradeable
} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizableUpgradeable.sol";
import {IStageAction} from "../interfaces/IStageAction.sol";
import {IBudget} from "../interfaces/IBudget.sol";
import {Plan} from "../lib/types.sol";
import {MANAGER_PERMISSION_ID} from "../lib/constants.sol";

/// @title MerkleClaimAction
/// @notice Cumulative Merkle distribution. Each leaf is (account, cumulative amount); an account
///         can claim `cumulative − claimed` at any time. A new root raises the cumulative amounts
///         for the next round.
/// @dev Outputs only what the claimed account is owed (not the whole budget) and sets it as the
///      flow's beneficiary, so later stages can swap it and a `PayBeneficiary` splitter pays it out.
///      Leaves use OpenZeppelin's StandardMerkleTree format: keccak256(bytes.concat(keccak256(abi.encode(account, cumulative)))).
///
///      Stage data: abi.encode(address account, uint256 cumulative, bytes32[] proof, address beneficiary).
///      Anyone may submit a claim (relayers), and the payout then goes to `account`. Only the account
///      itself may set a different beneficiary.
contract MerkleClaimAction is IStageAction, Initializable, DaoAuthorizableUpgradeable {
    /// @inheritdoc IStageAction
    IBudget public budget;

    /// @notice The current Merkle root of (account, cumulative amount) leaves
    bytes32 public root;

    /// @notice Cumulative amount already claimed per account
    mapping(address => uint256) public claimed;

    event RootUpdated(bytes32 root);
    event Claimed(address indexed account, address indexed beneficiary, uint256 amount);

    error NoBudget();
    error InvalidProof();
    error OnlyAccountCanRedirect();
    error InvalidBeneficiary();
    error OnlyDao();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IDAO _dao, IBudget _budget, bytes32 _root) external initializer {
        if (address(_budget) == address(0)) revert NoBudget();

        __DaoAuthorizableUpgradeable_init(_dao);
        budget = _budget;
        _setRoot(_root);
    }

    // IStageAction

    /// @inheritdoc IStageAction
    function preconditions(address, Plan calldata) external view virtual {}

    /// @inheritdoc IStageAction
    function build(address _caller, bytes calldata _data, Plan calldata _draft)
        external
        view
        virtual
        returns (Plan memory _plan, Action[] memory _actions)
    {
        (address _account, uint256 _cumulative, bytes32[] memory _proof, address _beneficiary) =
            abi.decode(_data, (address, uint256, bytes32[], address));

        if (!MerkleProof.verify(_proof, root, leaf(_account, _cumulative))) revert InvalidProof();
        if (_beneficiary == address(0)) _beneficiary = _account;
        if (_beneficiary != _account && _caller != _account) revert OnlyAccountCanRedirect();
        if (_beneficiary == address(dao())) revert InvalidBeneficiary();

        if (_cumulative <= claimed[_account]) return (_plan, _actions); // nothing new: skip
        uint256 _owed = _cumulative - claimed[_account];

        _plan = Plan({
            inToken: _draft.inToken,
            inAmount: _owed,
            outToken: _draft.inToken,
            outAmount: _owed,
            beneficiary: _beneficiary
        });

        _actions = new Action[](1);
        _actions[0] = Action({
            to: address(this), value: 0, data: abi.encodeCall(this.recordClaim, (_account, _cumulative, _beneficiary))
        });
    }

    /// @inheritdoc IStageAction
    /// @dev None: the plugin's balance checks verify the payout
    function postconditions(address, Plan calldata) external view virtual returns (Action[] memory) {}

    // Claim record

    /// @notice Records a claim. Executed by the DAO inside the claim's stage, so it rolls back with it.
    function recordClaim(address _account, uint256 _cumulative, address _beneficiary) external virtual {
        if (msg.sender != address(dao())) revert OnlyDao();

        emit Claimed(_account, _beneficiary, _cumulative - claimed[_account]);
        claimed[_account] = _cumulative;
    }

    /// @notice Replaces the root, usually with higher cumulative amounts for a new round
    /// @dev Whoever holds this can direct payouts up to the DAO's balance of the token
    function setRoot(bytes32 _root) external virtual auth(MANAGER_PERMISSION_ID) {
        _setRoot(_root);
    }

    /// @notice The leaf for `(account, cumulative)`, in OpenZeppelin's StandardMerkleTree format
    function leaf(address _account, uint256 _cumulative) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(_account, _cumulative))));
    }

    function _setRoot(bytes32 _root) internal {
        root = _root;
        emit RootUpdated(_root);
    }
}
```

**Step 10: Run the tests**

Run: `forge test`
Expected: `86 tests passed, 0 failed` (plugin suite `32 passed`, Merkle suite `12 passed`)

Run: `forge fmt --check`
Expected: no output

**Step 11: Commit**

```bash
git add -A src test
git commit -m "Add Merkle claims that can feed later stages

MerkleClaimAction outputs only what the claimed account is owed and
sets it as the flow's beneficiary, so a later stage can swap it before
PayBeneficiary pays it out. Leaves are cumulative, so new roots pay the
difference. Relayers can claim for an account; only the account itself
can redirect to another beneficiary. BalanceBudget caps claims at what
the DAO holds."
```

---

### Task 3: TriggerBatch

**Files:**
- Create: `test/TriggerBatch.t.sol`, `src/periphery/TriggerBatch.sol`

**Step 1: Create `test/TriggerBatch.t.sol`**

```solidity
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
```

**Step 2: Run it to make sure it fails**

Run: `forge test --match-contract TriggerBatchTest`
Expected: compilation fails with `Source "src/periphery/TriggerBatch.sol" not found`

**Step 3: Create `src/periphery/TriggerBatch.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {CapitalPipelinePlugin} from "../CapitalPipelinePlugin.sol";

/// @title TriggerBatch
/// @notice Triggers several plugins (on any DAOs) in one transaction. A plugin marked as allowed
///         to fail is skipped with an event instead of reverting the batch.
/// @dev Holds no state and no permissions: `trigger` is open to anyone by default. Each call is
///      sequential, not nested, so the plugins' reentrancy locks don't interfere.
contract TriggerBatch {
    event TriggerFailed(uint256 index, CapitalPipelinePlugin plugin, bytes reason);

    error LengthMismatch();

    /// @param _plugins The plugins to trigger, in order
    /// @param _data The `trigger` data for each plugin (empty bytes[] for none)
    /// @param _allowFailure Whether each plugin may fail without reverting the batch
    function triggerAll(
        CapitalPipelinePlugin[] calldata _plugins,
        bytes[][] calldata _data,
        bool[] calldata _allowFailure
    ) external {
        if (_data.length != _plugins.length || _allowFailure.length != _plugins.length) {
            revert LengthMismatch();
        }

        for (uint256 i; i < _plugins.length; ++i) {
            try _plugins[i].trigger(_data[i]) {}
            catch (bytes memory _reason) {
                if (!_allowFailure[i]) {
                    assembly {
                        revert(add(_reason, 0x20), mload(_reason))
                    }
                }
                emit TriggerFailed(i, _plugins[i], _reason);
            }
        }
    }
}
```

**Step 4: Run the tests**

Run: `forge test`
Expected: `89 tests passed, 0 failed`

Run: `forge fmt --check`
Expected: no output

**Step 5: Commit**

```bash
git add src/periphery test/TriggerBatch.t.sol
git commit -m "Add TriggerBatch to run independent flows together with allowed failures

One flow per plugin means independent flows live in separate plugins.
TriggerBatch triggers several in one transaction, on any DAOs, and skips
the ones marked allowed-to-fail, which replaces capital-router's
failsafe map."
```

---

### Task 4: README

**Files:**
- Replace: `README.md`

**Step 1: Replace `README.md`**

````markdown
# Capital Pipeline

Aragon OSx plugin that runs one treasury flow per install: a **budget**, then a chain of
**stages** (action → splitter), where each stage passes what it produced and didn't transfer out
to the next one. After every stage the plugin checks balances, so a stage can only ever spend what
the budget released or what the previous stage really produced.

```
budget → [action → splitter] → [action → splitter] → … → budget commit
```

Examples: sell token A in a Dutch auction and split the proceeds 95% burn / 5% fee; swap, keep
part of the output and pay it on; let accounts claim cumulative Merkle allocations, optionally
swapped before they're paid.

Design: [`docs/plans/2026-11-04-capital-pipeline-design.md`](docs/plans/2026-11-04-capital-pipeline-design.md)

## Layout

| Path | What |
|---|---|
| `src/CapitalPipelinePlugin.sol` | Runs the flow, checks balances after every stage |
| `src/budgets/FundedStreamBudget.sol` | Streaming pot that never jumps |
| `src/budgets/BalanceBudget.sol` | The DAO's whole balance of a token |
| `src/actions/OpenFillAction.sol` | Open-fill swap with Dutch-auction pricing |
| `src/actions/MerkleClaimAction.sol` | Cumulative Merkle claims with a redirectable beneficiary |
| `src/splitters/RatioSplitter.sol` | Fixed-ratio split; a share to the DAO carries to the next stage |
| `src/splitters/PayBeneficiary.sol` | Pays a stage's output to the flow's beneficiary |
| `src/periphery/TriggerBatch.sol` | Triggers several plugins in one transaction, with allowed failures |
| `src/setup/CapitalPipelinePluginSetup.sol` | Installs the swap-and-split flow |

## Permissions

| Permission | Holder | Allows |
|---|---|---|
| `TRIGGER_PERMISSION_ID` | anyone | `trigger()` |
| `CONFIGURE_PERMISSION_ID` | DAO only | `setFlow()` |
| `MANAGER_PERMISSION_ID` | manager | parameter setters, Merkle `setRoot()`, `pause()`, `unpause()` |
| `CHECKPOINT_PERMISSION_ID` | DAO, swap action | restarting the stream budget |

## Develop

```shell
git submodule update --init --recursive
forge build
forge test
```

Never set `via_ir = true`; fix stack-too-deep errors by restructuring the code.
````

**Step 2: Commit**

```bash
git add README.md
git commit -m "Describe flows, the new components and permissions in the README"
```
