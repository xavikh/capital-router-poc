# Capital Pipeline v3 (Trees) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use /executing-plans to implement this plan task-by-task.

**Goal:** Replace the v2 stage chain with a tree of explicit actions: a budget feeds a root node, every node passes its whole output to its children (split by fixed weights), and every branch ends in a leaf action that consumes what it receives.

**Architecture:** `CapitalPipelinePlugin` stores one `IBudget` and a `Node[]` (`{action, children, weights}`). `trigger` reads the budget once and runs the tree depth first: each node with an action is planned (preconditions → build → postconditions), executed in its own `dao.execute` and followed by DAO balance checks; its declared output feeds its children. The budget commits once at the end. Leaf actions (`Transfer`, `TransferToBeneficiary`, `SplitTransfer`, `Burn`, `Keep`) replace splitters as the way money leaves a flow.

**Tech Stack:** Solidity 0.8.28 (cancun, optimizer 200, **never via_ir**), Foundry, Aragon OSx 1.4, OpenZeppelin 4.9.6. Testing patterns: @sol-test.

**Design:** `docs/plans/2026-11-04-capital-pipeline-design.md` (v3). **Branch:** `feat/flow-stages`.

**Verified:** every code block below was compiled and tested in a scratch copy of this repo, including the state after each task. The balance-check and whole-input tests were also confirmed to fail when those checks are removed.

---

## Tasks

| # | Task | End state | Time |
|---|---|---|---|
| 1 | Drop TriggerBatch | 92 tests pass | 3 min |
| 2 | Tree of explicit actions | 111 tests pass | 30 min |
| 3 | README | unchanged | 3 min |

Conventions:
- Copy every code block verbatim; each file block replaces the whole file.
- Test names: `test_<Behavior>`, `test_RevertWhen_<Condition>`, `testFuzz_<Property>`, `invariant_<Property>`.
- Commit messages have no `Co-Authored-By` line.
- Unchanged and not touched by this plan: `foundry.toml`, `remappings.txt`, `test/FundedStreamBudget.t.sol`, `test/OpenFillAction.t.sol`, `test/CapitalPipelinePluginSetup.t.sol`.

---

### Task 1: Drop TriggerBatch

Independent flows are separate plugins, triggered separately. The batch's allowed failures are no longer needed now that every node of a flow must succeed.

**Files:**
- Delete: `src/periphery/TriggerBatch.sol`, `test/TriggerBatch.t.sol`
- Modify: `README.md` (remove the `src/periphery/TriggerBatch.sol` row from the Layout table)

**Step 1: Delete the contract and its tests**

```bash
git rm src/periphery/TriggerBatch.sol test/TriggerBatch.t.sol
```

**Step 2: Remove this row from the Layout table in `README.md`**

```markdown
| `src/periphery/TriggerBatch.sol` | Triggers several plugins in one transaction, with allowed failures |
```

**Step 3: Run the tests**

Run: `forge test`
Expected: `92 tests passed, 0 failed`

**Step 4: Commit**

```bash
git add -A src test README.md
git commit -m "Drop TriggerBatch

Independent flows are separate plugins triggered separately, and a flow
now either fully succeeds or reverts, so batching with allowed failures
no longer has a use."
```

---

### Task 2: Tree of explicit actions

Replaces the stage model in one step, because every component implements the new `INodeAction` interface.

- `Node {action, children, weights}` replaces `Stage {action, splitter}`; `IStageAction` becomes `INodeAction` (same hooks).
- Every node must succeed: the root takes a non-zero amount up to the budget, every other node takes exactly its input, leaves output nothing.
- Leaf actions replace splitters as the way money leaves a flow; `ISplitter.split(uint256)` now only feeds `SplitTransferAction`. `PayBeneficiary` becomes `TransferToBeneficiaryAction`.
- Native ETH is `NATIVE` (`0xEeee…EEeE`); `address(0)` is never a valid token.
- Merkle claims: only the account itself can claim, a claim with nothing owed reverts (`NothingToClaim`), and `recordClaim` needs `RECORD_CLAIM_PERMISSION_ID`.
- No action may target the plugin; `setFlow` is `nonReentrant`.

**Files:**
- Modify (tests first): `test/mocks/ERC20Mock.sol`, `test/mocks/BadComponents.sol`, `test/mocks/MockFiller.sol`, `test/mocks/MockSwap.sol`, `test/helpers/Fixture.sol`, `test/CapitalPipelinePlugin.t.sol`, `test/MerkleClaimAction.t.sol`, `test/NativeEth.t.sol`, `test/RatioSplitter.t.sol`, `test/invariant/PipelineInvariant.t.sol`
- Create (tests first): `test/LeafActions.t.sol`
- Delete (tests first): `test/BudgetsAndSplitters.t.sol` (its tests move to `test/LeafActions.t.sol`)
- Modify: `src/lib/types.sol`, `src/lib/constants.sol`, `src/lib/tokens.sol`, `src/interfaces/IBudget.sol`, `src/interfaces/ISplitter.sol`, `src/interfaces/IFiller.sol`, `src/budgets/BalanceBudget.sol`, `src/budgets/FundedStreamBudget.sol`, `src/actions/OpenFillAction.sol`, `src/actions/MerkleClaimAction.sol`, `src/splitters/RatioSplitter.sol`, `src/CapitalPipelinePlugin.sol`, `src/setup/CapitalPipelinePluginSetup.sol`
- Create: `src/interfaces/INodeAction.sol`, `src/actions/TransferBase.sol`, `src/actions/TransferAction.sol`, `src/actions/TransferToBeneficiaryAction.sol`, `src/actions/SplitTransferAction.sol`, `src/actions/BurnAction.sol`, `src/actions/KeepAction.sol`
- Delete: `src/interfaces/IStageAction.sol`, `src/splitters/PayBeneficiary.sol`

**Step 1: Replace `test/mocks/ERC20Mock.sol`** (burnable, for `BurnAction`)

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @notice Anyone can mint; holders can burn. Test only.
contract ERC20Mock is ERC20Burnable {
    constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) {}

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }
}
```

**Step 2: Replace `test/mocks/BadComponents.sol`**

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
    function split(uint256 _amount) external pure returns (Allocation[] memory _allocations) {
        _allocations = new Allocation[](1);
        _allocations[0] = Allocation({recipient: address(0xBEEF), amount: _amount + 1});
    }
}

/// @notice Lists the same recipient twice, splitting the amount 50/50 between the two entries
contract DuplicateRecipientSplitter is ISplitter {
    address public immutable recipient;

    constructor(address _recipient) {
        recipient = _recipient;
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

**Step 3: Replace `test/mocks/MockFiller.sol`** (`fill` sizes its data to the plugin's node count)

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFiller} from "../../src/interfaces/IFiller.sol";
import {CapitalPipelinePlugin} from "../../src/CapitalPipelinePlugin.sol";
import {NATIVE} from "../../src/lib/tokens.sol";

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

    /// @notice This contract becomes the trigger caller, so the DAO calls it back. `_data` goes to
    ///         the root (the OpenFill node); the other nodes get none.
    function fill(bytes memory _data) external {
        bytes[] memory _perNode = new bytes[](plugin.nodes().length);
        _perNode[0] = _data;
        plugin.trigger(_perNode);
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
    ) external payable {
        if (reenter) {
            try plugin.trigger(new bytes[](0)) {}
            catch (bytes memory _reason) {
                reentryError = _reason;
            }
        }

        // A native offer already arrived as msg.value; an ERC20 offer is pulled
        if (_offeredToken != NATIVE) {
            _offeredToken.transferFrom(msg.sender, address(this), _offeredAmount);
        }

        uint256 _amount = uint256(int256(_demandedAmount) + fillDelta);
        if (_demandedToken == NATIVE) {
            (bool _ok,) = msg.sender.call{value: _amount}("");
            require(_ok, "MockFiller: ETH send failed");
        } else {
            _demandedToken.transfer(msg.sender, _amount);
        }
        totalDelivered += _amount;
    }

    receive() external payable {}
}
```

