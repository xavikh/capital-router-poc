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
