// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IPotBudget} from "../interfaces/IPotBudget.sol";
import {IStreamingBudget} from "../interfaces/IStreamingBudget.sol";
import {FUNDED_STREAM_BUDGET_ID} from "../lib/constants.sol";

/// @title FundedStreamBudget
/// @notice A streaming pot whose available amount only grows while the vault can fund it. Built
///         for Dutch auctions (`OpenFillRequestStrategy` + `AuctionFillPolicy`), where the offered
///         amount must rise continuously and never jump.
/// @dev **Why not `StreamBudget`.** `StreamBudget` returns `min(rate x elapsed, balance)`. The
///      balance caps the amount but does not stop the clock, so while the vault is short the
///      elapsed time keeps accruing out of sight. When funds arrive, the cap lifts and the amount
///      jumps to the whole backlog, which an auction filler takes in the same block.
///
///      **How this budget avoids it.** The available amount is
///
///          min(baseAmount + rate x (now - baseTimestamp), lastSeenBalance, vaultBalance, maxBudget)
///
///      - `lastSeenBalance` is the vault balance seen at the last checkpoint or sync. A deposit
///        does not move it, so the amount cannot rise above it until a transaction picks the
///        deposit up.
///      - `sync()` (permissionless) stores the current amount as `baseAmount`, sets `baseTimestamp`
///        to now and records the vault balance. The amount is the same just before and just after
///        a sync, so growth hidden by `lastSeenBalance` is discarded and the stream resumes from
///        where it froze. Calling it repeatedly does not change the curve (at most 1 wei of
///        rounding per call).
///      - `writeCheckpoint()` (vault only) restarts the amount from zero and records the balance
///        left after the spend. Strategies append it as the last action of a fill or dispatch.
///      - The vault balance itself caps the amount if funds leave by another path after the last
///        sync.
///
///      **Liveness.** After a deposit the amount stays frozen until someone calls `sync()`. That
///      is safe (the amount never rises) but stalls the stream, so operators should run a keeper
///      or add a `sync()` action wherever revenue enters the vault.
///
///      **Residual case.** If funds leave the vault by another path and come back before any sync,
///      `lastSeenBalance` is stale and the growth accrued meanwhile is released, bounded by that
///      stale balance and, in an auction, the policy's `maxOffered()`. Proposals that spend the
///      vault token should include a `sync()` action, or the funds should sit in a vault whose
///      only outflow is this stream.
///
///      Pot only: `IQuotaBudget` is not declared, so quota-based request strategies reject it.
///      One strategy per instance, as with `StreamBudget`.
contract FundedStreamBudget is IPotBudget, IStreamingBudget, Initializable, ERC165 {
    /// @notice The address of the vault holding the funds
    address public vault;

    /// @notice The token streamed (address(0) for native ETH)
    IERC20 public vaultToken;

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

    /// @notice The vault balance seen at the last checkpoint or sync. The amount never rises above it.
    uint256 public lastSeenBalance;

    /// @notice Emitted when the contract settings are updated
    event BudgetSettingsUpdated(
        address vault, IERC20 vaultToken, uint256 amountPerEpoch, uint256 maxBudget, uint256 epochInterval
    );

    /// @notice Emitted when the epoch interval is updated
    event NewEpochInterval(uint256 epochInterval);

    /// @notice Emitted when the amount restarts from zero after a spend
    /// @param lastSeenBalance The vault balance left after the spend
    event CheckpointWritten(uint256 lastSeenBalance);

    /// @notice Emitted when the amount is carried forward and the vault balance recorded
    /// @param baseAmount The amount available at the time of the sync
    /// @param lastSeenBalance The vault balance seen by the sync
    event Synced(uint256 baseAmount, uint256 lastSeenBalance);

    /// @notice Thrown when the given vault address is empty
    error InvalidVault();

    /// @notice Thrown when the given epoch interval is zero
    error InvalidEpochInterval();

    /// @notice Thrown when a vault-only function is called by another address
    error OnlyVault();

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the budget. The amount starts at zero, capped by the current balance.
    /// @dev A vault that is empty at initialization keeps the amount at zero until `sync()` is
    ///      called after it is funded.
    /// @param _vault The address of the vault holding the funds
    /// @param _vaultToken The token streamed (address(0) for native ETH)
    /// @param _amountPerEpoch How much the available amount grows per epoch
    /// @param _maxBudget Maximum available amount at any point in time (0 for no cap)
    /// @param _epochInterval The epoch duration in seconds
    function initialize(
        address _vault,
        IERC20 _vaultToken,
        uint256 _amountPerEpoch,
        uint256 _maxBudget,
        uint256 _epochInterval
    ) external initializer {
        if (_vault == address(0)) revert InvalidVault();

        /// @dev _vaultToken may be zero (i.e. using the native token)
        vault = _vault;
        vaultToken = _vaultToken;
        amountPerEpoch = _amountPerEpoch;
        maxBudget = _maxBudget;
        _setEpochInterval(_epochInterval);

        emit BudgetSettingsUpdated(_vault, _vaultToken, _amountPerEpoch, _maxBudget, _epochInterval);

        _writeCheckpoint();
    }

    // IPotBudget

    /// @inheritdoc IPotBudget
    function token() public view virtual returns (IERC20) {
        return vaultToken;
    }

    /// @notice Returns the amount available right now
    /// @return min(baseAmount + rate x (now - baseTimestamp), lastSeenBalance, vaultBalance, maxBudget)
    function budget() public view virtual returns (uint256) {
        return _available(_vaultBalance());
    }

    /// @inheritdoc IPotBudget
    function budgetId() external pure virtual returns (string memory id) {
        return FUNDED_STREAM_BUDGET_ID;
    }

    /// @inheritdoc ERC165
    /// @dev Declares the pot kind and the streaming capability, so strategies append
    ///      `writeCheckpoint()` after each spend. Not a quota base.
    function supportsInterface(bytes4 _interfaceId) public view virtual override returns (bool) {
        return _interfaceId == type(IPotBudget).interfaceId || _interfaceId == type(IStreamingBudget).interfaceId
            || super.supportsInterface(_interfaceId);
    }

    // Lifecycle

    /// @notice Carries the current amount forward and records the vault balance
    /// @dev Permissionless: it never raises the current amount, it only lets the amount resume
    ///      growing after a deposit (or follow the balance down after an outflow).
    function sync() external virtual {
        _sync();
    }

    /// @notice Restarts the amount from zero and records the vault balance
    /// @dev Only callable by the vault. Strategies append it as the last action of a fill or
    ///      dispatch, so the recorded balance is what is left after the tokens have been handed over.
    function writeCheckpoint() public virtual onlyVault {
        _writeCheckpoint();
    }

    /// @notice Updates the epoch interval, which changes the growth rate
    /// @dev Only callable by the vault. Syncs first, so time already elapsed keeps the old rate
    ///      and the amount does not jump.
    /// @param _epochInterval The new epoch duration in seconds
    function setEpochInterval(uint256 _epochInterval) public virtual onlyVault {
        _sync();
        _setEpochInterval(_epochInterval);
    }

    // Internal

    /// @dev The amount available for a given vault balance
    function _available(uint256 _vaultBalance) internal view virtual returns (uint256 _amount) {
        _amount = baseAmount + (amountPerEpoch * (block.timestamp - baseTimestamp)) / epochInterval;

        if (lastSeenBalance < _amount) _amount = lastSeenBalance;
        if (_vaultBalance < _amount) _amount = _vaultBalance;
        if (maxBudget != 0 && maxBudget < _amount) _amount = maxBudget;
    }

    function _sync() internal virtual {
        uint256 _balance = _vaultBalance();
        uint256 _amount = _available(_balance);

        baseAmount = _amount;
        baseTimestamp = block.timestamp;
        lastSeenBalance = _balance;

        emit Synced(_amount, _balance);
    }

    function _writeCheckpoint() internal virtual {
        uint256 _balance = _vaultBalance();

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

    /// @dev The vault's current balance of the streamed token, or of native ETH
    function _vaultBalance() internal view virtual returns (uint256) {
        return address(vaultToken) == address(0) ? vault.balance : vaultToken.balanceOf(vault);
    }
}
