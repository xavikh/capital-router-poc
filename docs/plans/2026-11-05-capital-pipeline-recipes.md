# Capital Pipeline: Recipe Installation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use /executing-plans to implement this plan task-by-task.

**Goal:** Install any flow from a recipe, with every component a fresh clone of a registered implementation bound to the installing DAO.

**Architecture:** A write-once `ComponentRegistry` maps ids (`"OpenFillAction@1"`) to implementations. `CapitalPipelinePluginSetup` takes a recipe (components by id with their `initialize` calls, the budget, the tree, the grants) that names not-yet-deployed contracts with placeholders (`DAO_REF`, `PLUGIN_REF`, `ref(i)`); it clones everything, replaces the placeholders, initializes, and returns the permissions. Every component is bound to one DAO, and the plugin rejects budgets and actions that aren't bound to its own, so implementations can never run in a flow.

**Tech Stack:** Solidity 0.8.28 (cancun, optimizer 200, **never via_ir**), Foundry, Aragon OSx 1.4, OpenZeppelin 4.9.6. Testing patterns: @sol-test.

**Design:** `docs/plans/2026-11-04-capital-pipeline-design.md` (sections "Rules" 10, "ComponentRegistry", "CapitalPipelinePluginSetup"). **Branch:** `feat/flow-stages`.

**Verified:** every code block below was compiled and tested in a scratch copy of this repo, including the state after each task. Each new guard (DAO binding, splitter binding, grant targets, reserved `CONFIGURE`, uninstall hash, write-once registry) was also confirmed to make a test fail when removed.

---

## Tasks

| # | Task | End state | Time |
|---|---|---|---|
| 1 | Bind every component to its DAO | 116 tests pass | 15 min |
| 2 | Registry, recipe setup, recipes and deploy script | 132 tests pass | 20 min |
| 3 | README | unchanged | 3 min |

Conventions:
- Copy every code block verbatim; each file block replaces the whole file.
- Test names: `test_<Behavior>`, `test_RevertWhen_<Condition>`, `testFuzz_<Property>`, `invariant_<Property>`.
- Commit messages have no `Co-Authored-By` line.
- Unchanged and not touched by this plan: `foundry.toml`, `remappings.txt`, and every file not listed in a task.

---

### Task 1: Bind every component to its DAO

`BurnAction`, `KeepAction` and `TransferToBeneficiaryAction` stop being shared deployments: like every other component they become clones with a locked implementation and an `initialize(IDAO)`. `TransferAction` and `SplitTransferAction` take the DAO too. The plugin rejects a budget or action whose `dao()` isn't its own (`ForeignComponent`), and `SplitTransferAction` rejects a splitter of another DAO (`ForeignSplitter`). The current setup only needs the DAO passed to `SplitTransferAction.initialize`; Task 2 replaces it.

**Files:**
- Modify (tests first): `test/mocks/BadComponents.sol`, `test/helpers/Fixture.sol`, `test/LeafActions.t.sol`, `test/CapitalPipelinePlugin.t.sol`
- Modify: `src/interfaces/INodeAction.sol`, `src/interfaces/IBudget.sol`, `src/actions/TransferBase.sol`, `src/actions/TransferAction.sol`, `src/actions/TransferToBeneficiaryAction.sol`, `src/actions/BurnAction.sol`, `src/actions/KeepAction.sol`, `src/actions/SplitTransferAction.sol`, `src/CapitalPipelinePlugin.sol`, `src/setup/CapitalPipelinePluginSetup.sol`

**Step 1: Replace `test/mocks/BadComponents.sol`** (the mock splitters expose a `dao`)

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IBudget} from "../../src/interfaces/IBudget.sol";
import {INodeAction} from "../../src/interfaces/INodeAction.sol";
import {ISplitter} from "../../src/interfaces/ISplitter.sol";
import {Plan, Allocation} from "../../src/lib/types.sol";