**Step 4: Replace `test/mocks/MockSwap.sol`**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IBudget} from "../../src/interfaces/IBudget.sol";
import {INodeAction} from "../../src/interfaces/INodeAction.sol";
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

/// @notice A swap node: converts its whole input at the exchange's fixed rate
contract MockSwapAction is INodeAction {
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

**Step 5: Replace `test/helpers/Fixture.sol`** (tree builders `_leaf`, `_then`, `_branch`, `_one`, `_chain`, `_fork`)

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

    // Stateless leaves: one deployment serves every plugin
    BurnAction internal burn = new BurnAction();
    KeepAction internal keep = new KeepAction();
    TransferToBeneficiaryAction internal toBeneficiary = new TransferToBeneficiaryAction();

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
            ProxyLib.deployMinimalProxy(address(new TransferAction()), abi.encodeCall(TransferAction.initialize, (_to)))
        );
    }

    function _deploySplitTransfer(ISplitter _splitter) internal returns (SplitTransferAction) {
        return SplitTransferAction(
            ProxyLib.deployMinimalProxy(
                address(new SplitTransferAction()), abi.encodeCall(SplitTransferAction.initialize, (_splitter))
            )
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

**Step 6: Replace `test/CapitalPipelinePlugin.t.sol`**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {DaoUnauthorized} from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {CapitalPipelinePlugin} from "../src/CapitalPipelinePlugin.sol";
import {FundedStreamBudget} from "../src/budgets/FundedStreamBudget.sol";
import {BalanceBudget} from "../src/budgets/BalanceBudget.sol";
import {OpenFillAction} from "../src/actions/OpenFillAction.sol";
import {MerkleClaimAction} from "../src/actions/MerkleClaimAction.sol";
import {SplitTransferAction} from "../src/actions/SplitTransferAction.sol";
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

**Step 7: Replace `test/MerkleClaimAction.t.sol`**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DaoUnauthorized} from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import {CapitalPipelinePlugin} from "../src/CapitalPipelinePlugin.sol";
import {BalanceBudget} from "../src/budgets/BalanceBudget.sol";
import {MerkleClaimAction} from "../src/actions/MerkleClaimAction.sol";
import {Node} from "../src/lib/types.sol";
import {MANAGER_PERMISSION_ID, RECORD_CLAIM_PERMISSION_ID} from "../src/lib/constants.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockExchange, MockSwapAction} from "./mocks/MockSwap.sol";
import {BadAction} from "./mocks/BadComponents.sol";

/// @notice Two-leaf tree: alice is owed 10 A, bob 30 A (cumulative)
contract MerkleClaimActionTest is Fixture {
    uint256 internal aliceAmount;
    uint256 internal bobAmount;

    BalanceBudget internal budget;
    MerkleClaimAction internal merkle;
    CapitalPipelinePlugin internal plugin;

    function setUp() public override {
        super.setUp();
        budget = _deployBalanceBudget(tokenA);
        merkle = _deployMerkle(budget, _root(10 ether, 30 ether));
        plugin = _deployPlugin(budget, _chain(merkle, toBeneficiary));
    }

    function test_AccountClaimsItsAmount() public {
        vm.prank(alice);
        plugin.trigger(_claim(alice, 10 ether, address(0), 2));

        assertEq(tokenA.balanceOf(alice), 10 ether);
        assertEq(tokenA.balanceOf(address(dao)), DAO_A - 10 ether);
        assertEq(merkle.claimed(alice), 10 ether);
    }

    function test_RevertWhen_ClaimingAgain() public {
        vm.startPrank(alice);
        plugin.trigger(_claim(alice, 10 ether, address(0), 2));

        vm.expectRevert(MerkleClaimAction.NothingToClaim.selector);
        plugin.trigger(_claim(alice, 10 ether, address(0), 2));
        vm.stopPrank();
    }

    function test_RevertWhen_SomeoneElseClaims() public {
        vm.expectRevert(MerkleClaimAction.NotTheAccount.selector);
        vm.prank(carol);
        plugin.trigger(_claim(alice, 10 ether, address(0), 2));
    }

    function test_AccountRedirectsToAnotherBeneficiary() public {
        vm.prank(alice);
        plugin.trigger(_claim(alice, 10 ether, carol, 2));

        assertEq(tokenA.balanceOf(carol), 10 ether);
        assertEq(tokenA.balanceOf(alice), 0);
    }

    function test_RevertWhen_BeneficiaryIsTheDao() public {
        vm.expectRevert(MerkleClaimAction.InvalidBeneficiary.selector);
        vm.prank(alice);
        plugin.trigger(_claim(alice, 10 ether, address(dao), 2));
    }

    function test_RevertWhen_ProofIsInvalid() public {
        vm.expectRevert(MerkleClaimAction.InvalidProof.selector);
        vm.prank(alice);
        plugin.trigger(_claim(alice, 20 ether, address(0), 2)); // the tree says 10
    }

    function test_NewRootPaysTheDifference() public {
        vm.prank(alice);
        plugin.trigger(_claim(alice, 10 ether, address(0), 2));

        vm.prank(manager);
        merkle.setRoot(_root(25 ether, 30 ether));

        vm.prank(alice);
        plugin.trigger(_claim(alice, 25 ether, address(0), 2));

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

    function test_RevertWhen_RecordClaimUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector, address(dao), address(merkle), address(this), RECORD_CLAIM_PERMISSION_ID
            )
        );
        merkle.recordClaim(alice, 10 ether, alice);
    }

    function test_RevertWhen_TheDaoCannotPay() public {
        vm.prank(manager);
        merkle.setRoot(_root(1_000 ether, 30 ether));

        vm.expectRevert(
            abi.encodeWithSelector(CapitalPipelinePlugin.InAmountExceedsInput.selector, 0, 1_000 ether, DAO_A)
        );
        vm.prank(alice);
        plugin.trigger(_claim(alice, 1_000 ether, address(0), 2));
    }

    function test_RevertWhen_TheDaoIsEmpty() public {
        ERC20Mock _token = new ERC20Mock("Empty", "E"); // the DAO holds none
        BalanceBudget _budget = _deployBalanceBudget(IERC20(address(_token)));
        CapitalPipelinePlugin _plugin =
            _deployPlugin(_budget, _chain(_deployMerkle(_budget, _root(10 ether, 30 ether)), toBeneficiary));

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.EmptyInput.selector, 0));
        vm.prank(alice);
        _plugin.trigger(_claim(alice, 10 ether, address(0), 2));
    }

    /// Claim → swap A to B at 2 → pay the beneficiary (redirected to carol)
    function test_ClaimThenSwap() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _chain(merkle, _swap(), toBeneficiary));

        vm.prank(alice);
        _plugin.trigger(_claim(alice, 10 ether, carol, 3));

        assertEq(tokenB.balanceOf(carol), 20 ether);
        assertEq(tokenA.balanceOf(address(dao)), DAO_A - 10 ether);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B, "treasury B untouched");
    }

    /// Claim → 1% to the fee address, 99% swapped and paid to alice
    function test_ClaimWithAFeeBranch() public {
        Node[] memory _tree = new Node[](4);
        _tree[0] = _branch(merkle, 1, 10_000, 2, 990_000);
        _tree[1] = _leaf(_deployTransfer(fee));
        _tree[2] = _then(_swap(), 3);
        _tree[3] = _leaf(toBeneficiary);
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _tree);

        vm.prank(alice);
        _plugin.trigger(_claim(alice, 10 ether, address(0), 4));

        assertEq(tokenA.balanceOf(fee), 0.1 ether);
        assertEq(tokenB.balanceOf(alice), 19.8 ether);
    }

    /// Issue 1: if a later node can't run, the whole claim reverts and stays claimable
    function test_ClaimStaysOpenWhenALaterNodeCannotRun() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(
            budget, _chain(merkle, new BadAction(BadAction.Mode.Skip, address(dao), tokenB), toBeneficiary)
        );

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.NodeIncomplete.selector, 1, 0, 10 ether));
        vm.prank(alice);
        _plugin.trigger(_claim(alice, 10 ether, address(0), 3));

        assertEq(merkle.claimed(alice), 0, "nothing recorded");
    }

    // Helpers

    function _swap() internal returns (MockSwapAction) {
        MockExchange _exchange = new MockExchange(2e18);
        tokenB.mint(address(_exchange), 1_000 ether);
        return new MockSwapAction(_exchange, tokenB, address(dao));
    }

    function _leafHash(address _account, uint256 _cumulative) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(_account, _cumulative))));
    }

    /// @dev OpenZeppelin MerkleProof hashes sorted pairs
    function _hashPair(bytes32 _a, bytes32 _b) internal pure returns (bytes32) {
        return _a < _b ? keccak256(abi.encode(_a, _b)) : keccak256(abi.encode(_b, _a));
    }

    function _root(uint256 _alice, uint256 _bob) internal returns (bytes32) {
        (aliceAmount, bobAmount) = (_alice, _bob);
        return _hashPair(_leafHash(alice, _alice), _leafHash(bob, _bob));
    }

    /// @dev Root data for a flow of `_nodes` nodes. In a two-leaf tree, the proof is the other leaf.
    function _claim(address _account, uint256 _cumulative, address _beneficiary, uint256 _nodes)
        internal
        view
        returns (bytes[] memory _data)
    {
        bytes32[] memory _proof = new bytes32[](1);
        _proof[0] = _account == alice ? _leafHash(bob, bobAmount) : _leafHash(alice, aliceAmount);

        _data = new bytes[](_nodes);
        _data[0] = abi.encode(_account, _cumulative, _proof, _beneficiary);
    }
}
```

**Step 8: Create `test/LeafActions.t.sol` and delete the old budgets-and-splitters suite**

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
        _transfer.initialize(address(0));
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
            _one(_deploySplitTransfer(new DuplicateRecipientSplitter(alice)))
        );

        // Actions 0 and 1 are the transfers, action 2 the postcondition (alice expected 100, has 50)
        vm.expectRevert(abi.encodeWithSelector(DAO.ActionFailed.selector, 2));
        _plugin.trigger(noData);
    }

    function test_RevertWhen_TheSplitterAllocatesTooMuch() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _one(_deploySplitTransfer(new OverAllocatingSplitter())));

        vm.expectRevert(abi.encodeWithSelector(SplitTransferAction.AllocationExceedsInput.selector, DAO_A + 1, DAO_A));
        _plugin.trigger(noData);
    }

    function test_RevertWhen_SplitterIsUnset() public {
        SplitTransferAction _split =
            SplitTransferAction(ProxyLib.deployMinimalProxy(address(new SplitTransferAction()), ""));

        vm.expectRevert(SplitTransferAction.NoSplitter.selector);
        _split.initialize(ISplitter(address(0)));
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

```bash
git rm test/BudgetsAndSplitters.t.sol
```

**Step 9: Replace `test/NativeEth.t.sol`**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {CapitalPipelinePlugin} from "../src/CapitalPipelinePlugin.sol";
import {FundedStreamBudget} from "../src/budgets/FundedStreamBudget.sol";
import {OpenFillAction} from "../src/actions/OpenFillAction.sol";
import {MerkleClaimAction} from "../src/actions/MerkleClaimAction.sol";
import {Plan} from "../src/lib/types.sol";
import {NATIVE} from "../src/lib/tokens.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {MockFiller} from "./mocks/MockFiller.sol";

/// @notice Native ETH is `NATIVE` (0xEeee…EEeE) everywhere; address(0) is never a token
contract NativeEthTest is Fixture {
    uint256 internal constant DAO_ETH = 100 ether;

    function setUp() public override {
        super.setUp();
        vm.deal(address(dao), DAO_ETH);
    }

    function test_BudgetPaysOutEth() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(
            _deployBalanceBudget(NATIVE),
            _fork(NO_ACTION, 500_000, _deployTransfer(alice), 500_000, _deployTransfer(bob))
        );

        _plugin.trigger(noData);

        assertEq(alice.balance, 50 ether);
        assertEq(bob.balance, 50 ether);
        assertEq(address(dao).balance, 0);
    }

    function test_StreamedEthIsSoldForTokens() public {
        FundedStreamBudget _budget = _deployStream(NATIVE, RATE, 0);
        CapitalPipelinePlugin _plugin =
            _deployPlugin(_budget, _chain(_deployAction(_budget), _deploySplitTransfer(_deploySplitter())));
        MockFiller _filler = new MockFiller(_plugin);
        tokenB.mint(address(_filler), DEMAND);
        vm.warp(block.timestamp + EPOCH);

        _filler.fillWithoutData();

        assertEq(address(_filler).balance, RATE, "the offer arrives as call value");
        assertEq(address(dao).balance, DAO_ETH - RATE);
        assertEq(tokenB.balanceOf(BURN), 950 ether);
        assertEq(tokenB.balanceOf(fee), 50 ether);
    }

    function test_NativeOfferNeedsNoApproval() public {
        OpenFillAction _action = _deployAction(_deployStream(NATIVE, RATE, 0));

        (, Action[] memory _actions) = _action.build(alice, "", Plan(NATIVE, 10 ether, NATIVE, 10 ether, address(0)));

        assertEq(_actions.length, 1, "callback only");
        assertEq(_actions[0].to, alice);
        assertEq(_actions[0].value, 10 ether);
    }

    function test_TokensAreSoldForEth() public {
        FundedStreamBudget _budget = _deployBudget(RATE, 0); // token A
        CapitalPipelinePlugin _plugin =
            _deployPlugin(_budget, _chain(_deployOpenFill(_budget, NATIVE), _deploySplitTransfer(_deploySplitter())));
        MockFiller _filler = new MockFiller(_plugin);
        vm.deal(address(_filler), DEMAND);
        vm.warp(block.timestamp + EPOCH);

        _filler.fillWithoutData();

        assertEq(tokenA.balanceOf(address(_filler)), RATE);
        assertEq(BURN.balance, 950 ether);
        assertEq(fee.balance, 50 ether);
        assertEq(address(dao).balance, DAO_ETH, "pre-existing ETH untouched");
    }

    function test_MerkleClaimPaysEth() public {
        bytes32 _root = keccak256(bytes.concat(keccak256(abi.encode(alice, 1 ether))));
        MerkleClaimAction _merkle = _deployMerkle(_deployBalanceBudget(NATIVE), _root);
        CapitalPipelinePlugin _plugin = _deployPlugin(_merkle.budget(), _chain(_merkle, toBeneficiary));

        bytes[] memory _data = new bytes[](2);
        _data[0] = abi.encode(alice, 1 ether, new bytes32[](0), address(0));
        vm.prank(alice);
        _plugin.trigger(_data);

        assertEq(alice.balance, 1 ether);
    }

    function test_RevertWhen_RecipientRejectsEth() public {
        // An ERC20 contract has no receive(), so the native send fails inside the DAO
        CapitalPipelinePlugin _plugin =
            _deployPlugin(_deployBalanceBudget(NATIVE), _one(_deployTransfer(address(tokenA))));

        vm.expectRevert(abi.encodeWithSelector(DAO.ActionFailed.selector, 0));
        _plugin.trigger(noData);
    }

    /// Issue 7: an unset token no longer means ETH
    function test_RevertWhen_TokenIsUnset() public {
        FundedStreamBudget _budget =
            FundedStreamBudget(ProxyLib.deployMinimalProxy(address(new FundedStreamBudget()), ""));

        vm.expectRevert(FundedStreamBudget.InvalidToken.selector);
        _budget.initialize(dao, IERC20(address(0)), RATE, 0, EPOCH);
    }
}
```

