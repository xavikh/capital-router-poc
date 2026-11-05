// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IBudget} from "./IBudget.sol";
import {Input, Movement} from "../lib/types.sol";

/// @title INodeAction
/// @notice What a node of a flow tree does with its input. The plugin calls all three hooks, in
///         order, on every node that has an action, so an action's safety checks can't be left out.
/// @dev Actions are clones initialized for one DAO and expose it as `dao()`
///      (`DaoAuthorizableUpgradeable`). The plugin rejects actions bound to another DAO or to none.
interface INodeAction {
    /// @notice The budget this action is bound to, or address(0) if it works with any input.
    ///         A bound action can only be the root of a flow on that budget.
    function budget() external view returns (IBudget);

    /// @notice Reverts if the action must not run on `input`
    function preconditions(address caller, Input calldata input) external view;

    /// @notice What the node spends from `input` (`inAmount`: the root may take less than its input,
    ///         every other node all of it), what it produces (`outToken`/`outAmount`, zero for a leaf)
    ///         and optionally a `beneficiary`, plus the actions that do the work.
    /// @dev `outAmount` must be known here: it is divided among the children before they run
    function build(address caller, bytes calldata data, Input calldata input)
        external
        view
        returns (Movement memory movement, Action[] memory actions);

    /// @notice The checks that make the work safe, executed by the DAO right after it
    function postconditions(address caller, Movement calldata movement) external view returns (Action[] memory);
}
