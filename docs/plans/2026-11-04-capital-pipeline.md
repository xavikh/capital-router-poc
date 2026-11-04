# Capital Pipeline v1 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use /executing-plans to implement this plan task-by-task.

**Goal:** Build the v1 capital pipeline: an OSx plugin that runs budget → action → splitter steps, shipping an open-fill swap whose proceeds are ratio-split to a burn address and a fee address.

**Architecture:** One `CapitalPipelinePlugin` (PluginCloneable) stores `Step {budget, action, splitter}` structs. For each step it calls the action's `preconditions → build → postconditions`, builds the split transfers, appends the budget's commit, rejects any action targeting the DAO, and executes everything in one `dao.execute`. All planning is `view`; every state change is a DAO action. Components are clones bound to the DAO, and their setters use OSx permissions (`auth`).

**Tech Stack:** Solidity 0.8.28 (cancun, optimizer 200, **never via_ir**), Foundry, Aragon OSx (`aragon/osx`, `aragon/osx-commons`), OpenZeppelin 4.9.6. Testing patterns: @sol-test.

**Design:** `docs/plans/2026-11-04-capital-pipeline-design.md`. Reference implementation: `../capital-router`.

**Verified:** every code block below was compiled and tested in a scratch copy of this layout, including each intermediate state of the plugin. Final state: 55 tests and 3 invariants pass.

---

## Tasks

| # | Task | Time |
|---|---|---|
| 1 | Scaffold the Foundry project | 10 min (includes dependency download) |
| 2 | Shared types, constants and interfaces | 5 min |
| 3 | FundedStreamBudget (adapt the existing file) | 10 min |
| 4 | RatioSplitter | 5 min |
| 5 | OpenFillAction | 10 min |
| 6 | Plugin: step configuration | 10 min |
| 7 | Plugin: trigger | 15 min |
| 8 | Plugin: reentrancy and DAO-target guards | 5 min |
| 9 | Plugin setup | 10 min |
| 10 | Invariant test | 5 min |
| 11 | Docs | 5 min |

Conventions used throughout:
- Test names: `test_<Behavior>`, `test_RevertWhen_<Condition>`, `testFuzz_<Property>`, `invariant_<Property>`.
- Internal identifiers and parameters start with `_`.
- The test contract is the DAO's ROOT, so tests grant permissions with `dao.grant(...)` directly.
- Commit messages have no `Co-Authored-By` line.

---

### Task 1: Scaffold the Foundry project

**Files:**
- Create: `foundry.toml`, `remappings.txt`, `.gitignore`
- Commit unchanged first: `FundedStreamBudget.sol` (repo root, reference copy)

**Step 1: Commit the reference budget unchanged**

Task 3 adapts this file; committing it first makes that diff reviewable. Skip if `git ls-files FundedStreamBudget.sol` already prints the name.

```bash
git add FundedStreamBudget.sol
git commit -m "Add FundedStreamBudget as the reference for the pipeline budget"
```

**Step 2: Create `foundry.toml`**

```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc = "0.8.28"
evm_version = "cancun"
optimizer = true
optimizer_runs = 200
via_ir = false

[invariant]
runs = 64
depth = 32
fail_on_revert = true

[lint]
lint_on_build = false
```

**Step 3: Create `remappings.txt`**

```text
forge-std/=lib/forge-std/src/
@aragon/osx/=lib/osx/packages/contracts/src/
@aragon/osx-commons-contracts/=lib/osx-commons/contracts/
@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/
@openzeppelin/contracts-upgradeable/=lib/openzeppelin-contracts-upgradeable/contracts/
```

**Step 4: Create `.gitignore`**

```text
out/
cache/
```

**Step 5: Install dependencies (same pins as capital-router, plus forge-std v1.17.0)**

The OSx repo is large; this takes a few minutes.

```bash
forge install \
  foundry-rs/forge-std@v1.17.0 \
  aragon/osx@fc7403fcef660aa952c7e635e95257ee7f466efb \
  aragon/osx-commons@869045b069679fad94d640a8a3e1a1b5538cf0f0 \
  openzeppelin/openzeppelin-contracts@dc44c9f1a4c3b10af99492eed84f83ed244203f6 \
  OpenZeppelin/openzeppelin-contracts-upgradeable@2d081f24cac1a867f6f73d512f2022e1fa987854
```

Expected: `lib/` holds the five folders and `.gitmodules` exists. Check the OpenZeppelin version:

```bash
grep '"version"' lib/openzeppelin-contracts/package.json
```

Expected: `"version": "4.9.6",`

**Step 6: Build**

Run: `forge build`
Expected: `Nothing to compile`

**Step 7: Commit**

```bash
git add foundry.toml remappings.txt .gitignore .gitmodules lib
git commit -m "Scaffold Foundry project with the OSx and OpenZeppelin versions capital-router uses"
```

---

### Task 2: Shared types, constants and interfaces

No behavior yet, so there is nothing to test; the check is that everything compiles.

**Files:**
- Create: `src/lib/constants.sol`, `src/lib/types.sol`
- Create: `src/interfaces/IBudget.sol`, `src/interfaces/IStepAction.sol`, `src/interfaces/ISplitter.sol`, `src/interfaces/IFiller.sol`

**Step 1: Create `src/lib/constants.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

/// @dev Tunes parameters on components and pauses the plugin
bytes32 constant MANAGER_PERMISSION_ID = keccak256("MANAGER_PERMISSION");

/// @dev Calls `trigger()` on the plugin
bytes32 constant TRIGGER_PERMISSION_ID = keccak256("TRIGGER_PERMISSION");

/// @dev Installs and removes steps. DAO only: a step can return arbitrary DAO actions.
bytes32 constant CONFIGURE_PERMISSION_ID = keccak256("CONFIGURE_PERMISSION");

/// @dev Restarts a stream budget from zero
bytes32 constant CHECKPOINT_PERMISSION_ID = keccak256("CHECKPOINT_PERMISSION");

/// @dev Ratios are fractions of 1_000_000
uint256 constant RATIO_BASE = 1_000_000;

/// @dev Prices are 1e18-scaled: demanded_raw * 1e18 / offered_raw
uint256 constant EXCHANGE_RATE_SCALE = 1e18;
```

