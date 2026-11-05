// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {
    DaoAuthorizableUpgradeable
} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizableUpgradeable.sol";
import {ICheckpointedBudget} from "../interfaces/IBudget.sol";
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
contract FundedStreamBudget is ICheckpointedBudget, DaoAuthorizableUpgradeable {
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
    function commitActions() external view virtual returns (Action[] memory _actions) {
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
