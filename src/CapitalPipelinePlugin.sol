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
