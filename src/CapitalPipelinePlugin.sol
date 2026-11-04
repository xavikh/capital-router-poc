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
///      the budget, allocations never exceed the output, and no action targets the DAO itself.
contract CapitalPipelinePlugin is PluginCloneable {
    Step[] internal _steps;

    /// @notice When true, `trigger` reverts
    bool public paused;

    /// @dev Makes every execution ID unique
    uint256 internal _nonce;

    /// @dev Reentrancy lock. Transient, so it needs no initialization on clones.
    bool internal transient _entered;

    event StepsUpdated(Step[] steps);
    event PausedSet(bool paused);
    event StepExecuted(uint256 indexed stepIndex, address indexed caller, bytes32 executionId, Plan plan);

    error NoSteps();
    error NoBudget(uint256 stepIndex);
    error BudgetMismatch(uint256 stepIndex);
    error Paused();
    error Reentrant();
    error DataLengthMismatch(uint256 expected, uint256 actual);
    error InAmountExceedsBudget(uint256 stepIndex, uint256 inAmount, uint256 available);
    error AllocationExceedsOutput(uint256 stepIndex, uint256 allocated, uint256 outAmount);
    error InvalidOutToken(uint256 stepIndex);
    error ActionTargetsDao(uint256 stepIndex, uint256 actionIndex);

    function initialize(IDAO _dao, Step[] calldata _newSteps) external initializer {
        __PluginCloneable_init(_dao);
        _setSteps(_newSteps);
    }

    /// @notice Runs every step in order
    /// @param _data Empty, or one entry per step (passed to that step's action)
    function trigger(bytes[] calldata _data) external auth(TRIGGER_PERMISSION_ID) {
        if (_entered) revert Reentrant();
        _entered = true;
        if (paused) revert Paused();

        uint256 _len = _steps.length;
        if (_data.length != 0 && _data.length != _len) revert DataLengthMismatch(_len, _data.length);

        uint256 _callNonce = _nonce++;
        for (uint256 i; i < _len; ++i) {
            _runStep(i, _data.length == 0 ? msg.data[0:0] : _data[i], _callNonce);
        }
        _entered = false;
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
        _rejectDaoTargets(_index, _actions);

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

    function _rejectDaoTargets(uint256 _index, Action[] memory _actions) internal view {
        address _dao = address(dao());
        for (uint256 i; i < _actions.length; ++i) {
            if (_actions[i].to == _dao) revert ActionTargetsDao(_index, i);
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