/// @notice A node action that misbehaves in one chosen way. Otherwise it passes its input through.
contract BadAction is INodeAction {
    enum Mode {
        Pass, // behaves: passes its whole input on
        Block, // preconditions revert
        Skip, // takes nothing
        TakeHalf, // takes half its input
        Overspend, // claims 1 wei more than its input
        TargetDao, // returns an action whose target is the DAO
        TargetPlugin, // returns an action whose target is the plugin
        Redirect, // sets a different beneficiary than the one already set
        SwapInputToken, // declares a different input token
        Lie, // declares 10 B of output it never produces
        Drain // declares half its input as a leaf but transfers all of it away
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
        if (mode == Mode.TakeHalf) (_plan.inAmount, _plan.outAmount) = (_draft.inAmount / 2, _draft.inAmount / 2);
        if (mode == Mode.Overspend) _plan.inAmount += 1;
        if (mode == Mode.Redirect) _plan.beneficiary = THIEF;
        if (mode == Mode.SwapInputToken) _plan.inToken = IERC20(THIEF);
        if (mode == Mode.Lie) (_plan.outToken, _plan.outAmount) = (tokenB, 10 ether);
        if (mode == Mode.TargetDao || mode == Mode.TargetPlugin) {
            _actions = new Action[](1);
            _actions[0] = Action({to: mode == Mode.TargetDao ? dao : msg.sender, value: 0, data: ""});
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

/// @notice A splitter that allocates 1 wei more than it was given
contract OverAllocatingSplitter is ISplitter {
    address public immutable dao;

    constructor(address _dao) {
        dao = _dao;
    }

    function split(uint256 _amount) external pure returns (Allocation[] memory _allocations) {
        _allocations = new Allocation[](1);
        _allocations[0] = Allocation({recipient: address(0xBEEF), amount: _amount + 1});
    }
}

/// @notice Lists the same recipient twice, splitting the amount 50/50 between the two entries
contract DuplicateRecipientSplitter is ISplitter {
    address public immutable dao;
    address public immutable recipient;

    constructor(address _dao, address _recipient) {
        (dao, recipient) = (_dao, _recipient);
    }

    function split(uint256 _amount) external view returns (Allocation[] memory _allocations) {
        _allocations = new Allocation[](2);
        _allocations[0] = Allocation({recipient: recipient, amount: _amount / 2});
        _allocations[1] = Allocation({recipient: recipient, amount: _amount - _amount / 2});
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

**Step 2: Replace `test/helpers/Fixture.sol`** (leaves are clones bound to the test DAO; adds `_deployKeep`)

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {FundedStreamBudget} from "../../src/budgets/FundedStreamBudget.sol";
import {BalanceBudget} from "../../src/budgets/BalanceBudget.sol";
import {RatioSplitter} from "../../src/splitters/RatioSplitter.sol";
import {OpenFillAction} from "../../src/actions/OpenFillAction.sol";
import {MerkleClaimAction} from "../../src/actions/MerkleClaimAction.sol";
import {TransferAction} from "../../src/actions/TransferAction.sol";
import {TransferToBeneficiaryAction} from "../../src/actions/TransferToBeneficiaryAction.sol";
import {BurnAction} from "../../src/actions/BurnAction.sol";
import {KeepAction} from "../../src/actions/KeepAction.sol";
import {SplitTransferAction} from "../../src/actions/SplitTransferAction.sol";
import {CapitalPipelinePlugin} from "../../src/CapitalPipelinePlugin.sol";
import {IBudget} from "../../src/interfaces/IBudget.sol";
import {INodeAction} from "../../src/interfaces/INodeAction.sol";
import {ISplitter} from "../../src/interfaces/ISplitter.sol";
import {Node} from "../../src/lib/types.sol";
import {
    MANAGER_PERMISSION_ID,
    CHECKPOINT_PERMISSION_ID,
    TRIGGER_PERMISSION_ID,
    CONFIGURE_PERMISSION_ID,
    RECORD_CLAIM_PERMISSION_ID
} from "../../src/lib/constants.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

/// @notice A DAO holding the offered token A and some pre-existing demanded token B.
///         The test contract is the DAO's ROOT, so it can grant permissions directly.
abstract contract Fixture is Test {
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;
    address internal constant ANY_ADDR = address(type(uint160).max);
    INodeAction internal constant NO_ACTION = INodeAction(address(0));

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

    // Leaves without settings, cloned for the test DAO
    BurnAction internal burn;
    KeepAction internal keep;
    TransferToBeneficiaryAction internal toBeneficiary;

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

        burn = BurnAction(
            ProxyLib.deployMinimalProxy(address(new BurnAction()), abi.encodeCall(BurnAction.initialize, (dao)))
        );
        keep = _deployKeep(dao);
        toBeneficiary = TransferToBeneficiaryAction(
            ProxyLib.deployMinimalProxy(
                address(new TransferToBeneficiaryAction()),
                abi.encodeCall(TransferToBeneficiaryAction.initialize, (dao))
            )
        );
    }

    // Budgets

    /// @dev A stream of token A. Deploy after funding the DAO: the budget records the balance it sees at init.
    function _deployBudget(uint256 _rate, uint256 _maxBudget) internal returns (FundedStreamBudget) {
        return _deployStream(tokenA, _rate, _maxBudget);
    }

    /// @dev A stream of any token, or of native ETH (`NATIVE`)
    function _deployStream(IERC20 _token, uint256 _rate, uint256 _maxBudget)
        internal
        returns (FundedStreamBudget _budget)
    {
        _budget = FundedStreamBudget(
            ProxyLib.deployMinimalProxy(
                address(new FundedStreamBudget()),
                abi.encodeCall(FundedStreamBudget.initialize, (dao, _token, _rate, _maxBudget, EPOCH))
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

    // Splitters (used by SplitTransferAction)

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

    /// @dev Demands token B. Bound to `_budget`, which it may restart when its price terms change.
    function _deployAction(FundedStreamBudget _budget) internal returns (OpenFillAction) {
        return _deployOpenFill(_budget, tokenB);
    }

    /// @dev Demands any token, or native ETH (`NATIVE`)
    function _deployOpenFill(FundedStreamBudget _budget, IERC20 _demanded) internal returns (OpenFillAction _action) {
        _action = OpenFillAction(
            ProxyLib.deployMinimalProxy(
                address(new OpenFillAction()),
                abi.encodeCall(OpenFillAction.initialize, (dao, _budget, _demanded, DEMAND, MIN_PRICE))
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
        dao.grant(address(_merkle), address(dao), RECORD_CLAIM_PERMISSION_ID);
    }

    function _deployTransfer(address _to) internal returns (TransferAction) {
        return TransferAction(
            ProxyLib.deployMinimalProxy(
                address(new TransferAction()), abi.encodeCall(TransferAction.initialize, (dao, _to))
            )
        );
    }

    function _deploySplitTransfer(ISplitter _splitter) internal returns (SplitTransferAction) {
        return SplitTransferAction(
            ProxyLib.deployMinimalProxy(
                address(new SplitTransferAction()), abi.encodeCall(SplitTransferAction.initialize, (dao, _splitter))
            )
        );
    }

    /// @dev A keep leaf bound to `_dao` (another DAO's component when `_dao` isn't the test DAO)
    function _deployKeep(IDAO _dao) internal returns (KeepAction) {
        return KeepAction(
            ProxyLib.deployMinimalProxy(address(new KeepAction()), abi.encodeCall(KeepAction.initialize, (_dao)))
        );
    }

    // Plugin

    /// @dev Same grants as CapitalPipelinePluginSetup: anyone triggers, the DAO configures, the manager pauses
    function _deployPlugin(IBudget _budget, Node[] memory _tree) internal returns (CapitalPipelinePlugin _plugin) {
        _plugin = CapitalPipelinePlugin(
            ProxyLib.deployMinimalProxy(
                address(new CapitalPipelinePlugin()),
                abi.encodeCall(CapitalPipelinePlugin.initialize, (dao, _budget, _tree))
            )
        );
        dao.grant(address(dao), address(_plugin), dao.EXECUTE_PERMISSION_ID());
        dao.grant(address(_plugin), ANY_ADDR, TRIGGER_PERMISSION_ID);
        dao.grant(address(_plugin), address(dao), CONFIGURE_PERMISSION_ID);
        dao.grant(address(_plugin), manager, MANAGER_PERMISSION_ID);
    }

    // Trees

    /// @dev A single node with no children
    function _leaf(INodeAction _action) internal pure returns (Node memory _node) {
        _node.action = _action;
    }

    /// @dev A node with one child
    function _then(INodeAction _action, uint32 _child) internal pure returns (Node memory _node) {
        _node.action = _action;
        _node.children = new uint32[](1);
        _node.children[0] = _child;
    }

    /// @dev A node with two children, split by weights (fractions of RATIO_BASE)
    function _branch(INodeAction _action, uint32 _childA, uint32 _weightA, uint32 _childB, uint32 _weightB)
        internal
        pure
        returns (Node memory _node)
    {
        _node.action = _action;
        _node.children = new uint32[](2);
        (_node.children[0], _node.children[1]) = (_childA, _childB);
        _node.weights = new uint32[](2);
        (_node.weights[0], _node.weights[1]) = (_weightA, _weightB);
    }

    /// @dev A one-node tree
    function _one(INodeAction _action) internal pure returns (Node[] memory _tree) {
        _tree = new Node[](1);
        _tree[0] = _leaf(_action);
    }

    /// @dev `_a` → `_b`
    function _chain(INodeAction _a, INodeAction _b) internal pure returns (Node[] memory _tree) {
        _tree = new Node[](2);
        (_tree[0], _tree[1]) = (_then(_a, 1), _leaf(_b));
    }

    /// @dev `_a` → `_b` → `_c`
    function _chain(INodeAction _a, INodeAction _b, INodeAction _c) internal pure returns (Node[] memory _tree) {
        _tree = new Node[](3);
        (_tree[0], _tree[1], _tree[2]) = (_then(_a, 1), _then(_b, 2), _leaf(_c));
    }

    /// @dev `_root` split by weight between two leaves
    function _fork(INodeAction _root, uint32 _weightA, INodeAction _a, uint32 _weightB, INodeAction _b)
        internal
        pure
        returns (Node[] memory _tree)
    {
        _tree = new Node[](3);
        (_tree[0], _tree[1], _tree[2]) = (_branch(_root, 1, _weightA, 2, _weightB), _leaf(_a), _leaf(_b));
    }
}
```

**Step 3: Replace `test/LeafActions.t.sol`**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {CapitalPipelinePlugin} from "../src/CapitalPipelinePlugin.sol";
import {BalanceBudget} from "../src/budgets/BalanceBudget.sol";
import {TransferAction} from "../src/actions/TransferAction.sol";
import {TransferBase} from "../src/actions/TransferBase.sol";
import {TransferToBeneficiaryAction} from "../src/actions/TransferToBeneficiaryAction.sol";
import {BurnAction} from "../src/actions/BurnAction.sol";
import {KeepAction} from "../src/actions/KeepAction.sol";
import {RatioSplitter} from "../src/splitters/RatioSplitter.sol";
import {SplitTransferAction} from "../src/actions/SplitTransferAction.sol";
import {ISplitter} from "../src/interfaces/ISplitter.sol";
import {Plan} from "../src/lib/types.sol";
import {NATIVE} from "../src/lib/tokens.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {OverAllocatingSplitter, DuplicateRecipientSplitter, FalseReturnToken} from "./mocks/BadComponents.sol";

contract LeafActionsTest is Fixture {
    BalanceBudget internal budget;

    function setUp() public override {
        super.setUp();
        budget = _deployBalanceBudget(tokenA); // 100 A
    }

    // Transfer

    function test_TransferSendsTheWholeInput() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _one(_deployTransfer(alice)));

        _plugin.trigger(noData);

        assertEq(tokenA.balanceOf(alice), DAO_A);
        assertEq(tokenA.balanceOf(address(dao)), 0);
    }

    function test_TransferPostconditionMeasuresTheRecipient() public {
        TransferAction _transfer = _deployTransfer(alice);
        Plan memory _plan = Plan(tokenA, 7 ether, tokenA, 0, address(0));

        Action[] memory _checks = _transfer.postconditions(address(0), _plan);

        assertEq(_checks.length, 1);
        assertEq(_checks[0].to, address(_transfer));
        assertEq(_checks[0].data, abi.encodeCall(TransferBase.assertReceived, (IERC20(tokenA), alice, 7 ether)));
    }

    function test_RevertWhen_ATransferSilentlyFails() public {
        FalseReturnToken _token = new FalseReturnToken(0);
        _token.mint(address(dao), 100 ether);
        CapitalPipelinePlugin _plugin =
            _deployPlugin(_deployBalanceBudget(IERC20(address(_token))), _one(_deployTransfer(alice)));

        // Action 0 is the transfer (returns false), action 1 the postcondition, which catches it
        vm.expectRevert(abi.encodeWithSelector(DAO.ActionFailed.selector, 1));
        _plugin.trigger(noData);
    }

    function test_RevertWhen_TransferRecipientIsUnset() public {
        TransferAction _transfer = TransferAction(ProxyLib.deployMinimalProxy(address(new TransferAction()), ""));

        vm.expectRevert(TransferAction.NoRecipient.selector);
        _transfer.initialize(dao, address(0));
    }

    // Transfer to beneficiary

    function test_RevertWhen_ThereIsNoBeneficiary() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _one(toBeneficiary));

        vm.expectRevert(TransferToBeneficiaryAction.NoBeneficiary.selector);
        _plugin.trigger(noData);
    }

    // Burn

    function test_BurnLowersTheSupply() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _one(burn));
        uint256 _supply = tokenA.totalSupply();

        _plugin.trigger(noData);

        assertEq(tokenA.totalSupply(), _supply - DAO_A);
    }

    function test_RevertWhen_BurningNativeEth() public {
        vm.expectRevert(BurnAction.CannotBurnNative.selector);
        burn.preconditions(address(0), Plan(NATIVE, 1 ether, NATIVE, 0, address(0)));
    }

    // Keep

    function test_KeepLeavesTheInputInTheDao() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _one(keep));

        _plugin.trigger(noData);

        assertEq(tokenA.balanceOf(address(dao)), DAO_A);
    }

    // Split transfer

    function test_SplitTransferPaysEachRecipient() public {
        CapitalPipelinePlugin _plugin =
            _deployPlugin(budget, _one(_deploySplitTransfer(_deployRatio(alice, 700_000, bob, 300_000))));

        _plugin.trigger(noData);

        assertEq(tokenA.balanceOf(alice), 70 ether);
        assertEq(tokenA.balanceOf(bob), 30 ether);
    }

    /// capital-router checks each transfer against a snapshot taken before any of them, so a
    /// recipient listed twice can miss a silent failure. Here expectations add up per recipient.
    function test_RevertWhen_ARepeatedRecipientMissesATransfer() public {
        FalseReturnToken _token = new FalseReturnToken(1); // the second transfer silently fails
        _token.mint(address(dao), 100 ether);
        CapitalPipelinePlugin _plugin = _deployPlugin(
            _deployBalanceBudget(IERC20(address(_token))),
            _one(_deploySplitTransfer(new DuplicateRecipientSplitter(address(dao), alice)))
        );

        // Actions 0 and 1 are the transfers, action 2 the postcondition (alice expected 100, has 50)
        vm.expectRevert(abi.encodeWithSelector(DAO.ActionFailed.selector, 2));
        _plugin.trigger(noData);
    }

    function test_RevertWhen_TheSplitterAllocatesTooMuch() public {
        CapitalPipelinePlugin _plugin =
            _deployPlugin(budget, _one(_deploySplitTransfer(new OverAllocatingSplitter(address(dao)))));

        vm.expectRevert(abi.encodeWithSelector(SplitTransferAction.AllocationExceedsInput.selector, DAO_A + 1, DAO_A));
        _plugin.trigger(noData);
    }

    function test_RevertWhen_SplitterIsUnset() public {
        SplitTransferAction _split =
            SplitTransferAction(ProxyLib.deployMinimalProxy(address(new SplitTransferAction()), ""));

        vm.expectRevert(SplitTransferAction.NoSplitter.selector);
        _split.initialize(dao, ISplitter(address(0)));
    }

    function test_RevertWhen_TheSplitterIsAnImplementation() public {
        SplitTransferAction _split =
            SplitTransferAction(ProxyLib.deployMinimalProxy(address(new SplitTransferAction()), ""));
        RatioSplitter _implementation = new RatioSplitter();

        vm.expectRevert(SplitTransferAction.ForeignSplitter.selector);
        _split.initialize(dao, _implementation);
    }

    // Implementations

    function test_RevertWhen_InitializingAnImplementation() public {
        BurnAction _burn = new BurnAction();
        KeepAction _keep = new KeepAction();
        TransferToBeneficiaryAction _toBeneficiary = new TransferToBeneficiaryAction();

        vm.expectRevert("Initializable: contract is already initialized");
        _burn.initialize(dao);
        vm.expectRevert("Initializable: contract is already initialized");
        _keep.initialize(dao);
        vm.expectRevert("Initializable: contract is already initialized");
        _toBeneficiary.initialize(dao);
    }
}

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
        _budget.initialize(dao, IERC20(address(0xBEEF)));
    }

    function test_RevertWhen_TokenIsUnset() public {
        BalanceBudget _budget = BalanceBudget(ProxyLib.deployMinimalProxy(address(new BalanceBudget()), ""));

        vm.expectRevert(BalanceBudget.InvalidToken.selector);
        _budget.initialize(dao, IERC20(address(0)));
    }
}
```

**Step 4: Replace `test/CapitalPipelinePlugin.t.sol`**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {DaoUnauthorized} from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {CapitalPipelinePlugin} from "../src/CapitalPipelinePlugin.sol";
import {FundedStreamBudget} from "../src/budgets/FundedStreamBudget.sol";
import {BalanceBudget} from "../src/budgets/BalanceBudget.sol";
import {OpenFillAction} from "../src/actions/OpenFillAction.sol";
import {MerkleClaimAction} from "../src/actions/MerkleClaimAction.sol";
import {SplitTransferAction} from "../src/actions/SplitTransferAction.sol";
import {KeepAction} from "../src/actions/KeepAction.sol";
import {IBudget} from "../src/interfaces/IBudget.sol";
import {INodeAction} from "../src/interfaces/INodeAction.sol";
import {Node} from "../src/lib/types.sol";
import {CONFIGURE_PERMISSION_ID, MANAGER_PERMISSION_ID} from "../src/lib/constants.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {MockFiller} from "./mocks/MockFiller.sol";
import {MockExchange, MockSwapAction} from "./mocks/MockSwap.sol";
import {BadAction} from "./mocks/BadComponents.sol";

contract CapitalPipelinePluginTest is Fixture {
    FundedStreamBudget internal budget;
    OpenFillAction internal action;
    SplitTransferAction internal split;
    CapitalPipelinePlugin internal plugin;
    MockFiller internal filler;

    /// @dev Swap 10 A for 1,000 B, then pay 95% to the burn address and 5% to the fee address
    function setUp() public override {
        super.setUp();
        budget = _deployBudget(RATE, 0);
        action = _deployAction(budget);
        split = _deploySplitTransfer(_deploySplitter());
        plugin = _deployPlugin(budget, _chain(action, split));

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
        assertEq(_stored.length, 2);
        assertEq(address(_stored[0].action), address(action));
        assertEq(_stored[0].children[0], 1);
        assertEq(address(_stored[1].action), address(split));
        assertEq(_stored[1].children.length, 0);
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

    function test_RevertWhen_ABoundActionIsNotTheRoot() public {
        _expectInitRevert(
            budget,
            _fork(NO_ACTION, 500_000, action, 500_000, keep),
            abi.encodeWithSelector(CapitalPipelinePlugin.BudgetMismatch.selector, 1)
        );
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
            _chain(action, split),
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
        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.DataLengthMismatch.selector, 2, 1));
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

    function _expectInitRevert(IBudget _budget, Node[] memory _tree, bytes memory _error) internal {
        CapitalPipelinePlugin _plugin =
            CapitalPipelinePlugin(ProxyLib.deployMinimalProxy(address(new CapitalPipelinePlugin()), ""));
        vm.expectRevert(_error);
        _plugin.initialize(dao, _budget, _tree);
    }
}
```

**Step 5: Run the tests to make sure they fail**

Run: `forge build`
Expected: compilation fails with `Member "initialize" not found or not visible after argument-dependent lookup in type(contract BurnAction)`

**Step 6: Replace `src/interfaces/INodeAction.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IBudget} from "./IBudget.sol";
import {Plan} from "../lib/types.sol";

/// @title INodeAction
/// @notice What a node of a flow tree does with its input. The plugin calls all three hooks, in
///         order, on every node that has an action, so an action's safety checks can't be left out.
/// @dev Actions are clones initialized for one DAO and expose it as `dao()`
///      (`DaoAuthorizableUpgradeable`). The plugin rejects actions bound to another DAO or to none.
interface INodeAction {
    /// @notice The budget this action is bound to, or address(0) if it works with any input.
    ///         A bound action can only be the root of a flow on that budget.
    function budget() external view returns (IBudget);

    /// @notice Reverts if the action must not run
    function preconditions(address caller, Plan calldata draft) external view;

    /// @notice Sets `inAmount` (the root may take less than its input, every other node all of it),
    ///         `outToken`/`outAmount` (zero for a leaf) and optionally `beneficiary`, and returns the
    ///         actions that do the work.
    /// @dev `outAmount` must be known here: it is divided among the children before they run
    function build(address caller, bytes calldata data, Plan calldata draft)
        external
        view
        returns (Plan memory plan, Action[] memory actions);

    /// @notice The checks that make the work safe, executed by the DAO right after it
    function postconditions(address caller, Plan calldata plan) external view returns (Action[] memory);
}
```

**Step 7: Replace `src/interfaces/IBudget.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {Plan} from "../lib/types.sol";

/// @title IBudget
/// @notice How much of a token a flow may spend right now
/// @dev Budgets are clones initialized for one DAO and expose it as `dao()`
///      (`DaoAuthorizableUpgradeable`). The plugin rejects budgets bound to another DAO or to none.
interface IBudget {
    /// @notice The token this budget releases
    function token() external view returns (IERC20);

    /// @notice The amount the flow may spend right now
    function available() external view returns (uint256);

    /// @notice DAO actions that record the spend. The plugin executes them once, in their own
    ///         `dao.execute`, after the whole tree ran, passing the root's plan.
    function commitActions(Plan calldata plan) external view returns (Action[] memory);
}

/// @title ICheckpointedBudget
/// @notice A budget that can be restarted from zero
interface ICheckpointedBudget is IBudget {
    /// @notice Restarts the available amount from zero
    function writeCheckpoint() external;
}
```

**Step 8: Replace `src/actions/TransferBase.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {
    DaoAuthorizableUpgradeable
} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizableUpgradeable.sol";
import {INodeAction} from "../interfaces/INodeAction.sol";
import {IBudget} from "../interfaces/IBudget.sol";
import {Plan} from "../lib/types.sol";
import {tokenBalance, transferAction} from "../lib/tokens.sol";

/// @title TransferBase
/// @notice Leaf that sends its whole input to one recipient. Postcondition: the recipient's balance
///         rose by the amount, which catches tokens that return false instead of reverting.
/// @dev Native ETH works too. Fee-on-transfer and rebasing tokens fail the postcondition by design.
abstract contract TransferBase is INodeAction, DaoAuthorizableUpgradeable {
    /// @notice Thrown when a recipient holds less than it should after the transfer
    error ReceiptShortfall(IERC20 token, address recipient, uint256 expected, uint256 actual);

    /// @inheritdoc INodeAction
    function budget() external pure returns (IBudget) {}

    /// @inheritdoc INodeAction
    function preconditions(address, Plan calldata) external view virtual {}

    /// @inheritdoc INodeAction
    function build(address, bytes calldata, Plan calldata _draft)
        external
        view
        virtual
        returns (Plan memory _plan, Action[] memory _actions)
    {
        _plan = Plan(_draft.inToken, _draft.inAmount, _draft.inToken, 0, _draft.beneficiary);
        _actions = new Action[](1);
        _actions[0] = transferAction(_draft.inToken, _recipient(_draft), _draft.inAmount);
    }

    /// @inheritdoc INodeAction
    function postconditions(address, Plan calldata _plan) external view virtual returns (Action[] memory _checks) {
        address _to = _recipient(_plan);
        uint256 _minBalance = tokenBalance(_plan.inToken, _to) + _plan.inAmount;

        _checks = new Action[](1);
        _checks[0] = Action({
            to: address(this), value: 0, data: abi.encodeCall(this.assertReceived, (_plan.inToken, _to, _minBalance))
        });
    }

    /// @notice Reverts unless `_account` holds at least `_minBalance` of `_token`
    /// @dev Executed by the DAO right after the transfer. View, so harmless to call from anywhere.
    function assertReceived(IERC20 _token, address _account, uint256 _minBalance) external view {
        uint256 _balance = tokenBalance(_token, _account);
        if (_balance < _minBalance) revert ReceiptShortfall(_token, _account, _minBalance, _balance);
    }

    function _recipient(Plan calldata _plan) internal view virtual returns (address);
}
```

**Step 9: Replace `src/actions/TransferAction.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {TransferBase} from "./TransferBase.sol";
import {Plan} from "../lib/types.sol";

/// @title TransferAction
/// @notice Leaf that sends its whole input to a fixed recipient
contract TransferAction is TransferBase {
    /// @notice Who receives the node's input
    address public recipient;

    /// @notice Thrown when the recipient is address(0)
    error NoRecipient();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IDAO _dao, address _to) external initializer {
        if (_to == address(0)) revert NoRecipient();
        __DaoAuthorizableUpgradeable_init(_dao);
        recipient = _to;
    }

    function _recipient(Plan calldata) internal view override returns (address) {
        return recipient;
    }
}
```

**Step 10: Replace `src/actions/TransferToBeneficiaryAction.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {TransferBase} from "./TransferBase.sol";
import {Plan} from "../lib/types.sol";

/// @title TransferToBeneficiaryAction
/// @notice Leaf that sends its whole input to the flow's beneficiary (set by a claim at the root)
contract TransferToBeneficiaryAction is TransferBase {
    /// @notice Thrown when no action in the flow set a beneficiary
    error NoBeneficiary();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IDAO _dao) external initializer {
        __DaoAuthorizableUpgradeable_init(_dao);
    }

    function _recipient(Plan calldata _plan) internal pure override returns (address) {
        if (_plan.beneficiary == address(0)) revert NoBeneficiary();
        return _plan.beneficiary;
    }
}
```

**Step 11: Replace `src/actions/BurnAction.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {
    DaoAuthorizableUpgradeable
} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizableUpgradeable.sol";
import {INodeAction} from "../interfaces/INodeAction.sol";
import {IBudget} from "../interfaces/IBudget.sol";
import {Plan} from "../lib/types.sol";
import {NATIVE} from "../lib/tokens.sol";

/// @title BurnAction
/// @notice Leaf that burns its whole input with `ERC20Burnable.burn`, lowering the total supply
/// @dev The token must implement `burn(uint256)`; otherwise the DAO action reverts. The plugin's
///      balance check confirms the DAO spent no more than the input.
contract BurnAction is INodeAction, DaoAuthorizableUpgradeable {
    /// @notice Thrown when the input is native ETH, which can't be burned
    error CannotBurnNative();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IDAO _dao) external initializer {
        __DaoAuthorizableUpgradeable_init(_dao);
    }

    /// @inheritdoc INodeAction
    function budget() external pure returns (IBudget) {}

    /// @inheritdoc INodeAction
    function preconditions(address, Plan calldata _draft) external pure {
        if (_draft.inToken == NATIVE) revert CannotBurnNative();
    }

    /// @inheritdoc INodeAction
    function build(address, bytes calldata, Plan calldata _draft)
        external
        pure
        returns (Plan memory _plan, Action[] memory _actions)
    {
        _plan = Plan(_draft.inToken, _draft.inAmount, _draft.inToken, 0, _draft.beneficiary);
        _actions = new Action[](1);
        _actions[0] = Action({
            to: address(_draft.inToken), value: 0, data: abi.encodeCall(ERC20Burnable.burn, (_draft.inAmount))
        });
    }

    /// @inheritdoc INodeAction
    function postconditions(address, Plan calldata) external pure returns (Action[] memory) {}
}
```

**Step 12: Replace `src/actions/KeepAction.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {
    DaoAuthorizableUpgradeable
} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizableUpgradeable.sol";
import {INodeAction} from "../interfaces/INodeAction.sol";
import {IBudget} from "../interfaces/IBudget.sol";
import {Plan} from "../lib/types.sol";

/// @title KeepAction
/// @notice Leaf that leaves its whole input in the DAO, so keeping funds is an explicit choice
contract KeepAction is INodeAction, DaoAuthorizableUpgradeable {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IDAO _dao) external initializer {
        __DaoAuthorizableUpgradeable_init(_dao);
    }

    /// @inheritdoc INodeAction
    function budget() external pure returns (IBudget) {}

    /// @inheritdoc INodeAction
    function preconditions(address, Plan calldata) external pure {}

    /// @inheritdoc INodeAction
    function build(address, bytes calldata, Plan calldata _draft)
        external
        pure
        returns (Plan memory _plan, Action[] memory _actions)
    {
        _plan = Plan(_draft.inToken, _draft.inAmount, _draft.inToken, 0, _draft.beneficiary);
        return (_plan, _actions);
    }

    /// @inheritdoc INodeAction
    function postconditions(address, Plan calldata) external pure returns (Action[] memory) {}
}
```

**Step 13: Replace `src/actions/SplitTransferAction.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {
    DaoAuthorizableUpgradeable
} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizableUpgradeable.sol";
import {INodeAction} from "../interfaces/INodeAction.sol";
import {IBudget} from "../interfaces/IBudget.sol";
import {ISplitter} from "../interfaces/ISplitter.sol";
import {Plan, Allocation} from "../lib/types.sol";
import {tokenBalance, transferAction} from "../lib/tokens.sol";

/// @title SplitTransferAction
/// @notice Leaf that pays its input to a list of recipients computed by a splitter (ratios,
///         gauge votes, ...). Postcondition: every recipient received its allocations, summed per
///         recipient so one listed twice can't hide a failed transfer.
/// @dev Rounding dust the splitter doesn't allocate stays in the DAO. Splitters must not allocate
///      to the DAO itself (use a branch with a KeepAction instead).
contract SplitTransferAction is INodeAction, DaoAuthorizableUpgradeable {
    /// @notice Computes the recipients and amounts
    ISplitter public splitter;

    error NoSplitter();
    /// @notice Thrown when the splitter belongs to another DAO, or is an implementation
    error ForeignSplitter();
    error AllocationExceedsInput(uint256 allocated, uint256 input);
    error ReceiptShortfall(IERC20 token, address recipient, uint256 expected, uint256 actual);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @dev The splitter must already be initialized for the same DAO
    function initialize(IDAO _dao, ISplitter _splitter) external initializer {
        if (address(_splitter) == address(0)) revert NoSplitter();
        if (DaoAuthorizableUpgradeable(address(_splitter)).dao() != _dao) revert ForeignSplitter();
        __DaoAuthorizableUpgradeable_init(_dao);
        splitter = _splitter;
    }

    /// @inheritdoc INodeAction
    function budget() external pure returns (IBudget) {}

    /// @inheritdoc INodeAction
    function preconditions(address, Plan calldata) external view virtual {}

    /// @inheritdoc INodeAction
    function build(address, bytes calldata, Plan calldata _draft)
        external
        view
        virtual
        returns (Plan memory _plan, Action[] memory _actions)
    {
        Allocation[] memory _allocations = _allocate(_draft.inAmount);
        _plan = Plan(_draft.inToken, _draft.inAmount, _draft.inToken, 0, _draft.beneficiary);

        uint256 _count;
        for (uint256 i; i < _allocations.length; ++i) {
            if (_allocations[i].amount != 0) ++_count;
        }
        _actions = new Action[](_count);
        uint256 _j;
        for (uint256 i; i < _allocations.length; ++i) {
            if (_allocations[i].amount == 0) continue;
            _actions[_j++] = transferAction(_draft.inToken, _allocations[i].recipient, _allocations[i].amount);
        }
    }

    /// @inheritdoc INodeAction
    function postconditions(address, Plan calldata _plan) external view virtual returns (Action[] memory _checks) {
        Allocation[] memory _allocations = _allocate(_plan.inAmount);

        // Sum per recipient, starting from its current balance
        address[] memory _recipients = new address[](_allocations.length);
        uint256[] memory _minBalances = new uint256[](_allocations.length);
        uint256 _unique;
        for (uint256 i; i < _allocations.length; ++i) {
            if (_allocations[i].amount == 0) continue;
            uint256 k;
            while (k < _unique && _recipients[k] != _allocations[i].recipient) ++k;
            if (k == _unique) {
                _recipients[k] = _allocations[i].recipient;
                _minBalances[k] = tokenBalance(_plan.inToken, _recipients[k]);
                ++_unique;
            }
            _minBalances[k] += _allocations[i].amount;
        }

        address[] memory _accounts = new address[](_unique);
        uint256[] memory _minimums = new uint256[](_unique);
        for (uint256 k; k < _unique; ++k) {
            (_accounts[k], _minimums[k]) = (_recipients[k], _minBalances[k]);
        }

        _checks = new Action[](1);
        _checks[0] = Action({
            to: address(this),
            value: 0,
            data: abi.encodeCall(this.assertReceivedAll, (_plan.inToken, _accounts, _minimums))
        });
    }

    /// @notice Reverts unless every recipient holds at least its minimum balance
    /// @dev Executed by the DAO right after the transfers. View, so harmless to call from anywhere.
    function assertReceivedAll(IERC20 _token, address[] calldata _recipients, uint256[] calldata _minBalances)
        external
        view
    {
        for (uint256 i; i < _recipients.length; ++i) {
            uint256 _balance = tokenBalance(_token, _recipients[i]);
            if (_balance < _minBalances[i]) {
                revert ReceiptShortfall(_token, _recipients[i], _minBalances[i], _balance);
            }
        }
    }

    function _allocate(uint256 _amount) internal view returns (Allocation[] memory _allocations) {
        _allocations = splitter.split(_amount);
        uint256 _total;
        for (uint256 i; i < _allocations.length; ++i) {
            _total += _allocations[i].amount;
        }
        if (_total > _amount) revert AllocationExceedsInput(_total, _amount);
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
import {
    DaoAuthorizableUpgradeable
} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizableUpgradeable.sol";
import {IBudget} from "./interfaces/IBudget.sol";
import {INodeAction} from "./interfaces/INodeAction.sol";
import {Plan, Node} from "./lib/types.sol";
import {
    TRIGGER_PERMISSION_ID,
    CONFIGURE_PERMISSION_ID,
    MANAGER_PERMISSION_ID,
    RATIO_BASE,
    MAX_NODES
} from "./lib/constants.sol";
import {tokenBalance, isToken} from "./lib/tokens.sol";

/// @title CapitalPipelinePlugin
/// @notice Runs one flow: a budget feeding a tree of actions. The budget is read once; the root
///         node takes up to what it allows; every node passes its output to its children (split by
///         fixed weights when there are several); leaves consume what they receive (transfer, burn,
///         keep). The budget commits once, after the whole tree ran.
/// @dev Every node must succeed: the root takes a non-zero amount, every other node takes exactly
///      its input, and leaves output nothing. Anything else reverts the whole trigger.
///      Each node with an action is planned (view) right after its parent ran and executes in its
///      own `dao.execute`, followed by balance checks: the DAO spent no more than the node's input
///      and received at least its declared output. Recipient checks are the actions' own postconditions.
contract CapitalPipelinePlugin is PluginCloneable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    /// @notice What the flow may spend; read at the start, committed at the end
    IBudget public budget;

    Node[] internal _nodes;

    /// @dev Makes every execution ID unique
    uint256 internal _nonce;

    event FlowUpdated(IBudget budget, Node[] nodes);
    event NodeExecuted(uint256 indexed nodeIndex, address indexed caller, bytes32 executionId, Plan plan);
    event BudgetCommitted(bytes32 executionId);

    // Configuration errors
    error NoBudget();
    error ForeignComponent(address component);
    error InvalidNodeCount(uint256 count);
    error MissingAction(uint256 nodeIndex);
    error InvalidChild(uint256 nodeIndex, uint256 childIndex);
    error UnreachableNode(uint256 nodeIndex);
    error InvalidWeights(uint256 nodeIndex);
    error BudgetMismatch(uint256 nodeIndex);

    // Trigger errors
    error DataLengthMismatch(uint256 expected, uint256 actual);
    error EmptyInput(uint256 nodeIndex);
    error InputTokenMismatch(uint256 nodeIndex);
    error InAmountExceedsInput(uint256 nodeIndex, uint256 inAmount, uint256 input);
    error NodeIncomplete(uint256 nodeIndex, uint256 inAmount, uint256 input);
    error LeafLeftOutput(uint256 nodeIndex, uint256 outAmount);
    error InvalidOutToken(uint256 nodeIndex);
    error BeneficiaryChanged(uint256 nodeIndex);
    error ActionTargetsDao(uint256 nodeIndex, uint256 actionIndex);
    error ActionTargetsPlugin(uint256 nodeIndex, uint256 actionIndex);
    error UnexpectedBalance(uint256 nodeIndex, address token, uint256 expected, uint256 actual);

    function initialize(IDAO _dao, IBudget _budget, Node[] calldata _newNodes) external initializer {
        __PluginCloneable_init(_dao);
        __Pausable_init();
        __ReentrancyGuard_init();
        _setFlow(_budget, _newNodes);
    }

    /// @notice Runs the flow
    /// @param _data Empty, or one entry per node (passed to that node's action)
    function trigger(bytes[] calldata _data) external nonReentrant whenNotPaused auth(TRIGGER_PERMISSION_ID) {
        uint256 _len = _nodes.length;
        if (_data.length != 0 && _data.length != _len) revert DataLengthMismatch(_len, _data.length);

        uint256 _callNonce = _nonce++;
        IERC20 _token = budget.token();
        uint256 _available = budget.available();

        Plan memory _root = _runNode(0, Plan(_token, _available, _token, _available, address(0)), _data, _callNonce);
        _commitBudget(_root, _callNonce);
    }

    /// @notice Replaces the flow. DAO only: an action can return arbitrary DAO actions.
    function setFlow(IBudget _budget, Node[] calldata _newNodes) external nonReentrant auth(CONFIGURE_PERMISSION_ID) {
        _setFlow(_budget, _newNodes);
    }

    /// @notice Stops the flow until `unpause`
    function pause() external auth(MANAGER_PERMISSION_ID) {
        _pause();
    }

    /// @notice Resumes the flow
    function unpause() external auth(MANAGER_PERMISSION_ID) {
        _unpause();
    }

    function nodes() external view returns (Node[] memory) {
        return _nodes;
    }

    // Running the tree

    /// @dev Runs node `_index` on `_input`, then its children, depth first. Returns the node's plan.
    function _runNode(uint256 _index, Plan memory _input, bytes[] calldata _data, uint256 _callNonce)
        internal
        returns (Plan memory _plan)
    {
        if (_input.inAmount == 0) revert EmptyInput(_index);

        Node storage _node = _nodes[_index];
        if (address(_node.action) == address(0)) {
            _plan = _input; // a branch without an action passes its input on
        } else {
            bytes calldata _nodeData = _data.length == 0 ? msg.data[0:0] : _data[_index];
            _plan = _runAction(_index, _node.action, _input, _nodeData, _node.children.length == 0, _callNonce);
        }

        _runChildren(_node, _plan, _data, _callNonce);
    }

    function _runChildren(Node storage _node, Plan memory _plan, bytes[] calldata _data, uint256 _callNonce) internal {
        uint256 _count = _node.children.length;
        if (_count == 0) return;
        if (_count == 1) {
            _runNode(_node.children[0], _childInput(_plan, _plan.outAmount), _data, _callNonce);
            return;
        }

        uint256[] memory _amounts = _weighted(_plan.outAmount, _node.weights);
        for (uint256 k; k < _count; ++k) {
            _runNode(_node.children[k], _childInput(_plan, _amounts[k]), _data, _callNonce);
        }
    }

    function _runAction(
        uint256 _index,
        INodeAction _action,
        Plan memory _draft,
        bytes calldata _data,
        bool _leaf,
        uint256 _callNonce
    ) internal returns (Plan memory _plan) {
        Action[] memory _actions;
        (_plan, _actions) = _planAction(_index, _action, _draft, _data, _leaf);

        (uint256 _inBefore, uint256 _outBefore) = _snapshot(_plan);
        bytes32 _executionId = keccak256(abi.encode(address(this), _callNonce, _index));
        _execute(_index, _actions, _executionId);
        _verify(_index, _plan, _inBefore, _outBefore);

        emit NodeExecuted(_index, msg.sender, _executionId, _plan);
    }

    /// @dev Calls the action's hooks in order and checks its plan against the node's input
    function _planAction(uint256 _index, INodeAction _action, Plan memory _draft, bytes calldata _data, bool _leaf)
        internal
        view
        returns (Plan memory _plan, Action[] memory _actions)
    {
        _action.preconditions(msg.sender, _draft);
        Action[] memory _work;
        (_plan, _work) = _action.build(msg.sender, _data, _draft);

        if (_plan.inAmount > _draft.inAmount) revert InAmountExceedsInput(_index, _plan.inAmount, _draft.inAmount);
        // The root may take less than the budget allows (but something); every other node takes all of it
        if (_plan.inAmount == 0 || (_index != 0 && _plan.inAmount != _draft.inAmount)) {
            revert NodeIncomplete(_index, _plan.inAmount, _draft.inAmount);
        }
        if (_plan.inToken != _draft.inToken) revert InputTokenMismatch(_index);
        if (_leaf && _plan.outAmount != 0) revert LeafLeftOutput(_index, _plan.outAmount);
        if (_plan.outAmount != 0 && !isToken(_plan.outToken)) revert InvalidOutToken(_index);
        _plan.beneficiary = _keepBeneficiary(_index, _draft.beneficiary, _plan.beneficiary);

        _actions = _concat(_work, _action.postconditions(msg.sender, _plan));
    }

    function _execute(uint256 _index, Action[] memory _actions, bytes32 _executionId) internal {
        if (_actions.length == 0) return;

        address _dao = address(dao());
        for (uint256 i; i < _actions.length; ++i) {
            if (_actions[i].to == _dao) revert ActionTargetsDao(_index, i);
            if (_actions[i].to == address(this)) revert ActionTargetsPlugin(_index, i);
        }
        IExecutor(_dao).execute(_executionId, _actions, 0);
    }

    /// @dev After the whole tree ran, so a stream checkpoint sees the final balance
    function _commitBudget(Plan memory _root, uint256 _callNonce) internal {
        Action[] memory _actions = budget.commitActions(_root);
        if (_actions.length == 0) return;

        bytes32 _executionId = keccak256(abi.encode(address(this), _callNonce, type(uint256).max));
        _execute(_nodes.length, _actions, _executionId);
        emit BudgetCommitted(_executionId);
    }

    // Balance checks

    function _snapshot(Plan memory _plan) internal view returns (uint256 _inBefore, uint256 _outBefore) {
        address _dao = address(dao());
        _inBefore = tokenBalance(_plan.inToken, _dao);
        if (_plan.outToken != _plan.inToken && _plan.outAmount != 0) _outBefore = tokenBalance(_plan.outToken, _dao);
    }

    /// @dev The DAO spent at most `inAmount` and received at least `outAmount`
    function _verify(uint256 _index, Plan memory _plan, uint256 _inBefore, uint256 _outBefore) internal view {
        if (_plan.outToken == _plan.inToken) {
            _checkDao(_index, _plan.inToken, _inBefore + _plan.outAmount, _plan.inAmount);
        } else {
            _checkDao(_index, _plan.inToken, _inBefore, _plan.inAmount);
            if (_plan.outAmount != 0) _checkDao(_index, _plan.outToken, _outBefore + _plan.outAmount, 0);
        }
    }

    /// @dev Reverts unless `balance + spent >= target`
    function _checkDao(uint256 _index, IERC20 _token, uint256 _target, uint256 _spent) internal view {
        uint256 _actual = tokenBalance(_token, address(dao()));
        if (_actual + _spent < _target) {
            revert UnexpectedBalance(_index, address(_token), _target > _spent ? _target - _spent : 0, _actual);
        }
    }

    // Helpers

    function _childInput(Plan memory _plan, uint256 _amount) internal pure returns (Plan memory) {
        return Plan(_plan.outToken, _amount, _plan.outToken, _amount, _plan.beneficiary);
    }

    /// @dev Splits `_amount` by `_weights`; the rounding remainder goes to the largest weight
    function _weighted(uint256 _amount, uint32[] storage _weights) internal view returns (uint256[] memory _amounts) {
        uint256 _count = _weights.length;
        _amounts = new uint256[](_count);

        uint256 _assigned;
        uint256 _largest;
        for (uint256 k; k < _count; ++k) {
            _amounts[k] = (_amount * _weights[k]) / RATIO_BASE;
            _assigned += _amounts[k];
            if (_weights[k] > _weights[_largest]) _largest = k;
        }
        _amounts[_largest] += _amount - _assigned;
    }

    /// @dev Once set, the beneficiary carries on; an action may leave it unset but not change it
    function _keepBeneficiary(uint256 _index, address _current, address _proposed) internal pure returns (address) {
        if (_current == address(0) || _proposed == _current) return _proposed;
        if (_proposed == address(0)) return _current;
        revert BeneficiaryChanged(_index);
    }

    function _concat(Action[] memory _a, Action[] memory _b) internal pure returns (Action[] memory _out) {
        _out = new Action[](_a.length + _b.length);
        for (uint256 i; i < _a.length; ++i) {
            _out[i] = _a[i];
        }
        for (uint256 i; i < _b.length; ++i) {
            _out[_a.length + i] = _b[i];
        }
    }

    // Configuration

    function _setFlow(IBudget _budget, Node[] calldata _newNodes) internal {
        if (address(_budget) == address(0)) revert NoBudget();
        _checkOwnDao(address(_budget));
        uint256 _len = _newNodes.length;
        if (_len == 0 || _len > MAX_NODES) revert InvalidNodeCount(_len);

        delete _nodes;
        bool[] memory _hasParent = new bool[](_len);
        for (uint256 i; i < _len; ++i) {
            _checkNode(i, _newNodes[i], _budget, _hasParent);

            Node storage _stored = _nodes.push();
            _stored.action = _newNodes[i].action;
            _stored.children = _newNodes[i].children;
            _stored.weights = _newNodes[i].weights;
        }
        for (uint256 i = 1; i < _len; ++i) {
            if (!_hasParent[i]) revert UnreachableNode(i);
        }
        budget = _budget;

        emit FlowUpdated(_budget, _newNodes);
    }

    /// @dev Children come after their parent and have exactly one parent, so the nodes form a tree
    ///      rooted at node 0 with no cycles. Weights are only for branches and sum to RATIO_BASE.
    function _checkNode(uint256 _index, Node calldata _node, IBudget _budget, bool[] memory _hasParent) internal view {
        uint256 _count = _node.children.length;
        if (address(_node.action) == address(0)) {
            if (_count < 2) revert MissingAction(_index);
        } else {
            _checkOwnDao(address(_node.action));
            IBudget _bound = _node.action.budget();
            if (address(_bound) != address(0) && (_index != 0 || _bound != _budget)) revert BudgetMismatch(_index);
        }

        for (uint256 k; k < _count; ++k) {
            uint256 _child = _node.children[k];
            if (_child <= _index || _child >= _hasParent.length || _hasParent[_child]) {
                revert InvalidChild(_index, _child);
            }
            _hasParent[_child] = true;
        }

        if (_count < 2) {
            if (_node.weights.length != 0) revert InvalidWeights(_index);
            return;
        }
        if (_node.weights.length != _count) revert InvalidWeights(_index);
        uint256 _sum;
        for (uint256 k; k < _count; ++k) {
            if (_node.weights[k] == 0) revert InvalidWeights(_index);
            _sum += _node.weights[k];
        }
        if (_sum != RATIO_BASE) revert InvalidWeights(_index);
    }

    /// @dev Every component is a clone initialized for this plugin's DAO. Implementations (bound to
    ///      no DAO) and other DAOs' components are rejected.
    function _checkOwnDao(address _component) internal view {
        if (DaoAuthorizableUpgradeable(_component).dao() != dao()) revert ForeignComponent(_component);
    }
}
```

**Step 15: Replace `src/setup/CapitalPipelinePluginSetup.sol`** (only the `SplitTransferAction.initialize` call changes)

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
import {SplitTransferAction} from "../actions/SplitTransferAction.sol";
import {ISplitter} from "../interfaces/ISplitter.sol";
import {ICheckpointedBudget} from "../interfaces/IBudget.sol";
import {Node} from "../lib/types.sol";
import {
    TRIGGER_PERMISSION_ID,
    CONFIGURE_PERMISSION_ID,
    MANAGER_PERMISSION_ID,
    CHECKPOINT_PERMISSION_ID
} from "../lib/constants.sol";

/// @title CapitalPipelinePluginSetup
/// @notice Installs a plugin with a swap-and-split flow: FundedStreamBudget feeding a two-node tree,
///         OpenFillAction → SplitTransferAction(RatioSplitter). Deploys every component as a clone.
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
    address public immutable splitTransferImplementation;

    constructor() PluginSetup(address(new CapitalPipelinePlugin())) {
        budgetImplementation = address(new FundedStreamBudget());
        actionImplementation = address(new OpenFillAction());
        splitterImplementation = address(new RatioSplitter());
        splitTransferImplementation = address(new SplitTransferAction());
    }

    /// @inheritdoc IPluginSetup
    /// @dev `_data` is `abi.encode(InstallParams)`. Helpers: [budget, action, splitter, splitTransfer].
    function prepareInstallation(address _dao, bytes calldata _data)
        external
        returns (address plugin, PreparedSetupData memory preparedSetupData)
    {
        InstallParams memory _params = abi.decode(_data, (InstallParams));

        address[] memory _helpers = _deployComponents(IDAO(_dao), _params);

        Node[] memory _nodes = new Node[](2);
        _nodes[0].action = OpenFillAction(_helpers[1]);
        _nodes[0].children = new uint32[](1);
        _nodes[0].children[0] = 1;
        _nodes[1].action = SplitTransferAction(_helpers[3]);

        plugin = ProxyLib.deployMinimalProxy(
            implementation(),
            abi.encodeCall(CapitalPipelinePlugin.initialize, (IDAO(_dao), FundedStreamBudget(_helpers[0]), _nodes))
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
        _helpers = new address[](4);
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
        _helpers[3] = ProxyLib.deployMinimalProxy(
            splitTransferImplementation, abi.encodeCall(SplitTransferAction.initialize, (_dao, ISplitter(_helpers[2])))
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
Expected: `116 tests passed, 0 failed` (the plugin suite alone: `40 passed`, the leaf suite `14 passed`)

Run: `forge fmt --check`
Expected: no output

**Step 17: Commit**

```bash
git add -A src test
git commit -m "Bind every component to its DAO and reject the rest

Shared Burn, Keep and TransferToBeneficiary deployments meant an
implementation could run in any DAO's flow. Every component is now a
clone initialized for one DAO, implementations lock their initializers,
and the plugin rejects any budget or action bound to another DAO or to
none, so implementations can never be used directly."
```

---

### Task 2: Registry, recipe setup, recipes and deploy script

**Files:**
- Create (tests first): `test/ComponentRegistry.t.sol`
- Modify (tests first): `test/CapitalPipelinePluginSetup.t.sol`
- Create: `src/lib/placeholders.sol`, `src/registry/ComponentRegistry.sol`, `script/Recipes.sol`, `script/Deploy.s.sol`
- Modify: `src/setup/CapitalPipelinePluginSetup.sol`

**Step 1: Create `test/ComponentRegistry.t.sol`**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {DaoUnauthorized} from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import {ComponentRegistry} from "../src/registry/ComponentRegistry.sol";
import {KeepAction} from "../src/actions/KeepAction.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {Recipes} from "../script/Recipes.sol";
import {Fixture} from "./helpers/Fixture.sol";

contract ComponentRegistryTest is Fixture {
    ComponentRegistry internal registry;
    address internal newKeep;

    function setUp() public override {
        super.setUp();
        (registry,) = new Deploy().deploy(dao);
        newKeep = address(new KeepAction());
        dao.grant(address(registry), manager, registry.REGISTER_PERMISSION_ID());
    }

    function test_RegistersTheInitialComponents() public view {
        address _openFill = registry.implementation(Recipes.OPEN_FILL);
        assertGt(_openFill.code.length, 0);
    }

    function test_ManagingDaoRegistersMore() public {
        vm.prank(manager);
        registry.register(ComponentRegistry.Registration("KeepAction@2", newKeep, "ipfs://keep"));

        assertEq(registry.implementation("KeepAction@2"), newKeep);
        (, bytes memory _metadata) = registry.entries("KeepAction@2");
        assertEq(_metadata, "ipfs://keep");
    }

    function test_RevertWhen_TheIdIsTaken() public {
        vm.expectRevert(abi.encodeWithSelector(ComponentRegistry.AlreadyRegistered.selector, Recipes.KEEP));
        vm.prank(manager);
        registry.register(ComponentRegistry.Registration(Recipes.KEEP, newKeep, ""));
    }

    function test_RevertWhen_RegisterUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector,
                address(dao),
                address(registry),
                address(this),
                registry.REGISTER_PERMISSION_ID()
            )
        );
        registry.register(ComponentRegistry.Registration("KeepAction@2", newKeep, ""));
    }

    function test_RevertWhen_TheImplementationHasNoCode() public {
        vm.expectRevert(abi.encodeWithSelector(ComponentRegistry.NotAContract.selector, address(0xBEEF)));
        vm.prank(manager);
        registry.register(ComponentRegistry.Registration("KeepAction@2", address(0xBEEF), ""));
    }

    function test_RevertWhen_TheIdIsUnknown() public {
        vm.expectRevert(abi.encodeWithSelector(ComponentRegistry.UnknownComponent.selector, bytes32("Unknown@1")));
        registry.implementation("Unknown@1");
    }
}
```

**Step 2: Replace `test/CapitalPipelinePluginSetup.t.sol`** (installs every recipe through the deploy script)

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    DaoAuthorizableUpgradeable
} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizableUpgradeable.sol";
import {IPluginSetup} from "@aragon/osx-commons-contracts/src/plugin/setup/IPluginSetup.sol";
import {PermissionLib} from "@aragon/osx-commons-contracts/src/permission/PermissionLib.sol";
import {CapitalPipelinePluginSetup} from "../src/setup/CapitalPipelinePluginSetup.sol";
import {CapitalPipelinePlugin} from "../src/CapitalPipelinePlugin.sol";
import {ComponentRegistry} from "../src/registry/ComponentRegistry.sol";
import {INodeAction} from "../src/interfaces/INodeAction.sol";
import {
    TRIGGER_PERMISSION_ID,
    CONFIGURE_PERMISSION_ID,
    MANAGER_PERMISSION_ID,
    CHECKPOINT_PERMISSION_ID
} from "../src/lib/constants.sol";
import {DAO_REF, PLUGIN_REF, ref} from "../src/lib/placeholders.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {Recipes} from "../script/Recipes.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {MockFiller} from "./mocks/MockFiller.sol";

contract CapitalPipelinePluginSetupTest is Fixture {
    ComponentRegistry internal registry;
    CapitalPipelinePluginSetup internal setup;

    function setUp() public override {
        super.setUp();
        (registry, setup) = new Deploy().deploy(dao);
    }

    // =========================================================================================
    // Recipes
    // =========================================================================================

    function test_SwapAndSplitFillsAndSplits() public {
        (CapitalPipelinePlugin _plugin,) = _install(_swapAndSplit());
        MockFiller _filler = _newFiller(_plugin);

        _filler.fill("");

        assertEq(tokenB.balanceOf(BURN), 950 ether);
        assertEq(tokenB.balanceOf(fee), 50 ether);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B);
    }

    function test_BuybackBurnsAndPaysTheFee() public {
        (CapitalPipelinePlugin _plugin,) = _install(Recipes.buyback(manager, _stream(), _swap(), fee, 50_000));
        MockFiller _filler = _newFiller(_plugin);
        uint256 _supply = tokenB.totalSupply();

        _filler.fill("");

        assertEq(tokenB.totalSupply(), _supply - 950 ether);
        assertEq(tokenB.balanceOf(fee), 50 ether);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B);
    }

    function test_MerkleClaimPaysTheAccount() public {
        bytes32 _aliceLeaf = _leafHash(alice, 10 ether);
        bytes32 _bobLeaf = _leafHash(bob, 30 ether);
        (CapitalPipelinePlugin _plugin,) =
            _install(Recipes.merkleClaim(manager, IERC20(tokenA), _hashPair(_aliceLeaf, _bobLeaf)));

        bytes32[] memory _proof = new bytes32[](1);
        _proof[0] = _bobLeaf;
        bytes[] memory _data = new bytes[](2);
        _data[0] = abi.encode(alice, 10 ether, _proof, address(0));

        vm.prank(alice);
        _plugin.trigger(_data);

        assertEq(tokenA.balanceOf(alice), 10 ether);
    }

    function test_PayrollPaysEachRecipient() public {
        (CapitalPipelinePlugin _plugin,) = _install(Recipes.payroll(manager, _stream(), _pair(alice, bob), _ratios()));
        vm.warp(block.timestamp + EPOCH);

        _plugin.trigger(noData);

        assertEq(tokenA.balanceOf(alice), 9.5 ether);
        assertEq(tokenA.balanceOf(bob), 0.5 ether);
    }

    // =========================================================================================
    // Components and permissions
    // =========================================================================================

    function test_EveryComponentIsAFreshCloneOfTheDao() public {
        (, address[] memory _first) = _install(_swapAndSplit());
        (, address[] memory _second) = _install(_swapAndSplit());

        for (uint256 i; i < _first.length; ++i) {
            assertTrue(_first[i] != _second[i], "a new clone per install");
            assertEq(address(DaoAuthorizableUpgradeable(_first[i]).dao()), address(dao));
        }
        assertTrue(_first[1] != registry.implementation(Recipes.OPEN_FILL), "never the implementation");
    }

    function test_GrantsTheRecipePermissions() public {
        (CapitalPipelinePlugin _plugin, address[] memory _helpers) = _install(_swapAndSplit());

        _assertPermissions(address(_plugin), _helpers, true);
        assertFalse(
            dao.hasPermission(address(_plugin), manager, CONFIGURE_PERMISSION_ID, ""), "manager can't set the flow"
        );
    }

    function test_UninstallRevokesEverything() public {
        CapitalPipelinePluginSetup.InstallParams memory _params = _swapAndSplit();
        (CapitalPipelinePlugin _plugin, address[] memory _helpers) = _install(_params);

        dao.applyMultiTargetPermissions(_prepareUninstall(_plugin, _helpers, _params.grants));

        _assertPermissions(address(_plugin), _helpers, false);
    }

    function test_RevertWhen_UninstallGrantsDiffer() public {
        CapitalPipelinePluginSetup.InstallParams memory _params = _swapAndSplit();
        (CapitalPipelinePlugin _plugin, address[] memory _helpers) = _install(_params);
        CapitalPipelinePluginSetup.Grant[] memory _fewer = new CapitalPipelinePluginSetup.Grant[](1);
        _fewer[0] = _params.grants[0];

        vm.expectRevert(CapitalPipelinePluginSetup.GrantsMismatch.selector);
        _prepareUninstall(_plugin, _helpers, _fewer);
    }

    // =========================================================================================
    // Rejected recipes
    // =========================================================================================

    function test_RevertWhen_AComponentIsNotRegistered() public {
        CapitalPipelinePluginSetup.InstallParams memory _params = _swapAndSplit();
        _params.components[0].id = "Unknown@1";

        _expectInstallRevert(
            _params, abi.encodeWithSelector(ComponentRegistry.UnknownComponent.selector, bytes32("Unknown@1"))
        );
    }

    function test_RevertWhen_AReferenceIsUnknown() public {
        CapitalPipelinePluginSetup.InstallParams memory _params = _swapAndSplit();
        _params.nodes[1].action = INodeAction(ref(9));

        _expectInstallRevert(_params, abi.encodeWithSelector(CapitalPipelinePluginSetup.UnknownReference.selector, 9));
    }

    function test_RevertWhen_AGrantTargetsTheDao() public {
        CapitalPipelinePluginSetup.InstallParams memory _params = _swapAndSplit();
        _params.grants[0] = CapitalPipelinePluginSetup.Grant(DAO_REF, manager, keccak256("ROOT_PERMISSION"));

        _expectInstallRevert(
            _params, abi.encodeWithSelector(CapitalPipelinePluginSetup.GrantOutsideInstallation.selector, DAO_REF)
        );
    }

    function test_RevertWhen_AGrantTargetsAnOutsideContract() public {
        CapitalPipelinePluginSetup.InstallParams memory _params = _swapAndSplit();
        _params.grants[0] = CapitalPipelinePluginSetup.Grant(address(tokenA), manager, MANAGER_PERMISSION_ID);

        _expectInstallRevert(
            _params,
            abi.encodeWithSelector(CapitalPipelinePluginSetup.GrantOutsideInstallation.selector, address(tokenA))
        );
    }

    function test_RevertWhen_AGrantGivesConfigure() public {
        CapitalPipelinePluginSetup.InstallParams memory _params = _swapAndSplit();
        _params.grants[1] = CapitalPipelinePluginSetup.Grant(PLUGIN_REF, manager, CONFIGURE_PERMISSION_ID);

        _expectInstallRevert(
            _params,
            abi.encodeWithSelector(CapitalPipelinePluginSetup.ReservedPermission.selector, CONFIGURE_PERMISSION_ID)
        );
    }

    // =========================================================================================
    // Helpers
    // =========================================================================================

    function _install(CapitalPipelinePluginSetup.InstallParams memory _params)
        internal
        returns (CapitalPipelinePlugin _plugin, address[] memory _helpers)
    {
        (address _pluginAddress, IPluginSetup.PreparedSetupData memory _prepared) =
            setup.prepareInstallation(address(dao), abi.encode(_params));
        dao.applyMultiTargetPermissions(_prepared.permissions);

        return (CapitalPipelinePlugin(_pluginAddress), _prepared.helpers);
    }

    function _expectInstallRevert(CapitalPipelinePluginSetup.InstallParams memory _params, bytes memory _error)
        internal
    {
        bytes memory _data = abi.encode(_params);
        vm.expectRevert(_error);
        setup.prepareInstallation(address(dao), _data);
    }

    function _prepareUninstall(
        CapitalPipelinePlugin _plugin,
        address[] memory _helpers,
        CapitalPipelinePluginSetup.Grant[] memory _grants
    ) internal view returns (PermissionLib.MultiTargetPermission[] memory) {
        return setup.prepareUninstallation(
            address(dao),
            IPluginSetup.SetupPayload({plugin: address(_plugin), currentHelpers: _helpers, data: abi.encode(_grants)})
        );
    }

    /// @dev Swap 10 A for 1,000 B, then pay 95% to the burn address and 5% to the fee address
    function _swapAndSplit() internal view returns (CapitalPipelinePluginSetup.InstallParams memory) {
        return Recipes.swapAndSplit(manager, _stream(), _swap(), _pair(BURN, fee), _ratios());
    }

    function _stream() internal view returns (Recipes.Stream memory) {
        return Recipes.Stream({token: IERC20(tokenA), amountPerEpoch: RATE, maxBudget: 0, epochInterval: EPOCH});
    }

    function _swap() internal view returns (Recipes.Swap memory) {
        return Recipes.Swap({demandedToken: IERC20(tokenB), demandPerFill: DEMAND, minDemandedPerOffered: MIN_PRICE});
    }

    function _pair(address _a, address _b) internal pure returns (address[] memory _recipients) {
        _recipients = new address[](2);
        (_recipients[0], _recipients[1]) = (_a, _b);
    }

    function _ratios() internal pure returns (uint32[] memory _shares) {
        _shares = new uint32[](2);
        (_shares[0], _shares[1]) = (950_000, 50_000);
    }

    function _newFiller(CapitalPipelinePlugin _plugin) internal returns (MockFiller _mock) {
        _mock = new MockFiller(_plugin);
        tokenB.mint(address(_mock), 1_000_000 ether);
        vm.warp(block.timestamp + EPOCH);
    }

    function _leafHash(address _account, uint256 _cumulative) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(_account, _cumulative))));
    }

    function _hashPair(bytes32 _a, bytes32 _b) internal pure returns (bytes32) {
        return _a < _b ? keccak256(abi.encode(_a, _b)) : keccak256(abi.encode(_b, _a));
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
```

**Step 3: Run the tests to make sure they fail**

Run: `forge build`
Expected: compilation fails with `Source "src/registry/ComponentRegistry.sol" not found` (and `src/lib/placeholders.sol`)

**Step 4: Create `src/lib/placeholders.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

/// @dev Placeholder addresses for contracts a recipe can't know yet: the DAO, the plugin and the
///      recipe's own components. The setup replaces them wherever they appear (init data, budget,
///      node actions, grants). The upper bits are a fixed tag, the lower 16 bits say what it
///      stands for.
uint160 constant PLACEHOLDER_TAG = uint160(uint256(keccak256("capital-pipeline.placeholder"))) & ~uint160(0xFFFF);
uint256 constant DAO_INDEX = 0xFFFF;
uint256 constant PLUGIN_INDEX = 0xFFFE;

address constant DAO_REF = address(PLACEHOLDER_TAG | uint160(DAO_INDEX));
address constant PLUGIN_REF = address(PLACEHOLDER_TAG | uint160(PLUGIN_INDEX));

/// @notice Placeholder for the clone of the recipe's component `_index`
function ref(uint256 _index) pure returns (address) {
    return address(PLACEHOLDER_TAG | uint160(_index));
}

/// @notice Whether a 32-byte word is a placeholder
function isPlaceholder(uint256 _word) pure returns (bool) {
    return _word >> 16 == uint256(PLACEHOLDER_TAG) >> 16;
}
```

**Step 5: Create `src/registry/ComponentRegistry.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {DaoAuthorizable} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizable.sol";

/// @title ComponentRegistry
/// @notice Names the component implementations that recipes can clone. Entries are write-once,
///         so an id always means the same code and a recipe can't change under a vote.
/// @dev Maintained through a managing DAO's permissions (`REGISTER_PERMISSION_ID`)
contract ComponentRegistry is DaoAuthorizable {
    bytes32 public constant REGISTER_PERMISSION_ID = keccak256("REGISTER_PERMISSION");

    struct Registration {
        bytes32 id;
        address implementation;
        bytes metadata;
    }

    struct Entry {
        address implementation;
        bytes metadata;
    }

    /// @notice Registered components by id, e.g. "OpenFillAction@1"
    mapping(bytes32 id => Entry) public entries;

    event ComponentRegistered(bytes32 indexed id, address implementation, bytes metadata);

    error AlreadyRegistered(bytes32 id);
    error NotAContract(address implementation);
    error UnknownComponent(bytes32 id);

    /// @param _initial Registered at deployment, so the first set needs no proposal
    constructor(IDAO _managingDao, Registration[] memory _initial) DaoAuthorizable(_managingDao) {
        for (uint256 i; i < _initial.length; ++i) {
            _register(_initial[i]);
        }
    }

    function register(Registration calldata _registration) external auth(REGISTER_PERMISSION_ID) {
        _register(_registration);
    }

    /// @notice The implementation registered as `_id`; reverts if there is none
    function implementation(bytes32 _id) external view returns (address _implementation) {
        _implementation = entries[_id].implementation;
        if (_implementation == address(0)) revert UnknownComponent(_id);
    }

    function _register(Registration memory _registration) internal {
        if (entries[_registration.id].implementation != address(0)) revert AlreadyRegistered(_registration.id);
        if (_registration.implementation.code.length == 0) revert NotAContract(_registration.implementation);

        entries[_registration.id] = Entry(_registration.implementation, _registration.metadata);
        emit ComponentRegistered(_registration.id, _registration.implementation, _registration.metadata);
    }
}
```

**Step 6: Replace `src/setup/CapitalPipelinePluginSetup.sol`**

```solidity
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
```

**Step 7: Create `script/Recipes.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {CapitalPipelinePluginSetup} from "../src/setup/CapitalPipelinePluginSetup.sol";
import {FundedStreamBudget} from "../src/budgets/FundedStreamBudget.sol";
import {BalanceBudget} from "../src/budgets/BalanceBudget.sol";
import {OpenFillAction} from "../src/actions/OpenFillAction.sol";
import {MerkleClaimAction} from "../src/actions/MerkleClaimAction.sol";
import {TransferAction} from "../src/actions/TransferAction.sol";
import {TransferToBeneficiaryAction} from "../src/actions/TransferToBeneficiaryAction.sol";
import {SplitTransferAction} from "../src/actions/SplitTransferAction.sol";
import {BurnAction} from "../src/actions/BurnAction.sol";
import {RatioSplitter} from "../src/splitters/RatioSplitter.sol";
import {IBudget, ICheckpointedBudget} from "../src/interfaces/IBudget.sol";
import {INodeAction} from "../src/interfaces/INodeAction.sol";
import {ISplitter} from "../src/interfaces/ISplitter.sol";
import {Node} from "../src/lib/types.sol";
import {
    TRIGGER_PERMISSION_ID,
    MANAGER_PERMISSION_ID,
    CHECKPOINT_PERMISSION_ID,
    RECORD_CLAIM_PERMISSION_ID,
    RATIO_BASE
} from "../src/lib/constants.sol";
import {DAO_REF, PLUGIN_REF, ref} from "../src/lib/placeholders.sol";

/// @title Recipes
/// @notice Registry ids and install recipes for the common flows. A recipe is
///         `abi.encode(CapitalPipelinePluginSetup.InstallParams)`.
library Recipes {
    bytes32 internal constant FUNDED_STREAM_BUDGET = "FundedStreamBudget@1";
    bytes32 internal constant BALANCE_BUDGET = "BalanceBudget@1";
    bytes32 internal constant OPEN_FILL = "OpenFillAction@1";
    bytes32 internal constant MERKLE_CLAIM = "MerkleClaimAction@1";
    bytes32 internal constant TRANSFER = "TransferAction@1";
    bytes32 internal constant TRANSFER_TO_BENEFICIARY = "TransferToBeneficiaryAction@1";
    bytes32 internal constant SPLIT_TRANSFER = "SplitTransferAction@1";
    bytes32 internal constant BURN = "BurnAction@1";
    bytes32 internal constant KEEP = "KeepAction@1";
    bytes32 internal constant RATIO_SPLITTER = "RatioSplitter@1";

    address internal constant ANY_ADDR = address(type(uint160).max);

    struct Stream {
        IERC20 token;
        uint256 amountPerEpoch;
        uint256 maxBudget;
        uint256 epochInterval;
    }

    struct Swap {
        IERC20 demandedToken;
        uint256 demandPerFill;
        uint256 minDemandedPerOffered;
    }

    /// @notice Stream → OpenFill → pay a ratio list.
    ///         Components: 0 budget, 1 OpenFill, 2 RatioSplitter, 3 SplitTransfer.
    function swapAndSplit(
        address _manager,
        Stream memory _stream,
        Swap memory _swap,
        address[] memory _recipients,
        uint32[] memory _ratios
    ) internal pure returns (CapitalPipelinePluginSetup.InstallParams memory _params) {
        _params.components = new CapitalPipelinePluginSetup.Component[](4);
        _params.components[0] = _streamBudget(_stream);
        _params.components[1] = _openFill(_swap);
        _params.components[2] = _ratio(_recipients, _ratios);
        _params.components[3] = _splitTransfer(2);

        _params.budget = IBudget(ref(0));
        _params.nodes = new Node[](2);
        _params.nodes[0] = _then(1, 1);
        _params.nodes[1] = _leaf(3);

        _params.grants = new CapitalPipelinePluginSetup.Grant[](7);
        _params.grants[0] = _grant(PLUGIN_REF, ANY_ADDR, TRIGGER_PERMISSION_ID);
        _params.grants[1] = _grant(PLUGIN_REF, _manager, MANAGER_PERMISSION_ID);
        _params.grants[2] = _grant(ref(0), _manager, MANAGER_PERMISSION_ID);
        _params.grants[3] = _grant(ref(1), _manager, MANAGER_PERMISSION_ID);
        _params.grants[4] = _grant(ref(2), _manager, MANAGER_PERMISSION_ID);
        _params.grants[5] = _grant(ref(0), DAO_REF, CHECKPOINT_PERMISSION_ID);
        _params.grants[6] = _grant(ref(0), ref(1), CHECKPOINT_PERMISSION_ID);
    }

    /// @notice Stream → OpenFill → burn the proceeds, except `_feeWeight` (of RATIO_BASE) to `_fee`.
    ///         Components: 0 budget, 1 OpenFill, 2 Burn, 3 Transfer.
    function buyback(address _manager, Stream memory _stream, Swap memory _swap, address _fee, uint32 _feeWeight)
        internal
        pure
        returns (CapitalPipelinePluginSetup.InstallParams memory _params)
    {
        _params.components = new CapitalPipelinePluginSetup.Component[](4);
        _params.components[0] = _streamBudget(_stream);
        _params.components[1] = _openFill(_swap);
        _params.components[2] = _component(BURN, abi.encodeCall(BurnAction.initialize, (IDAO(DAO_REF))));
        _params.components[3] = _component(TRANSFER, abi.encodeCall(TransferAction.initialize, (IDAO(DAO_REF), _fee)));

        _params.budget = IBudget(ref(0));
        _params.nodes = new Node[](3);
        _params.nodes[0].action = INodeAction(ref(1));
        _params.nodes[0].children = new uint32[](2);
        (_params.nodes[0].children[0], _params.nodes[0].children[1]) = (1, 2);
        _params.nodes[0].weights = new uint32[](2);
        (_params.nodes[0].weights[0], _params.nodes[0].weights[1]) = (uint32(RATIO_BASE) - _feeWeight, _feeWeight);
        _params.nodes[1] = _leaf(2);
        _params.nodes[2] = _leaf(3);

        _params.grants = new CapitalPipelinePluginSetup.Grant[](6);
        _params.grants[0] = _grant(PLUGIN_REF, ANY_ADDR, TRIGGER_PERMISSION_ID);
        _params.grants[1] = _grant(PLUGIN_REF, _manager, MANAGER_PERMISSION_ID);
        _params.grants[2] = _grant(ref(0), _manager, MANAGER_PERMISSION_ID);
        _params.grants[3] = _grant(ref(1), _manager, MANAGER_PERMISSION_ID);
        _params.grants[4] = _grant(ref(0), DAO_REF, CHECKPOINT_PERMISSION_ID);
        _params.grants[5] = _grant(ref(0), ref(1), CHECKPOINT_PERMISSION_ID);
    }

    /// @notice The DAO's balance of `_token` → Merkle claim → pay the beneficiary.
    ///         Components: 0 budget, 1 MerkleClaim, 2 TransferToBeneficiary.
    function merkleClaim(address _manager, IERC20 _token, bytes32 _root)
        internal
        pure
        returns (CapitalPipelinePluginSetup.InstallParams memory _params)
    {
        _params.components = new CapitalPipelinePluginSetup.Component[](3);
        _params.components[0] =
            _component(BALANCE_BUDGET, abi.encodeCall(BalanceBudget.initialize, (IDAO(DAO_REF), _token)));
        _params.components[1] = _component(
            MERKLE_CLAIM, abi.encodeCall(MerkleClaimAction.initialize, (IDAO(DAO_REF), IBudget(ref(0)), _root))
        );
        _params.components[2] = _component(
            TRANSFER_TO_BENEFICIARY, abi.encodeCall(TransferToBeneficiaryAction.initialize, (IDAO(DAO_REF)))
        );

        _params.budget = IBudget(ref(0));
        _params.nodes = new Node[](2);
        _params.nodes[0] = _then(1, 1);
        _params.nodes[1] = _leaf(2);

        _params.grants = new CapitalPipelinePluginSetup.Grant[](4);
        _params.grants[0] = _grant(PLUGIN_REF, ANY_ADDR, TRIGGER_PERMISSION_ID);
        _params.grants[1] = _grant(PLUGIN_REF, _manager, MANAGER_PERMISSION_ID);
        _params.grants[2] = _grant(ref(1), _manager, MANAGER_PERMISSION_ID);
        _params.grants[3] = _grant(ref(1), DAO_REF, RECORD_CLAIM_PERMISSION_ID);
    }

    /// @notice Stream → pay a ratio list.
    ///         Components: 0 budget, 1 RatioSplitter, 2 SplitTransfer.
    function payroll(address _manager, Stream memory _stream, address[] memory _recipients, uint32[] memory _ratios)
        internal
        pure
        returns (CapitalPipelinePluginSetup.InstallParams memory _params)
    {
        _params.components = new CapitalPipelinePluginSetup.Component[](3);
        _params.components[0] = _streamBudget(_stream);
        _params.components[1] = _ratio(_recipients, _ratios);
        _params.components[2] = _splitTransfer(1);

        _params.budget = IBudget(ref(0));
        _params.nodes = new Node[](1);
        _params.nodes[0] = _leaf(2);

        _params.grants = new CapitalPipelinePluginSetup.Grant[](5);
        _params.grants[0] = _grant(PLUGIN_REF, ANY_ADDR, TRIGGER_PERMISSION_ID);
        _params.grants[1] = _grant(PLUGIN_REF, _manager, MANAGER_PERMISSION_ID);
        _params.grants[2] = _grant(ref(0), _manager, MANAGER_PERMISSION_ID);
        _params.grants[3] = _grant(ref(1), _manager, MANAGER_PERMISSION_ID);
        _params.grants[4] = _grant(ref(0), DAO_REF, CHECKPOINT_PERMISSION_ID);
    }

    // Components

    function _streamBudget(Stream memory _stream) private pure returns (CapitalPipelinePluginSetup.Component memory) {
        return _component(
            FUNDED_STREAM_BUDGET,
            abi.encodeCall(
                FundedStreamBudget.initialize,
                (IDAO(DAO_REF), _stream.token, _stream.amountPerEpoch, _stream.maxBudget, _stream.epochInterval)
            )
        );
    }

    /// @dev Bound to component 0, the budget
    function _openFill(Swap memory _swap) private pure returns (CapitalPipelinePluginSetup.Component memory) {
        return _component(
            OPEN_FILL,
            abi.encodeCall(
                OpenFillAction.initialize,
                (
                    IDAO(DAO_REF),
                    ICheckpointedBudget(ref(0)),
                    _swap.demandedToken,
                    _swap.demandPerFill,
                    _swap.minDemandedPerOffered
                )
            )
        );
    }

    function _ratio(address[] memory _recipients, uint32[] memory _ratios)
        private
        pure
        returns (CapitalPipelinePluginSetup.Component memory)
    {
        return
            _component(RATIO_SPLITTER, abi.encodeCall(RatioSplitter.initialize, (IDAO(DAO_REF), _recipients, _ratios)));
    }

    function _splitTransfer(uint256 _splitter) private pure returns (CapitalPipelinePluginSetup.Component memory) {
        return _component(
            SPLIT_TRANSFER, abi.encodeCall(SplitTransferAction.initialize, (IDAO(DAO_REF), ISplitter(ref(_splitter))))
        );
    }

    function _component(bytes32 _id, bytes memory _initData)
        private
        pure
        returns (CapitalPipelinePluginSetup.Component memory)
    {
        return CapitalPipelinePluginSetup.Component(_id, _initData);
    }

    // Tree

    function _leaf(uint256 _index) private pure returns (Node memory _node) {
        _node.action = INodeAction(ref(_index));
    }

    function _then(uint256 _index, uint32 _child) private pure returns (Node memory _node) {
        _node.action = INodeAction(ref(_index));
        _node.children = new uint32[](1);
        _node.children[0] = _child;
    }

    function _grant(address _where, address _who, bytes32 _id)
        private
        pure
        returns (CapitalPipelinePluginSetup.Grant memory)
    {
        return CapitalPipelinePluginSetup.Grant(_where, _who, _id);
    }
}
```

**Step 8: Create `script/Deploy.s.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {ComponentRegistry} from "../src/registry/ComponentRegistry.sol";
import {CapitalPipelinePluginSetup} from "../src/setup/CapitalPipelinePluginSetup.sol";
import {FundedStreamBudget} from "../src/budgets/FundedStreamBudget.sol";
import {BalanceBudget} from "../src/budgets/BalanceBudget.sol";
import {OpenFillAction} from "../src/actions/OpenFillAction.sol";
import {MerkleClaimAction} from "../src/actions/MerkleClaimAction.sol";
import {TransferAction} from "../src/actions/TransferAction.sol";
import {TransferToBeneficiaryAction} from "../src/actions/TransferToBeneficiaryAction.sol";
import {SplitTransferAction} from "../src/actions/SplitTransferAction.sol";
import {BurnAction} from "../src/actions/BurnAction.sol";
import {KeepAction} from "../src/actions/KeepAction.sol";
import {RatioSplitter} from "../src/splitters/RatioSplitter.sol";
import {Recipes} from "./Recipes.sol";

/// @notice Deploys every component implementation, a registry naming them and the plugin setup.
///         `MANAGING_DAO` maintains the registry.
/// @dev Run: `forge script script/Deploy.s.sol --rpc-url <rpc> --broadcast` with `MANAGING_DAO` set
contract Deploy is Script {
    function run() external returns (ComponentRegistry registry, CapitalPipelinePluginSetup setup) {
        IDAO _managingDao = IDAO(vm.envAddress("MANAGING_DAO"));

        vm.startBroadcast();
        (registry, setup) = deploy(_managingDao);
        vm.stopBroadcast();
    }

    function deploy(IDAO _managingDao) public returns (ComponentRegistry registry, CapitalPipelinePluginSetup setup) {
        ComponentRegistry.Registration[] memory _components = new ComponentRegistry.Registration[](10);
        _components[0] = _registration(Recipes.FUNDED_STREAM_BUDGET, address(new FundedStreamBudget()));
        _components[1] = _registration(Recipes.BALANCE_BUDGET, address(new BalanceBudget()));
        _components[2] = _registration(Recipes.OPEN_FILL, address(new OpenFillAction()));
        _components[3] = _registration(Recipes.MERKLE_CLAIM, address(new MerkleClaimAction()));
        _components[4] = _registration(Recipes.TRANSFER, address(new TransferAction()));
        _components[5] = _registration(Recipes.TRANSFER_TO_BENEFICIARY, address(new TransferToBeneficiaryAction()));
        _components[6] = _registration(Recipes.SPLIT_TRANSFER, address(new SplitTransferAction()));
        _components[7] = _registration(Recipes.BURN, address(new BurnAction()));
        _components[8] = _registration(Recipes.KEEP, address(new KeepAction()));
        _components[9] = _registration(Recipes.RATIO_SPLITTER, address(new RatioSplitter()));

        registry = new ComponentRegistry(_managingDao, _components);
        setup = new CapitalPipelinePluginSetup(registry);
    }

    function _registration(bytes32 _id, address _implementation)
        internal
        pure
        returns (ComponentRegistry.Registration memory)
    {
        return ComponentRegistry.Registration(_id, _implementation, "");
    }
}
```

**Step 9: Run the tests**

Run: `forge test`
Expected: `132 tests passed, 0 failed` (the setup suite alone: `13 passed`, the registry suite `6 passed`)

Run: `forge fmt --check`
Expected: no output

Run: `forge build --sizes 2>&1 | grep -E "\| (CapitalPipelinePluginSetup|ComponentRegistry) "`
Expected: the setup's initcode is about 19.8 KB (it was 35.7 KB), the registry's about 3.4 KB

**Step 10: Commit**

```bash
git add -A src test script
git commit -m "Install any flow from a recipe of registered components

The setup could only install one fixed tree and never deployed most
components. It now clones the implementations a recipe names from a
write-once registry, replaces placeholders for the DAO, the plugin and
the recipe's own components, and grants only what the recipe lists on
the plugin and its components. New actions need a registry entry, not a
new setup. Recipes for the common flows and a deploy script come with it."
```

---

### Task 3: README

**Files:**
- Modify: `README.md`

**Step 1: Replace `README.md`**

````markdown
# Capital Pipeline

Aragon OSx plugin that runs one treasury flow per install: a **budget** feeding a **tree of
actions**. Every node passes its output to its children, split by fixed weights when there are
several, and every branch ends in a leaf that consumes what it receives (transfer, burn, keep).
Each node runs in its own `dao.execute`, followed by balance checks, so a node can only ever spend
what the budget released or what its parent really produced.

```
budget  FundedStreamBudget(A)
└─ OpenFill (A → B)
   ├─ 95% → Burn
   └─  5% → Transfer(feeAddr)
```

Examples: sell token A in a Dutch auction and burn 95% of the proceeds, paying 5% as a fee; let
accounts claim cumulative Merkle allocations, optionally swapped before they're paid; pay a
payroll from a stream. Any ERC20 works, and native ETH as `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`.

Design: [`docs/plans/2026-11-04-capital-pipeline-design.md`](docs/plans/2026-11-04-capital-pipeline-design.md)

## Layout

| Path | What |
|---|---|
| `src/CapitalPipelinePlugin.sol` | Runs the tree, checks balances after every node |
| `src/budgets/FundedStreamBudget.sol` | Streaming pot that never jumps |
| `src/budgets/BalanceBudget.sol` | The DAO's whole balance of a token |
| `src/actions/OpenFillAction.sol` | Open-fill swap with Dutch-auction pricing (root only) |
| `src/actions/MerkleClaimAction.sol` | Cumulative Merkle claims with a redirectable beneficiary (root only) |
| `src/actions/TransferAction.sol` | Leaf: sends its input to a fixed recipient |
| `src/actions/TransferToBeneficiaryAction.sol` | Leaf: sends its input to the flow's beneficiary |
| `src/actions/SplitTransferAction.sol` | Leaf: pays a dynamic list of recipients from a splitter |
| `src/actions/BurnAction.sol` | Leaf: burns its input |
| `src/actions/KeepAction.sol` | Leaf: leaves its input in the DAO |
| `src/splitters/RatioSplitter.sol` | Fixed-ratio recipient list for `SplitTransferAction` |
| `src/registry/ComponentRegistry.sol` | Write-once ids for the implementations recipes can clone |
| `src/setup/CapitalPipelinePluginSetup.sol` | Installs any flow from a recipe |
| `script/Recipes.sol` | Recipes for swap and split, buyback, Merkle claim and payroll |
| `script/Deploy.s.sol` | Deploys every implementation, the registry and the setup |

## Permissions

| Permission | Holder | Allows |
|---|---|---|
| `TRIGGER_PERMISSION_ID` | anyone | `trigger()` |
| `CONFIGURE_PERMISSION_ID` | DAO only | `setFlow()` |
| `MANAGER_PERMISSION_ID` | manager | parameter setters, Merkle `setRoot()`, `pause()`, `unpause()` |
| `CHECKPOINT_PERMISSION_ID` | DAO, swap action | restarting the stream budget |
| `RECORD_CLAIM_PERMISSION_ID` | DAO | Merkle `recordClaim()`, run by the plugin through the DAO |
| `REGISTER_PERMISSION_ID` | picked by the managing DAO | registering new components |

The setup always grants `EXECUTE` and `CONFIGURE`; a recipe lists the rest.

## Develop

```shell
git submodule update --init --recursive
forge build
forge test
```

Never set `via_ir = true`; fix stack-too-deep errors by restructuring the code.

## Deploy

```shell
MANAGING_DAO=0x... forge script script/Deploy.s.sol --rpc-url <rpc> --broadcast
```

Then install a flow by calling `prepareInstallation` with a recipe from `script/Recipes.sol`.
Every component is a fresh clone bound to the installing DAO.
````

**Step 2: Check the paths it mentions**

Run: `ls src/registry/ComponentRegistry.sol script/Recipes.sol script/Deploy.s.sol`
Expected: all three listed, no errors

**Step 3: Commit**

```bash
git add README.md
git commit -m "Describe the registry, recipes and deployment in the README"
```
