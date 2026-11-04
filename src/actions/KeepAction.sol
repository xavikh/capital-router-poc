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