**Step 10: Replace `test/RatioSplitter.t.sol`**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {DaoUnauthorized} from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import {RatioSplitter} from "../src/splitters/RatioSplitter.sol";
import {Allocation} from "../src/lib/types.sol";
import {MANAGER_PERMISSION_ID, RATIO_BASE} from "../src/lib/constants.sol";
import {Fixture} from "./helpers/Fixture.sol";

contract RatioSplitterTest is Fixture {
    RatioSplitter internal splitter;

    function setUp() public override {
        super.setUp();
        splitter = _deploySplitter();
    }

    function test_SplitsNinetyFiveFive() public view {
        Allocation[] memory _allocations = splitter.split(1000 ether);

        assertEq(_allocations.length, 2);
        assertEq(_allocations[0].recipient, BURN);
        assertEq(_allocations[0].amount, 950 ether);
        assertEq(_allocations[1].recipient, fee);
        assertEq(_allocations[1].amount, 50 ether);
    }

    function test_RemainderGoesToLargestShare() public view {
        Allocation[] memory _allocations = splitter.split(1); // both shares round down to 0

        assertEq(_allocations[0].amount, 1);
        assertEq(_allocations[1].amount, 0);
    }

    function testFuzz_AllocationsSumToAmount(uint256 _amount, uint256 _ratio) public {
        _amount = bound(_amount, 0, type(uint128).max);
        _ratio = bound(_ratio, 0, RATIO_BASE);
        _set(uint32(_ratio), uint32(RATIO_BASE - _ratio));

        Allocation[] memory _allocations = splitter.split(_amount);

        assertEq(_allocations[0].amount + _allocations[1].amount, _amount);
    }

    function test_ManagerReplacesRecipients() public {
        _set(500_000, 500_000);

        Allocation[] memory _allocations = splitter.split(10);
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

**Step 11: Replace `test/invariant/PipelineInvariant.t.sol`**

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
        if (budget.available() == 0) return; // nothing on offer: a trigger would revert by design
        filler.fillWithoutData();
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
        CapitalPipelinePlugin _plugin = _deployPlugin(_budget, _chain(_action, _deploySplitTransfer(_deploySplitter())));

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

**Step 12: Run the tests to make sure they fail**

Run: `forge test`
Expected: compilation fails with `Source "src/interfaces/INodeAction.sol" not found` (and other new sources)

**Step 13: Replace `src/lib/types.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INodeAction} from "../interfaces/INodeAction.sol";

/// @notice What a node spends and what it produces
/// @param beneficiary Who the flowing amount belongs to, once an action sets it (a Merkle claim).
///        Carried down every branch; it can't be changed once set.
struct Plan {
    IERC20 inToken;
    uint256 inAmount;
    IERC20 outToken;
    uint256 outAmount;
    address beneficiary;
}

/// @notice An amount for one recipient, returned by splitters
struct Allocation {
    address recipient;
    uint256 amount;
}

/// @notice One node of a flow tree. Node 0 is the root and receives the budget.
/// @param action What the node does with its input. May be address(0) only on a branch (2+
///        children): the node then passes its input to its children unchanged.
/// @param children Indexes of the child nodes, each greater than this node's index. None makes
///        the node a leaf, whose action must output nothing.
/// @param weights One per child when there are 2+ children, summing to RATIO_BASE. Empty otherwise.
struct Node {
    INodeAction action;
    uint32[] children;
    uint32[] weights;
}
```

**Step 14: Replace `src/lib/constants.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

/// @dev Tunes parameters on components and pauses the plugin
bytes32 constant MANAGER_PERMISSION_ID = keccak256("MANAGER_PERMISSION");

/// @dev Calls `trigger()` on the plugin
bytes32 constant TRIGGER_PERMISSION_ID = keccak256("TRIGGER_PERMISSION");

/// @dev Replaces the flow tree. DAO only: an action can return arbitrary DAO actions.
bytes32 constant CONFIGURE_PERMISSION_ID = keccak256("CONFIGURE_PERMISSION");

/// @dev Restarts a stream budget from zero
bytes32 constant CHECKPOINT_PERMISSION_ID = keccak256("CHECKPOINT_PERMISSION");

/// @dev Records a Merkle claim; granted to the DAO, which executes it inside the claim's node
bytes32 constant RECORD_CLAIM_PERMISSION_ID = keccak256("RECORD_CLAIM_PERMISSION");

/// @dev The most nodes a flow tree may have, which bounds the gas of a trigger
uint256 constant MAX_NODES = 16;

/// @dev Ratios are fractions of 1_000_000
uint256 constant RATIO_BASE = 1_000_000;

/// @dev Prices are 1e18-scaled: demanded_raw * 1e18 / offered_raw
uint256 constant EXCHANGE_RATE_SCALE = 1e18;
```

**Step 15: Replace `src/lib/tokens.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";

/// @dev Native ETH, by the common 0xEeee…EEeE convention. `address(0)` is never a valid token,
///      so a parameter left unset reverts instead of silently meaning ETH.
IERC20 constant NATIVE = IERC20(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

/// @notice `_account`'s balance of `_token`, or of native ETH
function tokenBalance(IERC20 _token, address _account) view returns (uint256) {
    return _token == NATIVE ? _account.balance : _token.balanceOf(_account);
}

/// @notice A DAO action that sends `_amount` of `_token` (or native ETH) to `_to`
function transferAction(IERC20 _token, address _to, uint256 _amount) pure returns (Action memory) {
    if (_token == NATIVE) return Action({to: _to, value: _amount, data: ""});
    return Action({to: address(_token), value: 0, data: abi.encodeCall(IERC20.transfer, (_to, _amount))});
}

/// @notice True for native ETH or a contract; rejects address(0), typos and EOAs
function isToken(IERC20 _token) view returns (bool) {
    return _token == NATIVE || address(_token).code.length != 0;
}
```

**Step 16: Create `src/interfaces/INodeAction.sol` and delete the old interface**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IBudget} from "./IBudget.sol";
import {Plan} from "../lib/types.sol";

/// @title INodeAction
/// @notice What a node of a flow tree does with its input. The plugin calls all three hooks, in
///         order, on every node that has an action, so an action's safety checks can't be left out.
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

```bash
git rm src/interfaces/IStageAction.sol
```

**Step 17: Replace `src/interfaces/IBudget.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {Plan} from "../lib/types.sol";

/// @title IBudget
/// @notice How much of a token a flow may spend right now
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

**Step 18: Replace `src/interfaces/ISplitter.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Allocation} from "../lib/types.sol";