**Step 2: Create `src/lib/types.sol`**

`types.sol` and the interfaces import each other; Solidity resolves the cycle.

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBudget} from "../interfaces/IBudget.sol";
import {IStepAction} from "../interfaces/IStepAction.sol";
import {ISplitter} from "../interfaces/ISplitter.sol";

/// @notice What a step spends and what it produces. Passed from component to component.
struct Plan {
    IERC20 inToken;
    uint256 inAmount;
    IERC20 outToken;
    uint256 outAmount;
}

/// @notice An amount of the step's output for one recipient
struct Allocation {
    address recipient;
    uint256 amount;
}

/// @notice One step of the pipeline. `action` and `splitter` may be address(0).
struct Step {
    IBudget budget;
    IStepAction action;
    ISplitter splitter;
}
```

**Step 3: Create `src/interfaces/IBudget.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {Plan} from "../lib/types.sol";

/// @title IBudget
/// @notice How much of a token a step may spend right now
interface IBudget {
    /// @notice The token this budget releases
    function token() external view returns (IERC20);

    /// @notice The amount the step may spend right now
    function available() external view returns (uint256);

    /// @notice DAO actions that record the spend. The plugin appends them last, on every step.
    function commitActions(Plan calldata plan) external view returns (Action[] memory);
}

/// @title ICheckpointedBudget
/// @notice A budget that can be restarted from zero
interface ICheckpointedBudget is IBudget {
    /// @notice Restarts the available amount from zero
    function writeCheckpoint() external;
}
```

**Step 4: Create `src/interfaces/IStepAction.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IBudget} from "./IBudget.sol";
import {Plan} from "../lib/types.sol";

/// @title IStepAction
/// @notice Converts a step's input into its output. The plugin calls all three hooks, in order,
///         on every step that has an action, so an action's safety checks can't be left out.
interface IStepAction {
    /// @notice The budget this action is bound to, or address(0) if it works with any budget
    function budget() external view returns (IBudget);

    /// @notice Reverts if the action must not run
    function preconditions(address caller, Plan calldata draft) external view;

    /// @notice Caps `inAmount`, sets `outToken`/`outAmount`, returns the actions that do the work
    /// @dev `outAmount` must be known here: the splitter divides it before anything executes
    function build(address caller, bytes calldata data, Plan calldata draft)
        external
        view
        returns (Plan memory plan, Action[] memory actions);

    /// @notice The checks that make the work safe, executed by the DAO right after it
    function postconditions(address caller, Plan calldata plan) external view returns (Action[] memory);
}
```

**Step 5: Create `src/interfaces/ISplitter.sol`**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Allocation} from "../lib/types.sol";

/// @title ISplitter
/// @notice Divides a step's output among recipients
interface ISplitter {
    /// @notice Allocations of `amount`. The plugin rejects allocations that add up to more.
    function split(uint256 amount) external view returns (Allocation[] memory);
}
```

**Step 6: Create `src/interfaces/IFiller.sol`**

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
interface IFiller {
    function fillOffer(
        IERC20 offeredToken,
        uint256 offeredAmount,
        IERC20 demandedToken,
        uint256 demandedAmount,
        bytes calldata data
    ) external;
}
```

**Step 7: Build**

Run: `forge build`
Expected: `Compiler run successful!`

**Step 8: Commit**

```bash
git add src/lib src/interfaces
git commit -m "Add step types, permission IDs and the budget, action, splitter and filler interfaces"
```

---

### Task 3: FundedStreamBudget (adapt the existing file)

Changes from the reference copy:
- implements `ICheckpointedBudget`; `budget()` is renamed `available()`
- the DAO is the vault (`dao()`), so the `vault` parameter is gone
- OSx `auth` replaces `onlyVault`: `CHECKPOINT_PERMISSION_ID` for `writeCheckpoint`, `MANAGER_PERMISSION_ID` for setters
- new `setAmountPerEpoch` and `setMaxBudget`, both calling `_sync()` first like `setEpochInterval`
- ERC165, `budgetId` and `IStreamingBudget` removed; the token must have code (rejects native ETH)

**Files:**
- Create: `test/mocks/ERC20Mock.sol`, `test/helpers/Fixture.sol`, `test/FundedStreamBudget.t.sol`
- Move and rewrite: `FundedStreamBudget.sol` → `src/budgets/FundedStreamBudget.sol`

**Step 1: Create `test/mocks/ERC20Mock.sol`**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Anyone can mint. Test only.
contract ERC20Mock is ERC20 {
    constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) {}

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }
}
```

**Step 2: Create `test/helpers/Fixture.sol`**

Later tasks add one deploy helper each.

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {FundedStreamBudget} from "../../src/budgets/FundedStreamBudget.sol";
import {MANAGER_PERMISSION_ID, CHECKPOINT_PERMISSION_ID} from "../../src/lib/constants.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

