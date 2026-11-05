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