/// @title ISplitter
/// @notice Divides an amount among recipients. Used by `SplitTransferAction` to pay dynamic lists.
interface ISplitter {
    /// @notice Allocations of `amount`, adding up to at most `amount`
    function split(uint256 amount) external view returns (Allocation[] memory);
}
```

**Step 19: Replace `src/interfaces/IFiller.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IFiller
/// @notice The callback a filler contract implements to take an open-fill offer. The filler calls
///         `trigger()` on the plugin; the DAO approves `offeredAmount` to it and calls this function
///         on that same caller. The filler pulls the offered tokens and must leave the DAO holding
///         at least `demandedAmount` more of `demandedToken` before returning.
/// @dev Same selector as capital-router's `ISwapSolver.fillOffer`, so existing fillers keep working.
///      Native ETH is `0xEeee…EEeE` (see `NATIVE` in lib/tokens.sol) on either side, never both: a native offer arrives as
///      `msg.value` with no approval; a native demand must be sent to the DAO as ETH.
interface IFiller {
    function fillOffer(
        IERC20 offeredToken,
        uint256 offeredAmount,
        IERC20 demandedToken,
        uint256 demandedAmount,
        bytes calldata data
    ) external payable;
}
```

**Step 20: Replace `src/budgets/BalanceBudget.sol`**

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
import {tokenBalance, isToken} from "../lib/tokens.sol";

/// @title BalanceBudget
/// @notice The DAO's whole balance of a token, with nothing to commit. Used where something else
///         decides the amount, such as a Merkle claim, and the budget only caps it at what the DAO holds.
contract BalanceBudget is IBudget, Initializable, DaoAuthorizableUpgradeable {
    /// @inheritdoc IBudget
    IERC20 public token;

    /// @notice Thrown when the token is neither native ETH (`NATIVE`) nor a contract
    error InvalidToken();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IDAO _dao, IERC20 _token) external initializer {
        if (!isToken(_token)) revert InvalidToken();

        __DaoAuthorizableUpgradeable_init(_dao);
        token = _token;
    }

    /// @inheritdoc IBudget
    function available() external view returns (uint256) {
        return tokenBalance(token, address(dao()));
    }

    /// @inheritdoc IBudget
    function commitActions(Plan calldata) external pure returns (Action[] memory) {}
}
```