/// @notice A DAO holding the offered token A and some pre-existing demanded token B.
///         The test contract is the DAO's ROOT, so it can grant permissions directly.
abstract contract Fixture is Test {
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;
    address internal constant ANY_ADDR = address(type(uint160).max);

    uint256 internal constant DAO_A = 100 ether; // offered token held by the DAO
    uint256 internal constant DAO_B = 500 ether; // pre-existing demanded token: must never be spent
    uint256 internal constant RATE = 10 ether; // offer growth per epoch
    uint256 internal constant EPOCH = 1 days;
    uint256 internal constant DEMAND = 1000 ether; // B demanded per fill
    uint256 internal constant MIN_PRICE = 50 ether; // 50 B per A, 1e18-scaled → maxOffered = 20 A

    address internal manager = makeAddr("manager");
    address internal fee = makeAddr("fee");

    DAO internal dao;
    ERC20Mock internal tokenA;
    ERC20Mock internal tokenB;

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
}
```

**Step 3: Write the failing test `test/FundedStreamBudget.t.sol`**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {DaoUnauthorized} from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FundedStreamBudget} from "../src/budgets/FundedStreamBudget.sol";
import {Plan} from "../src/lib/types.sol";
import {MANAGER_PERMISSION_ID, CHECKPOINT_PERMISSION_ID} from "../src/lib/constants.sol";
import {Fixture} from "./helpers/Fixture.sol";

contract FundedStreamBudgetTest is Fixture {
    FundedStreamBudget internal budget;

    function setUp() public override {
        super.setUp();
        budget = _deployBudget(RATE, 0);
    }

    function test_GrowsAtRatePerEpoch() public {
        assertEq(budget.available(), 0);

        vm.warp(block.timestamp + EPOCH);
        assertEq(budget.available(), RATE);

        vm.warp(block.timestamp + EPOCH / 2);
        assertEq(budget.available(), RATE + RATE / 2);
    }

    function test_DepositDoesNotLiftTheCapUntilSync() public {
        vm.warp(block.timestamp + 20 * EPOCH); // 200 accrued, capped at the 100 seen
        assertEq(budget.available(), DAO_A);

        tokenA.mint(address(dao), 50 ether);
        assertEq(budget.available(), DAO_A, "deposit must not lift the cap");

        budget.sync();
        assertEq(budget.available(), DAO_A, "sync must not jump");

        vm.warp(block.timestamp + EPOCH);
        assertEq(budget.available(), DAO_A + RATE, "growth resumes from where it froze");
    }

    function test_CommitActionsWriteCheckpoint() public view {
        Plan memory _plan;
        Action[] memory _actions = budget.commitActions(_plan);

        assertEq(_actions.length, 1);
        assertEq(_actions[0].to, address(budget));
        assertEq(_actions[0].value, 0);
        assertEq(_actions[0].data, abi.encodeCall(budget.writeCheckpoint, ()));
    }

    function test_WriteCheckpointRestartsFromZero() public {
        vm.warp(block.timestamp + EPOCH);

        vm.prank(address(dao));
        budget.writeCheckpoint();

        assertEq(budget.available(), 0);
    }

    function test_SetAmountPerEpochKeepsWhatAccrued() public {
        vm.warp(block.timestamp + EPOCH);

        vm.prank(manager);
        budget.setAmountPerEpoch(2 * RATE);
        assertEq(budget.available(), RATE, "no change in the same block");

        vm.warp(block.timestamp + EPOCH);
        assertEq(budget.available(), RATE + 2 * RATE, "new rate from now on");
    }

    function test_RaisingMaxBudgetDoesNotJump() public {
        vm.prank(manager);
        budget.setMaxBudget(5 ether);

        vm.warp(block.timestamp + 2 * EPOCH); // 20 accrued, capped at 5
        assertEq(budget.available(), 5 ether);

        vm.prank(manager);
        budget.setMaxBudget(0);
        assertEq(budget.available(), 5 ether, "hidden accrual must not be released");

        vm.warp(block.timestamp + EPOCH);
        assertEq(budget.available(), 5 ether + RATE);
    }

    function test_SetEpochIntervalKeepsWhatAccrued() public {
        vm.warp(block.timestamp + EPOCH);

        vm.prank(manager);
        budget.setEpochInterval(2 * EPOCH);
        assertEq(budget.available(), RATE);

        vm.warp(block.timestamp + 2 * EPOCH);
        assertEq(budget.available(), 2 * RATE);
    }

    function test_RevertWhen_WriteCheckpointUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector, address(dao), address(budget), address(this), CHECKPOINT_PERMISSION_ID
            )
        );
        budget.writeCheckpoint();
    }

    function test_RevertWhen_SetterUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector, address(dao), address(budget), address(this), MANAGER_PERMISSION_ID
            )
        );
        budget.setAmountPerEpoch(1);
    }

    function test_RevertWhen_TokenHasNoCode() public {
        FundedStreamBudget _budget =
            FundedStreamBudget(ProxyLib.deployMinimalProxy(address(new FundedStreamBudget()), ""));

        vm.expectRevert(FundedStreamBudget.InvalidToken.selector);
        _budget.initialize(dao, IERC20(address(0)), RATE, 0, EPOCH);
    }
}
```

**Step 4: Run it to make sure it fails**

Run: `forge test --match-contract FundedStreamBudgetTest`
Expected: compilation fails with `Source "src/budgets/FundedStreamBudget.sol" not found`

**Step 5: Move the file**

```bash
mkdir -p src/budgets
git mv FundedStreamBudget.sol src/budgets/FundedStreamBudget.sol
```

