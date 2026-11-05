// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {INodeAction} from "../interfaces/INodeAction.sol";
import {LeafAction} from "./LeafAction.sol";
import {Input, Movement} from "../lib/types.sol";
import {tokenBalance, transferAction} from "../lib/tokens.sol";

/// @title TransferBase
/// @notice Leaf that sends its whole input to one recipient. Postcondition: the recipient's balance
///         rose by the amount, which catches tokens that return false instead of reverting.
/// @dev Native ETH works too. Fee-on-transfer and rebasing tokens fail the postcondition by design.
abstract contract TransferBase is LeafAction {
    /// @notice Thrown when a recipient holds less than it should after the transfer
    error ReceiptShortfall(IERC20 token, address recipient, uint256 expected, uint256 actual);

    /// @inheritdoc INodeAction
    function build(address, bytes calldata, Input calldata _input)
        external
        view
        virtual
        returns (Movement memory _movement, Action[] memory _actions)
    {
        _movement = _consume(_input);
        _actions = new Action[](1);
        _actions[0] = transferAction(_input.token, _recipient(_input.beneficiary), _input.amount);
    }

    /// @inheritdoc INodeAction
    function postconditions(address, Movement calldata _movement)
        external
        view
        virtual
        override
        returns (Action[] memory _checks)
    {
        address _to = _recipient(_movement.beneficiary);
        uint256 _minBalance = tokenBalance(_movement.inToken, _to) + _movement.inAmount;

        _checks = new Action[](1);
        _checks[0] = Action({
            to: address(this),
            value: 0,
            data: abi.encodeCall(this.assertReceived, (_movement.inToken, _to, _minBalance))
        });
    }

    /// @notice Reverts unless `_account` holds at least `_minBalance` of `_token`
    /// @dev Executed by the DAO right after the transfer. View, so harmless to call from anywhere.
    function assertReceived(IERC20 _token, address _account, uint256 _minBalance) external view {
        uint256 _balance = tokenBalance(_token, _account);
        if (_balance < _minBalance) revert ReceiptShortfall(_token, _account, _minBalance, _balance);
    }

    /// @param _beneficiary The flow's beneficiary, address(0) if none was set
    function _recipient(address _beneficiary) internal view virtual returns (address);
}