**Step 21: Replace `src/budgets/FundedStreamBudget.sol`**

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
import {ICheckpointedBudget} from "../interfaces/IBudget.sol";
import {Plan} from "../lib/types.sol";
import {tokenBalance, isToken} from "../lib/tokens.sol";
import {MANAGER_PERMISSION_ID, CHECKPOINT_PERMISSION_ID} from "../lib/constants.sol";

/// @title FundedStreamBudget
/// @notice A streaming pot whose available amount only grows while the DAO can fund it. Built
///         for Dutch auctions (`OpenFillAction`), where the offered amount must rise continuously
///         and never jump.
/// @dev **Why not a plain stream.** `min(rate x elapsed, balance)` caps the amount by the balance
///      but does not stop the clock, so while the DAO is short the elapsed time keeps accruing out
///      of sight. When funds arrive, the cap lifts and the amount jumps to the whole backlog, which
///      an auction filler takes in the same block.
///
///      **How this budget avoids it.** The available amount is
///
///          min(baseAmount + rate x (now - baseTimestamp), lastSeenBalance, daoBalance, maxBudget)
///
///      - `lastSeenBalance` is the DAO balance seen at the last checkpoint or sync. A deposit
///        does not move it, so the amount cannot rise above it until a transaction picks the
///        deposit up.
///      - `sync()` (permissionless) stores the current amount as `baseAmount`, sets `baseTimestamp`
///        to now and records the DAO balance. The amount is the same just before and just after
///        a sync, so growth hidden by `lastSeenBalance` is discarded and the stream resumes from
///        where it froze. Calling it repeatedly does not change the curve (at most 1 wei of
///        rounding per call).
///      - `writeCheckpoint()` restarts the amount from zero and records the balance left after
///        the spend. The plugin runs it once, after the whole flow (`commitActions`).
///      - The DAO balance itself caps the amount if funds leave by another path after the last
///        sync.
///      - Every setter syncs first, so a parameter change never alters what has already accrued.
///
///      **Liveness.** After a deposit the amount stays frozen until someone calls `sync()`. That
///      is safe (the amount never rises) but stalls the stream, so operators should run a keeper
///      or add a `sync()` action wherever revenue enters the DAO.
///
///      **Residual case.** If funds leave the DAO by another path and come back before any sync,
///      `lastSeenBalance` is stale and the growth accrued meanwhile is released, bounded by that
///      stale balance and, in an auction, the action's `maxOffered()`. Proposals that spend the
///      token should include a `sync()` action.
///
///      One flow per instance.
contract FundedStreamBudget is ICheckpointedBudget, Initializable, DaoAuthorizableUpgradeable {
    /// @notice The token streamed
    IERC20 public token;

    /// @notice How much the available amount grows per epoch
    uint256 public amountPerEpoch;

    /// @notice If greater than zero, it limits the available amount at any point in time
    uint256 public maxBudget;

    /// @notice The length of an epoch in seconds
    uint256 public epochInterval;

    /// @notice The amount available at `baseTimestamp`, from which growth continues
    uint256 public baseAmount;

    /// @notice The timestamp of the last checkpoint or sync
    uint256 public baseTimestamp;

    /// @notice The DAO balance seen at the last checkpoint or sync. The amount never rises above it.
    uint256 public lastSeenBalance;

    /// @notice Emitted when the budget is initialized
    event BudgetSettingsUpdated(IERC20 token, uint256 amountPerEpoch, uint256 maxBudget, uint256 epochInterval);

    /// @notice Emitted when the growth per epoch is updated
    event NewAmountPerEpoch(uint256 amountPerEpoch);

    /// @notice Emitted when the cap is updated
    event NewMaxBudget(uint256 maxBudget);

    /// @notice Emitted when the epoch interval is updated
    event NewEpochInterval(uint256 epochInterval);

    /// @notice Emitted when the amount restarts from zero after a spend
    /// @param lastSeenBalance The DAO balance left after the spend
    event CheckpointWritten(uint256 lastSeenBalance);

    /// @notice Emitted when the amount is carried forward and the DAO balance recorded
    /// @param baseAmount The amount available at the time of the sync
    /// @param lastSeenBalance The DAO balance seen by the sync
    event Synced(uint256 baseAmount, uint256 lastSeenBalance);

    /// @notice Thrown when the token is neither native ETH (`NATIVE`) nor a contract
    error InvalidToken();

    /// @notice Thrown when the given epoch interval is zero
    error InvalidEpochInterval();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the budget. The amount starts at zero, capped by the current balance.
    /// @dev A DAO that holds no tokens at initialization keeps the amount at zero until `sync()`
    ///      is called after it is funded.
    /// @param _dao The DAO holding the funds
    /// @param _token The token streamed (`NATIVE` for native ETH)
    /// @param _amountPerEpoch How much the available amount grows per epoch
    /// @param _maxBudget Maximum available amount at any point in time (0 for no cap)
    /// @param _epochInterval The epoch duration in seconds
    function initialize(IDAO _dao, IERC20 _token, uint256 _amountPerEpoch, uint256 _maxBudget, uint256 _epochInterval)
        external
        initializer
    {
        if (!isToken(_token)) revert InvalidToken();

        __DaoAuthorizableUpgradeable_init(_dao);

        token = _token;
        amountPerEpoch = _amountPerEpoch;
        maxBudget = _maxBudget;
        _setEpochInterval(_epochInterval);

        emit BudgetSettingsUpdated(_token, _amountPerEpoch, _maxBudget, _epochInterval);

        _writeCheckpoint();
    }

    // IBudget

    /// @notice Returns the amount available right now
    /// @return min(baseAmount + rate x (now - baseTimestamp), lastSeenBalance, daoBalance, maxBudget)
    function available() public view virtual returns (uint256) {
        return _available(_daoBalance());
    }

    /// @notice Restarts the stream after the spend: the plugin executes this once, after the whole flow
    function commitActions(Plan calldata) external view virtual returns (Action[] memory _actions) {
        _actions = new Action[](1);
        _actions[0] = Action({to: address(this), value: 0, data: abi.encodeCall(this.writeCheckpoint, ())});
    }

    // Lifecycle

    /// @notice Carries the current amount forward and records the DAO balance
    /// @dev Permissionless: it never raises the current amount, it only lets the amount resume
    ///      growing after a deposit (or follow the balance down after an outflow).
    function sync() external virtual {
        _sync();
    }

    /// @notice Restarts the amount from zero and records the DAO balance
    /// @dev Executed by the DAO after the whole flow ran, so the recorded balance is what is left
    ///      after the tokens have been handed over. Also called by a bound action to restart its
    ///      auction when its price terms change.
    function writeCheckpoint() external virtual auth(CHECKPOINT_PERMISSION_ID) {
        _writeCheckpoint();
    }

    // Manager settings. Each one syncs first, so time already elapsed keeps the old values.

    /// @notice Updates how much the available amount grows per epoch
    function setAmountPerEpoch(uint256 _amountPerEpoch) external virtual auth(MANAGER_PERMISSION_ID) {
        _sync();
        amountPerEpoch = _amountPerEpoch;
        emit NewAmountPerEpoch(_amountPerEpoch);
    }

    /// @notice Updates the cap on the available amount (0 for no cap)
    function setMaxBudget(uint256 _maxBudget) external virtual auth(MANAGER_PERMISSION_ID) {
        _sync();
        maxBudget = _maxBudget;
        emit NewMaxBudget(_maxBudget);
    }

    /// @notice Updates the epoch interval, which changes the growth rate
    function setEpochInterval(uint256 _epochInterval) external virtual auth(MANAGER_PERMISSION_ID) {
        _sync();
        _setEpochInterval(_epochInterval);
    }

    // Internal

    /// @dev The amount available for a given DAO balance
    function _available(uint256 _balance) internal view virtual returns (uint256 _amount) {
        _amount = baseAmount + (amountPerEpoch * (block.timestamp - baseTimestamp)) / epochInterval;

        _amount = Math.min(_amount, lastSeenBalance);
        _amount = Math.min(_amount, _balance);
        if (maxBudget != 0) _amount = Math.min(_amount, maxBudget);
    }

    function _sync() internal virtual {
        uint256 _balance = _daoBalance();
        uint256 _amount = _available(_balance);

        baseAmount = _amount;
        baseTimestamp = block.timestamp;
        lastSeenBalance = _balance;

        emit Synced(_amount, _balance);
    }

    function _writeCheckpoint() internal virtual {
        uint256 _balance = _daoBalance();

        baseAmount = 0;
        baseTimestamp = block.timestamp;
        lastSeenBalance = _balance;

        emit CheckpointWritten(_balance);
    }

    function _setEpochInterval(uint256 _epochInterval) internal virtual {
        if (_epochInterval == 0) revert InvalidEpochInterval();

        epochInterval = _epochInterval;

        emit NewEpochInterval(_epochInterval);
    }

    /// @dev The DAO's current balance of the streamed token
    function _daoBalance() internal view virtual returns (uint256) {
        return tokenBalance(token, address(dao()));
    }
}
```

**Step 22: Replace `src/actions/OpenFillAction.sol`**

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
import {INodeAction} from "../interfaces/INodeAction.sol";
import {IBudget, ICheckpointedBudget} from "../interfaces/IBudget.sol";
import {IFiller} from "../interfaces/IFiller.sol";
import {Plan} from "../lib/types.sol";
import {MANAGER_PERMISSION_ID, EXCHANGE_RATE_SCALE} from "../lib/constants.sol";
import {NATIVE, tokenBalance, isToken} from "../lib/tokens.sol";

/// @title OpenFillAction
/// @notice Take-it-or-leave-it swap priced as a Dutch auction. The bound budget grows the offer
///         from zero; the DAO demands a flat `demandPerFill` back; any filler can take it.
/// @dev The price obtained is `demandPerFill / offered`, so it worsens as the offer grows.
///      `maxOffered()` caps the offer at `demandPerFill / minDemandedPerOffered`, which holds the
///      worst acceptable price. Price terms are 1e18-scaled: `demanded_raw * 1e18 / offered_raw`.
///      Changing either price term restarts the auction, so a filler cannot take an offer that
///      accumulated under the old terms at the new price.
///
///      Native ETH (`NATIVE`) works on either side, never both: a native offer is sent as call
///      value with the callback (no approvals); a native demand is measured on the DAO's ETH balance.
contract OpenFillAction is INodeAction, Initializable, DaoAuthorizableUpgradeable {
    /// @inheritdoc INodeAction
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

    /// @notice Thrown when the demanded token is neither native ETH (`NATIVE`) nor a contract
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
    /// @param _demandedToken The token the DAO must receive back (`NATIVE` for native ETH)
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
        if (!isToken(_demandedToken)) revert InvalidToken();
        if (_demandedToken == _budget.token()) revert SameToken();

        __DaoAuthorizableUpgradeable_init(_dao);

        budget = _budget;
        demandedToken = _demandedToken;
        _setTerms(_demandPerFill, _minDemandedPerOffered);
    }

    // INodeAction

    /// @inheritdoc INodeAction
    /// @dev None in v1
    function preconditions(address, Plan calldata) external view virtual {}

    /// @inheritdoc INodeAction
    /// @dev ERC20 offer: approve it to the caller, call it back, clear the approval.
    ///      Native offer: call the caller back with the offer as call value.
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

        bytes memory _callback =
            abi.encodeCall(IFiller.fillOffer, (_draft.inToken, _offered, demandedToken, demandPerFill, _data));

        if (_draft.inToken == NATIVE) {
            _actions = new Action[](1);
            _actions[0] = Action({to: _caller, value: _offered, data: _callback});
            return (_plan, _actions);
        }

        address _in = address(_draft.inToken);
        _actions = new Action[](3);
        _actions[0] = Action({to: _in, value: 0, data: abi.encodeCall(IERC20.approve, (_caller, _offered))});
        _actions[1] = Action({to: _caller, value: 0, data: _callback});
        _actions[2] = Action({to: _in, value: 0, data: abi.encodeCall(IERC20.approve, (_caller, 0))});
    }

    /// @inheritdoc INodeAction
    /// @dev Reverts the whole trigger unless the DAO received at least `outAmount`
    function postconditions(address, Plan calldata _plan) external view virtual returns (Action[] memory _actions) {
        uint256 _minBalance = tokenBalance(_plan.outToken, address(dao())) + _plan.outAmount;

        _actions = new Action[](1);
        _actions[0] = Action({
            to: address(this), value: 0, data: abi.encodeCall(this.assertReceived, (_plan.outToken, _minBalance))
        });
    }

    /// @notice Reverts unless the DAO holds at least `_minBalance` of `_token`
    /// @dev Executed by the DAO as the postcondition of a fill. View, so harmless to call from anywhere.
    function assertReceived(IERC20 _token, uint256 _minBalance) external view virtual {
        uint256 _balance = tokenBalance(_token, address(dao()));
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

**Step 23: Replace `src/actions/MerkleClaimAction.sol`**

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
import {INodeAction} from "../interfaces/INodeAction.sol";
import {IBudget} from "../interfaces/IBudget.sol";
import {Plan} from "../lib/types.sol";
import {MANAGER_PERMISSION_ID, RECORD_CLAIM_PERMISSION_ID} from "../lib/constants.sol";

/// @title MerkleClaimAction
/// @notice Cumulative Merkle distribution. Each leaf is (account, cumulative amount); an account
///         can claim `cumulative − claimed` at any time. A new root raises the cumulative amounts
///         for the next round.
/// @dev Must be the root of a flow on its budget. Outputs only what the account is owed (not the
///      whole budget) and sets the flow's beneficiary, so child nodes can swap it before a
///      `TransferToBeneficiaryAction` pays it out. One claim per trigger.
///      Leaves use OpenZeppelin's StandardMerkleTree format: keccak256(bytes.concat(keccak256(abi.encode(account, cumulative)))).
///
///      Root data: abi.encode(address account, uint256 cumulative, bytes32[] proof, address beneficiary).
///      Only the account itself can claim (`caller == account`), so nobody else can pick the data
///      of the other nodes or front-run a redirect. `beneficiary == 0` pays the account.
///      Relayed (gasless) claims could be added later with a signature from the account over the
///      beneficiary and the data of every node.
contract MerkleClaimAction is INodeAction, Initializable, DaoAuthorizableUpgradeable {
    /// @inheritdoc INodeAction
    IBudget public budget;

    /// @notice The current Merkle root of (account, cumulative amount) leaves
    bytes32 public root;

    /// @notice Cumulative amount already claimed per account
    mapping(address => uint256) public claimed;

    event RootUpdated(bytes32 root);
    event Claimed(address indexed account, address indexed beneficiary, uint256 amount);

    error NoBudget();
    error InvalidProof();
    error NotTheAccount();
    error NothingToClaim();
    error InvalidBeneficiary();

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

    // INodeAction

    /// @inheritdoc INodeAction
    function preconditions(address, Plan calldata) external view virtual {}

    /// @inheritdoc INodeAction
    function build(address _caller, bytes calldata _data, Plan calldata _draft)
        external
        view
        virtual
        returns (Plan memory _plan, Action[] memory _actions)
    {
        (address _account, uint256 _cumulative, bytes32[] memory _proof, address _beneficiary) =
            abi.decode(_data, (address, uint256, bytes32[], address));

        if (_caller != _account) revert NotTheAccount();
        if (!MerkleProof.verify(_proof, root, leaf(_account, _cumulative))) revert InvalidProof();
        if (_beneficiary == address(0)) _beneficiary = _account;
        if (_beneficiary == address(dao())) revert InvalidBeneficiary();

        if (_cumulative <= claimed[_account]) revert NothingToClaim();
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

    /// @inheritdoc INodeAction
    /// @dev None: the plugin's balance checks verify the payout
    function postconditions(address, Plan calldata) external view virtual returns (Action[] memory) {}

    // Claim record

    /// @notice Records a claim. Executed by the DAO inside the claim's node, so it rolls back with the flow.
    function recordClaim(address _account, uint256 _cumulative, address _beneficiary)
        external
        virtual
        auth(RECORD_CLAIM_PERMISSION_ID)
    {
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

**Step 24: Create `src/actions/TransferBase.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {INodeAction} from "../interfaces/INodeAction.sol";
import {IBudget} from "../interfaces/IBudget.sol";
import {Plan} from "../lib/types.sol";
import {tokenBalance, transferAction} from "../lib/tokens.sol";