**Step 6: Replace `src/budgets/FundedStreamBudget.sol` with the adapted version**

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
import {ICheckpointedBudget} from "../interfaces/IBudget.sol";
import {Plan} from "../lib/types.sol";
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
///        the spend. The plugin appends it as the last action of every step (`commitActions`).
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
///      One step per instance.
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

    /// @notice Thrown when the token has no code (includes native ETH, unsupported in v1)
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
    /// @param _token The token streamed (ERC20 only)
    /// @param _amountPerEpoch How much the available amount grows per epoch
    /// @param _maxBudget Maximum available amount at any point in time (0 for no cap)
    /// @param _epochInterval The epoch duration in seconds
    function initialize(IDAO _dao, IERC20 _token, uint256 _amountPerEpoch, uint256 _maxBudget, uint256 _epochInterval)
        external
        initializer
    {
        if (address(_token).code.length == 0) revert InvalidToken();

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

    /// @notice Restarts the stream after the spend: the plugin appends this as the step's last action
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
    /// @dev Executed by the DAO as a step's last action, so the recorded balance is what is left
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

        if (lastSeenBalance < _amount) _amount = lastSeenBalance;
        if (_balance < _amount) _amount = _balance;
        if (maxBudget != 0 && maxBudget < _amount) _amount = maxBudget;
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
        return token.balanceOf(address(dao()));
    }
}
```

**Step 7: Run the tests**

Run: `forge test --match-contract FundedStreamBudgetTest`
Expected: `10 passed; 0 failed`

**Step 8: Commit**

```bash
git add test src/budgets
git commit -m "Adapt FundedStreamBudget to the pipeline: DAO as vault, OSx permissions, settle-first setters"
```

---

### Task 4: RatioSplitter

**Files:**
- Modify: `test/helpers/Fixture.sol`
- Create: `test/RatioSplitter.t.sol`, `src/splitters/RatioSplitter.sol`

**Step 1: Add the splitter helper to `test/helpers/Fixture.sol`**

Add this import after the `FundedStreamBudget` import:

```solidity
import {RatioSplitter} from "../../src/splitters/RatioSplitter.sol";
```

Add this function at the end of the contract:

```solidity
    /// @dev 95% to the burn address, 5% to the fee address
    function _deploySplitter() internal returns (RatioSplitter _splitter) {
        address[] memory _recipients = new address[](2);
        (_recipients[0], _recipients[1]) = (BURN, fee);
        uint32[] memory _ratios = new uint32[](2);
        (_ratios[0], _ratios[1]) = (950_000, 50_000);

        _splitter = RatioSplitter(
            ProxyLib.deployMinimalProxy(
                address(new RatioSplitter()), abi.encodeCall(RatioSplitter.initialize, (dao, _recipients, _ratios))
            )
        );
        dao.grant(address(_splitter), manager, MANAGER_PERMISSION_ID);
    }
```

**Step 2: Write the failing test `test/RatioSplitter.t.sol`**

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

**Step 3: Run it to make sure it fails**

Run: `forge test --match-contract RatioSplitterTest`
Expected: compilation fails with `Source "src/splitters/RatioSplitter.sol" not found`

**Step 4: Create `src/splitters/RatioSplitter.sol`**

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

**Step 5: Run the tests**

Run: `forge test --match-contract RatioSplitterTest`
Expected: `9 passed; 0 failed`

**Step 6: Commit**

```bash
git add test src/splitters
git commit -m "Add RatioSplitter: remainder goes to the largest share so splits are exact"
```

---

### Task 5: OpenFillAction

**Files:**
- Modify: `test/helpers/Fixture.sol`
- Create: `test/OpenFillAction.t.sol`, `src/actions/OpenFillAction.sol`

**Step 1: Add the action helper to `test/helpers/Fixture.sol`**

Add this import after the `RatioSplitter` import:

```solidity
import {OpenFillAction} from "../../src/actions/OpenFillAction.sol";
```

Add this function at the end of the contract:

```solidity
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
```

**Step 2: Write the failing test `test/OpenFillAction.t.sol`**

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
        return Plan({inToken: tokenA, inAmount: _available, outToken: tokenA, outAmount: _available});
    }

    function _clone() internal returns (OpenFillAction) {
        return OpenFillAction(ProxyLib.deployMinimalProxy(address(new OpenFillAction()), ""));
    }
}
```

**Step 3: Run it to make sure it fails**

Run: `forge test --match-contract OpenFillActionTest`
Expected: compilation fails with `Source "src/actions/OpenFillAction.sol" not found`

