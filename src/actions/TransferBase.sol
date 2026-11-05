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