/// @title TransferBase
/// @notice Leaf that sends its whole input to one recipient. Postcondition: the recipient's balance
///         rose by the amount, which catches tokens that return false instead of reverting.
/// @dev Native ETH works too. Fee-on-transfer and rebasing tokens fail the postcondition by design.
abstract contract TransferBase is INodeAction {
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

**Step 25: Create `src/actions/TransferAction.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {TransferBase} from "./TransferBase.sol";
import {Plan} from "../lib/types.sol";

/// @title TransferAction
/// @notice Leaf that sends its whole input to a fixed recipient
contract TransferAction is TransferBase, Initializable {
    /// @notice Who receives the node's input
    address public recipient;

    /// @notice Thrown when the recipient is address(0)
    error NoRecipient();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _to) external initializer {
        if (_to == address(0)) revert NoRecipient();
        recipient = _to;
    }

    function _recipient(Plan calldata) internal view override returns (address) {
        return recipient;
    }
}
```

**Step 26: Create `src/actions/TransferToBeneficiaryAction.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {TransferBase} from "./TransferBase.sol";
import {Plan} from "../lib/types.sol";

/// @title TransferToBeneficiaryAction
/// @notice Leaf that sends its whole input to the flow's beneficiary (set by a claim at the root).
///         Stateless: one deployment serves every plugin.
contract TransferToBeneficiaryAction is TransferBase {
    /// @notice Thrown when no action in the flow set a beneficiary
    error NoBeneficiary();

    function _recipient(Plan calldata _plan) internal pure override returns (address) {
        if (_plan.beneficiary == address(0)) revert NoBeneficiary();
        return _plan.beneficiary;
    }
}
```

**Step 27: Create `src/actions/SplitTransferAction.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
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
contract SplitTransferAction is INodeAction, Initializable {
    /// @notice Computes the recipients and amounts
    ISplitter public splitter;

    error NoSplitter();
    error AllocationExceedsInput(uint256 allocated, uint256 input);
    error ReceiptShortfall(IERC20 token, address recipient, uint256 expected, uint256 actual);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(ISplitter _splitter) external initializer {
        if (address(_splitter) == address(0)) revert NoSplitter();
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

**Step 28: Create `src/actions/BurnAction.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {INodeAction} from "../interfaces/INodeAction.sol";
import {IBudget} from "../interfaces/IBudget.sol";
import {Plan} from "../lib/types.sol";
import {NATIVE} from "../lib/tokens.sol";

/// @title BurnAction
/// @notice Leaf that burns its whole input with `ERC20Burnable.burn`, lowering the total supply.
///         Stateless: one deployment serves every plugin.
/// @dev The token must implement `burn(uint256)`; otherwise the DAO action reverts. The plugin's
///      balance check confirms the DAO spent no more than the input.
contract BurnAction is INodeAction {
    /// @notice Thrown when the input is native ETH, which can't be burned
    error CannotBurnNative();

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

**Step 29: Create `src/actions/KeepAction.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {INodeAction} from "../interfaces/INodeAction.sol";
import {IBudget} from "../interfaces/IBudget.sol";
import {Plan} from "../lib/types.sol";

/// @title KeepAction
/// @notice Leaf that leaves its whole input in the DAO, so keeping funds is an explicit choice.
///         Stateless: one deployment serves every plugin.
contract KeepAction is INodeAction {
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

**Step 30: Replace `src/splitters/RatioSplitter.sol` and delete `PayBeneficiary`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {
    DaoAuthorizableUpgradeable
} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizableUpgradeable.sol";
import {ISplitter} from "../interfaces/ISplitter.sol";
import {Allocation} from "../lib/types.sol";
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
    function split(uint256 _amount) external view virtual returns (Allocation[] memory _allocations) {
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

```bash
git rm src/splitters/PayBeneficiary.sol
```

**Step 31: Replace `src/CapitalPipelinePlugin.sol`**

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
}
```

**Step 32: Replace `src/setup/CapitalPipelinePluginSetup.sol`**

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
            splitTransferImplementation, abi.encodeCall(SplitTransferAction.initialize, (ISplitter(_helpers[2])))
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

**Step 33: Run the tests**

Run: `forge test`
Expected: `111 tests passed, 0 failed` (the plugin suite alone: `37 passed`)

Run: `forge fmt --check`
Expected: no output

Run: `forge build --sizes 2>&1 | grep -E "CapitalPipelinePlugin |CapitalPipelinePluginSetup "`
Expected: both under the limits (runtime about 12.5 KB and initcode about 35.7 KB)

**Step 34: Commit**

```bash
git add -A src test
git commit -m "Run each flow as a tree of explicit actions

A stage chain hid where money went: partial fills left funds behind
silently, a bound action could sit mid-flow, and one flow could not
branch into different actions per share. Now every node passes its whole
output to its children by fixed weights, every branch ends in an explicit
leaf (transfer, burn, keep) and each node executes on its own, followed
by DAO balance checks, so every movement is declared and verified.

Native ETH moves to the 0xEeee sentinel so address(0) can never pass as a
token, Merkle claims are account-only and revert when nothing is owed,
and recordClaim needs its own permission."
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
| `src/setup/CapitalPipelinePluginSetup.sol` | Installs the swap-and-split flow |

## Permissions

| Permission | Holder | Allows |
|---|---|---|
| `TRIGGER_PERMISSION_ID` | anyone | `trigger()` |
| `CONFIGURE_PERMISSION_ID` | DAO only | `setFlow()` |
| `MANAGER_PERMISSION_ID` | manager | parameter setters, Merkle `setRoot()`, `pause()`, `unpause()` |
| `CHECKPOINT_PERMISSION_ID` | DAO, swap action | restarting the stream budget |
| `RECORD_CLAIM_PERMISSION_ID` | DAO | Merkle `recordClaim()`, run by the plugin through the DAO |

## Develop

```shell
git submodule update --init --recursive
forge build
forge test
```

Never set `via_ir = true`; fix stack-too-deep errors by restructuring the code.
````

**Step 2: Check the links**

Run: `ls docs/plans/2026-11-04-capital-pipeline-design.md src/actions/KeepAction.sol src/setup/CapitalPipelinePluginSetup.sol`
Expected: all three listed, no errors

**Step 3: Commit**

```bash
git add README.md
git commit -m "Describe trees, leaf actions and the claim permission in the README"
```