**Step 4: Create `src/actions/OpenFillAction.sol`**

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
import {IStepAction} from "../interfaces/IStepAction.sol";
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
contract OpenFillAction is IStepAction, Initializable, DaoAuthorizableUpgradeable {
    /// @inheritdoc IStepAction
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

    /// @inheritdoc IStepAction
    /// @dev None in v1
    function preconditions(address, Plan calldata) external view virtual {}

    /// @inheritdoc IStepAction
    /// @dev Approves the offer to the caller, calls it back, and clears the approval
    function build(address _caller, bytes calldata _data, Plan calldata _draft)
        external
        view
        virtual
        returns (Plan memory _plan, Action[] memory _actions)
    {
        uint256 _offered = _draft.inAmount < maxOffered() ? _draft.inAmount : maxOffered();
        if (_offered == 0) return (_plan, _actions);

        _plan = Plan({inToken: _draft.inToken, inAmount: _offered, outToken: demandedToken, outAmount: demandPerFill});

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

    /// @inheritdoc IStepAction
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

**Step 5: Run the tests**

Run: `forge test --match-contract OpenFillActionTest`
Expected: `14 passed; 0 failed`

**Step 6: Commit**

```bash
git add test src/actions
git commit -m "Add OpenFillAction: Dutch-auction swap that owns its received-amount postcondition"
```

---

### Task 6: Plugin: step configuration

**Files:**
- Modify: `test/helpers/Fixture.sol`
- Create: `test/CapitalPipelinePlugin.t.sol`, `src/CapitalPipelinePlugin.sol`

**Step 1: Add the plugin helpers to `test/helpers/Fixture.sol`**

Replace the line importing `MANAGER_PERMISSION_ID, CHECKPOINT_PERMISSION_ID` with:

```solidity
import {CapitalPipelinePlugin} from "../../src/CapitalPipelinePlugin.sol";
import {IBudget} from "../../src/interfaces/IBudget.sol";
import {IStepAction} from "../../src/interfaces/IStepAction.sol";
import {ISplitter} from "../../src/interfaces/ISplitter.sol";
import {Step} from "../../src/lib/types.sol";
import {
    MANAGER_PERMISSION_ID,
    CHECKPOINT_PERMISSION_ID,
    TRIGGER_PERMISSION_ID,
    CONFIGURE_PERMISSION_ID
} from "../../src/lib/constants.sol";
```

Add these functions at the end of the contract:

```solidity
    /// @dev Same grants as CapitalPipelinePluginSetup: anyone triggers, the DAO configures, the manager pauses
    function _deployPlugin(Step[] memory _pipeline) internal returns (CapitalPipelinePlugin _plugin) {
        _plugin = CapitalPipelinePlugin(
            ProxyLib.deployMinimalProxy(
                address(new CapitalPipelinePlugin()), abi.encodeCall(CapitalPipelinePlugin.initialize, (dao, _pipeline))
            )
        );
        dao.grant(address(dao), address(_plugin), dao.EXECUTE_PERMISSION_ID());
        dao.grant(address(_plugin), ANY_ADDR, TRIGGER_PERMISSION_ID);
        dao.grant(address(_plugin), address(dao), CONFIGURE_PERMISSION_ID);
        dao.grant(address(_plugin), manager, MANAGER_PERMISSION_ID);
    }

    function _steps(IBudget _budget, IStepAction _action, ISplitter _splitter)
        internal
        pure
        returns (Step[] memory _list)
    {
        _list = new Step[](1);
        _list[0] = Step({budget: _budget, action: _action, splitter: _splitter});
    }
```

**Step 2: Write the failing test `test/CapitalPipelinePlugin.t.sol`**

```solidity
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
```

**Step 3: Run it to make sure it fails**

Run: `forge test --match-contract CapitalPipelinePluginTest`
Expected: compilation fails with `Source "src/CapitalPipelinePlugin.sol" not found`

**Step 4: Create `src/CapitalPipelinePlugin.sol` (configuration only)**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {PluginCloneable} from "@aragon/osx-commons-contracts/src/plugin/PluginCloneable.sol";
import {IBudget} from "./interfaces/IBudget.sol";
import {Step} from "./lib/types.sol";
import {CONFIGURE_PERMISSION_ID, MANAGER_PERMISSION_ID} from "./lib/constants.sol";

/// @title CapitalPipelinePlugin
/// @notice Runs a list of steps. Each step: budget → action (preconditions → build →
///         postconditions) → splitter → budget commit, executed by the DAO in one `execute`.
contract CapitalPipelinePlugin is PluginCloneable {
    Step[] internal _steps;

    /// @notice When true, `trigger` reverts
    bool public paused;

    event StepsUpdated(Step[] steps);
    event PausedSet(bool paused);

    error NoSteps();
    error NoBudget(uint256 stepIndex);
    error BudgetMismatch(uint256 stepIndex);

    function initialize(IDAO _dao, Step[] calldata _newSteps) external initializer {
        __PluginCloneable_init(_dao);
        _setSteps(_newSteps);
    }

    /// @notice Replaces all steps. DAO only: a step can return arbitrary DAO actions.
    function setSteps(Step[] calldata _newSteps) external auth(CONFIGURE_PERMISSION_ID) {
        _setSteps(_newSteps);
    }

    /// @notice Pauses or unpauses every step
    function setPaused(bool _paused) external auth(MANAGER_PERMISSION_ID) {
        paused = _paused;
        emit PausedSet(_paused);
    }

    function steps() external view returns (Step[] memory) {
        return _steps;
    }

    // Internal

    function _setSteps(Step[] calldata _newSteps) internal {
        if (_newSteps.length == 0) revert NoSteps();

        delete _steps;
        for (uint256 i; i < _newSteps.length; ++i) {
            Step calldata _step = _newSteps[i];
            if (address(_step.budget) == address(0)) revert NoBudget(i);
            if (address(_step.action) != address(0)) {
                IBudget _bound = _step.action.budget();
                if (address(_bound) != address(0) && _bound != _step.budget) revert BudgetMismatch(i);
            }
            _steps.push(_step);
        }

        emit StepsUpdated(_newSteps);
    }
}
```

**Step 5: Run the tests**

Run: `forge test --match-contract CapitalPipelinePluginTest`
Expected: `7 passed; 0 failed`

**Step 6: Commit**

```bash
git add test src/CapitalPipelinePlugin.sol
git commit -m "Add pipeline plugin configuration: DAO-only setSteps, manager pause, budget binding check"
```

---

### Task 7: Plugin: trigger

**Files:**
- Create: `test/mocks/MockFiller.sol`, `test/mocks/BadComponents.sol`
- Replace: `test/CapitalPipelinePlugin.t.sol`, `src/CapitalPipelinePlugin.sol`

**Step 1: Create `test/mocks/MockFiller.sol`**

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

**Step 2: Create `test/mocks/BadComponents.sol`**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IBudget} from "../../src/interfaces/IBudget.sol";
import {IStepAction} from "../../src/interfaces/IStepAction.sol";
import {ISplitter} from "../../src/interfaces/ISplitter.sol";
import {Plan, Allocation} from "../../src/lib/types.sol";

/// @notice An action that misbehaves in one of three ways
contract BadAction is IStepAction {
    enum Mode {
        Block, // preconditions revert
        TargetDao, // build returns an action whose target is the DAO
        Overspend // build claims 1 wei more than the budget allows
    }

    error Blocked();

    Mode public immutable mode;
    address public immutable dao;

    constructor(Mode _mode, address _dao) {
        mode = _mode;
        dao = _dao;
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
        _plan = _draft;
        if (mode == Mode.Overspend) _plan.inAmount += 1;
        if (mode == Mode.TargetDao) {
            _actions = new Action[](1);
            _actions[0] = Action({to: dao, value: 0, data: ""});
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
```

**Step 3: Replace `test/CapitalPipelinePlugin.t.sol` with the trigger tests added**

`setUp` now also deploys a filler and advances one epoch, so 10 A are on offer.

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
import {IStepAction} from "../src/interfaces/IStepAction.sol";
import {ISplitter} from "../src/interfaces/ISplitter.sol";
import {Step} from "../src/lib/types.sol";
import {CONFIGURE_PERMISSION_ID} from "../src/lib/constants.sol";
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
        plugin.setPaused(true);

        vm.expectRevert(CapitalPipelinePlugin.Paused.selector);
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

    function _bad(BadAction.Mode _mode) internal returns (IStepAction) {
        return new BadAction(_mode, address(dao));
    }

    function _clone() internal returns (CapitalPipelinePlugin) {
        return CapitalPipelinePlugin(ProxyLib.deployMinimalProxy(address(new CapitalPipelinePlugin()), ""));
    }
}
```

**Step 4: Run it to make sure it fails**

Run: `forge test --match-contract CapitalPipelinePluginTest`
Expected: compilation fails with `Member "trigger" not found or not visible after argument-dependent lookup in contract CapitalPipelinePlugin`

**Step 5: Replace `src/CapitalPipelinePlugin.sol` with the trigger added**

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {IExecutor, Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {PluginCloneable} from "@aragon/osx-commons-contracts/src/plugin/PluginCloneable.sol";
import {IBudget} from "./interfaces/IBudget.sol";
import {IStepAction} from "./interfaces/IStepAction.sol";
import {ISplitter} from "./interfaces/ISplitter.sol";
import {Plan, Allocation, Step} from "./lib/types.sol";
import {TRIGGER_PERMISSION_ID, CONFIGURE_PERMISSION_ID, MANAGER_PERMISSION_ID} from "./lib/constants.sol";

/// @title CapitalPipelinePlugin
/// @notice Runs a list of steps. Each step: budget → action (preconditions → build →
///         postconditions) → splitter → budget commit, executed by the DAO in one `execute`.
/// @dev Planning is view-only; every state change is a DAO action. What the plugin enforces for
///      every step, whatever its components do: all hooks run in order, the input never exceeds
///      the budget, and allocations never exceed the output.
contract CapitalPipelinePlugin is PluginCloneable {
    Step[] internal _steps;

    /// @notice When true, `trigger` reverts
    bool public paused;

    /// @dev Makes every execution ID unique
    uint256 internal _nonce;

    event StepsUpdated(Step[] steps);
    event PausedSet(bool paused);
    event StepExecuted(uint256 indexed stepIndex, address indexed caller, bytes32 executionId, Plan plan);

    error NoSteps();
    error NoBudget(uint256 stepIndex);
    error BudgetMismatch(uint256 stepIndex);
    error Paused();
    error DataLengthMismatch(uint256 expected, uint256 actual);
    error InAmountExceedsBudget(uint256 stepIndex, uint256 inAmount, uint256 available);
    error AllocationExceedsOutput(uint256 stepIndex, uint256 allocated, uint256 outAmount);
    error InvalidOutToken(uint256 stepIndex);

    function initialize(IDAO _dao, Step[] calldata _newSteps) external initializer {
        __PluginCloneable_init(_dao);
        _setSteps(_newSteps);
    }

    /// @notice Runs every step in order
    /// @param _data Empty, or one entry per step (passed to that step's action)
    function trigger(bytes[] calldata _data) external auth(TRIGGER_PERMISSION_ID) {
        if (paused) revert Paused();

        uint256 _len = _steps.length;
        if (_data.length != 0 && _data.length != _len) revert DataLengthMismatch(_len, _data.length);

        uint256 _callNonce = _nonce++;
        for (uint256 i; i < _len; ++i) {
            _runStep(i, _data.length == 0 ? msg.data[0:0] : _data[i], _callNonce);
        }
    }

    /// @notice Replaces all steps. DAO only: a step can return arbitrary DAO actions.
    function setSteps(Step[] calldata _newSteps) external auth(CONFIGURE_PERMISSION_ID) {
        _setSteps(_newSteps);
    }

    /// @notice Pauses or unpauses every step
    function setPaused(bool _paused) external auth(MANAGER_PERMISSION_ID) {
        paused = _paused;
        emit PausedSet(_paused);
    }

    function steps() external view returns (Step[] memory) {
        return _steps;
    }

    // Internal

    function _runStep(uint256 _index, bytes calldata _data, uint256 _callNonce) internal {
        Step memory _step = _steps[_index];

        (Plan memory _plan, Action[] memory _actions) = _planStep(_index, _step, _data);
        if (_plan.inAmount == 0) return;

        bytes32 _executionId = keccak256(abi.encode(address(this), _callNonce, _index));
        IExecutor(address(dao())).execute(_executionId, _actions, 0);

        emit StepExecuted(_index, msg.sender, _executionId, _plan);
    }

    /// @dev Calls every component in order and concatenates their actions
    function _planStep(uint256 _index, Step memory _step, bytes calldata _data)
        internal
        view
        returns (Plan memory _plan, Action[] memory _actions)
    {
        uint256 _available = _step.budget.available();
        IERC20 _token = _step.budget.token();
        _plan = Plan({inToken: _token, inAmount: _available, outToken: _token, outAmount: _available});

        Action[] memory _work;
        Action[] memory _checks;
        bool _hasAction = address(_step.action) != address(0);

        if (_hasAction) {
            _step.action.preconditions(msg.sender, _plan);
            (_plan, _work) = _step.action.build(msg.sender, _data, _plan);
        }
        if (_plan.inAmount == 0) return (_plan, _actions);
        if (_plan.inAmount > _available) revert InAmountExceedsBudget(_index, _plan.inAmount, _available);

        if (_hasAction) _checks = _step.action.postconditions(msg.sender, _plan);

        _actions =
            _concat(_work, _checks, _splitActions(_index, _step.splitter, _plan), _step.budget.commitActions(_plan));
    }

    /// @dev One ERC20 transfer per non-zero allocation. No splitter: the output stays in the DAO.
    function _splitActions(uint256 _index, ISplitter _splitter, Plan memory _plan)
        internal
        view
        returns (Action[] memory _transfers)
    {
        if (address(_splitter) == address(0) || _plan.outAmount == 0) return _transfers;
        if (address(_plan.outToken).code.length == 0) revert InvalidOutToken(_index);

        Allocation[] memory _allocations = _splitter.split(_plan.outAmount);

        uint256 _total;
        uint256 _count;
        for (uint256 i; i < _allocations.length; ++i) {
            _total += _allocations[i].amount;
            if (_allocations[i].amount != 0) ++_count;
        }
        if (_total > _plan.outAmount) revert AllocationExceedsOutput(_index, _total, _plan.outAmount);

        _transfers = new Action[](_count);
        uint256 _j;
        for (uint256 i; i < _allocations.length; ++i) {
            if (_allocations[i].amount == 0) continue;
            _transfers[_j++] = Action({
                to: address(_plan.outToken),
                value: 0,
                data: abi.encodeCall(IERC20.transfer, (_allocations[i].recipient, _allocations[i].amount))
            });
        }
    }

    function _concat(Action[] memory _a, Action[] memory _b, Action[] memory _c, Action[] memory _d)
        internal
        pure
        returns (Action[] memory _out)
    {
        _out = new Action[](_a.length + _b.length + _c.length + _d.length);
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
        for (uint256 i; i < _d.length; ++i) {
            _out[_k++] = _d[i];
        }
    }

    function _setSteps(Step[] calldata _newSteps) internal {
        if (_newSteps.length == 0) revert NoSteps();

        delete _steps;
        for (uint256 i; i < _newSteps.length; ++i) {
            Step calldata _step = _newSteps[i];
            if (address(_step.budget) == address(0)) revert NoBudget(i);
            if (address(_step.action) != address(0)) {
                IBudget _bound = _step.action.budget();
                if (address(_bound) != address(0) && _bound != _step.budget) revert BudgetMismatch(i);
            }
            _steps.push(_step);
        }

        emit StepsUpdated(_newSteps);
    }
}
```

**Step 6: Run the tests**

Run: `forge test --match-contract CapitalPipelinePluginTest`
Expected: `16 passed; 0 failed`

**Step 7: Commit**

```bash
git add test src/CapitalPipelinePlugin.sol
git commit -m "Add trigger: run each step's hooks in order and execute its actions in one DAO call"
```

---

### Task 8: Plugin: reentrancy and DAO-target guards

**Files:**
- Modify: `test/CapitalPipelinePlugin.t.sol`, `src/CapitalPipelinePlugin.sol`

**Step 1: Add the guard tests to `test/CapitalPipelinePlugin.t.sol`**

Insert right above `function _bad(BadAction.Mode _mode)`:

```solidity
    // Guards

    function test_RevertWhen_AnActionTargetsTheDao() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(_steps(budget, _bad(BadAction.Mode.TargetDao), splitter));

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.ActionTargetsDao.selector, 0, 0));
        _plugin.trigger(new bytes[](0));
    }

    function test_FillerCannotReenterTrigger() public {
        filler.setReenter(true);

        filler.fill("");

        assertEq(filler.reentryError(), abi.encodeWithSelector(CapitalPipelinePlugin.Reentrant.selector));
        assertEq(tokenB.balanceOf(BURN), 950 ether, "the outer fill still completes");
    }
```

**Step 2: Declare the two errors in `src/CapitalPipelinePlugin.sol`**

Add `error Reentrant();` right after `error Paused();`, and add this right after `error InvalidOutToken(uint256 stepIndex);`:

```solidity
    error ActionTargetsDao(uint256 stepIndex, uint256 actionIndex);
```

**Step 3: Run the tests to make sure they fail for the right reason**

Run: `forge test --match-contract CapitalPipelinePluginTest`
Expected: 2 failures:
- `test_FillerCannotReenterTrigger`: `assertion failed: 0x37ed32e8 != 0xed3ba6a6`. The DAO's own `ReentrantCall` (`0x37ed32e8`) caught the re-entry, not the plugin.
- `test_RevertWhen_AnActionTargetsTheDao`: `next call did not revert as expected`

**Step 4: Add the reentrancy lock**

Add this state variable right after `uint256 internal _nonce;`:

```solidity
    /// @dev Reentrancy lock. Transient, so it needs no initialization on clones.
    bool internal transient _entered;
```

In `trigger`, make these the first two statements of the body:

```solidity
        if (_entered) revert Reentrant();
        _entered = true;
```

and make this the last statement, after the `for` loop:

```solidity
        _entered = false;
```

**Step 5: Reject actions that target the DAO**

In `_runStep`, insert right after `if (_plan.inAmount == 0) return;`:

```solidity
        _rejectDaoTargets(_index, _actions);
```

Add this function right above `function _concat`:

```solidity
    function _rejectDaoTargets(uint256 _index, Action[] memory _actions) internal view {
        address _dao = address(dao());
        for (uint256 i; i < _actions.length; ++i) {
            if (_actions[i].to == _dao) revert ActionTargetsDao(_index, i);
        }
    }
```

Change the last line of the contract's `@dev` comment to:

```solidity
///      the budget, allocations never exceed the output, and no action targets the DAO itself.
```

**Step 6: Run the tests**

Run: `forge test --match-contract CapitalPipelinePluginTest`
Expected: `18 passed; 0 failed`

**Step 7: Commit**

```bash
git add test src/CapitalPipelinePlugin.sol
git commit -m "Guard trigger against re-entry and against steps that target the DAO itself"
```

---

### Task 9: Plugin setup

**Files:**
- Create: `test/CapitalPipelinePluginSetup.t.sol`, `src/setup/CapitalPipelinePluginSetup.sol`

**Step 1: Write the failing test `test/CapitalPipelinePluginSetup.t.sol`**

```solidity
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
```

**Step 2: Run it to make sure it fails**

Run: `forge test --match-contract CapitalPipelinePluginSetupTest`
Expected: compilation fails with `Source "src/setup/CapitalPipelinePluginSetup.sol" not found`

**Step 3: Create `src/setup/CapitalPipelinePluginSetup.sol`**

It imports `PluginSetup` and `PermissionLib` from osx-commons rather than from `PluginSetupProcessor.sol`, so the ENS dependencies aren't needed.

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
```

**Step 4: Run the tests**

Run: `forge test --match-contract CapitalPipelinePluginSetupTest`
Expected: `3 passed; 0 failed`

**Step 5: Check the setup's init code stays under the limit**

Run: `forge build --sizes | grep CapitalPipelinePluginSetup`
Expected: initcode size about 26,562 bytes (the limit is 49,152)

**Step 6: Commit**

```bash
git add test src/setup
git commit -m "Add plugin setup that installs the swap-and-split step with the designed permissions"
```

---

### Task 10: Invariant test

This task adds coverage, not behavior, so the test should pass immediately.

**Files:**
- Create: `test/invariant/PipelineInvariant.t.sol`

**Step 1: Create `test/invariant/PipelineInvariant.t.sol`**

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
        CapitalPipelinePlugin _plugin = _deployPlugin(_steps(_budget, _action, _deploySplitter()));

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

**Step 2: Run it**

Run: `forge test --match-contract PipelineInvariantTest -vv`
Expected: 3 `[PASS] invariant_...` lines and `reverts: 0` in the call table. `fail_on_revert = true` turns any handler revert into a failure.

**Step 3: Commit**

```bash
git add test/invariant
git commit -m "Add invariants: pre-existing B is never spent and proceeds are split exactly"
```

---

### Task 11: Docs

**Files:**
- Create: `README.md`
- Modify: `docs/plans/2026-11-04-capital-pipeline-design.md`

**Step 1: Create `README.md`**

````markdown
# Capital Pipeline

Aragon OSx plugin that runs treasury flows as a list of steps. Each step is
**budget → action (preconditions → build → postconditions) → splitter**, executed by the DAO in a
single `execute`. v1 ships one flow: an open-fill Dutch auction that sells token A for token B, then
splits the B received (for example 95% to a burn address, 5% to a fee address).

Design: [`docs/plans/2026-11-04-capital-pipeline-design.md`](docs/plans/2026-11-04-capital-pipeline-design.md)

## Layout

| Path | What |
|---|---|
| `src/CapitalPipelinePlugin.sol` | Runs the steps and enforces the shared guards |
| `src/budgets/FundedStreamBudget.sol` | Streaming pot that never jumps |
| `src/actions/OpenFillAction.sol` | Open-fill swap with Dutch-auction pricing |
| `src/splitters/RatioSplitter.sol` | Fixed-ratio split, remainder to the largest share |
| `src/setup/CapitalPipelinePluginSetup.sol` | Installs the swap-and-split flow |

## Permissions

| Permission | Holder | Allows |
|---|---|---|
| `TRIGGER_PERMISSION_ID` | anyone | `trigger()` |
| `CONFIGURE_PERMISSION_ID` | DAO only | `setSteps()` |
| `MANAGER_PERMISSION_ID` | manager | parameter setters, `setPaused()` |
| `CHECKPOINT_PERMISSION_ID` | DAO, swap action | restarting the budget |

## Develop

```shell
git submodule update --init --recursive
forge build
forge test
```

Never set `via_ir = true`; fix stack-too-deep errors by restructuring the code.
````

**Step 2: Record the implementation details in the design doc**

In the `IStepAction` interface block, add as the first function:

```solidity
    /// The budget this action is bound to, or address(0) if it works with any budget
    function budget() external view returns (IBudget);
```

Append at the end of the doc:

```markdown
## Implementation notes

Details settled while implementing v1:

- `IStepAction.budget()` returns the budget an action is bound to (address(0) if any). `setSteps` uses it to reject a step whose action is bound to a different budget.
- `ICheckpointedBudget` extends `IBudget` with `writeCheckpoint()`. `OpenFillAction` requires one, so its price setters can restart the auction.
- `IFiller.fillOffer` keeps the selector of capital-router's `ISwapSolver.fillOffer`, so existing fillers work unchanged.
- `FundedStreamBudget` drops ERC165, `budgetId` and the `vault` parameter (the vault is `dao()`). Tokens must have code, which also rejects native ETH.
- The reentrancy lock on `trigger` uses a transient storage variable, so clones need no initialization.
```

**Step 3: Full check**

Run: `forge fmt --check && forge test`
Expected: no formatting diff, then `55 tests passed, 0 failed`

**Step 4: Commit**

```bash
git add README.md docs/plans/2026-11-04-capital-pipeline-design.md
git commit -m "Document the pipeline layout, permissions and implementation details"
```
