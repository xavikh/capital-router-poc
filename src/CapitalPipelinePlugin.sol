// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {IExecutor, Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {PluginCloneable} from "@aragon/osx-commons-contracts/src/plugin/PluginCloneable.sol";
import {IBudget} from "./interfaces/IBudget.sol";
import {ISplitter} from "./interfaces/ISplitter.sol";
import {Plan, Allocation, Stage} from "./lib/types.sol";
import {TRIGGER_PERMISSION_ID, CONFIGURE_PERMISSION_ID, MANAGER_PERMISSION_ID} from "./lib/constants.sol";

/// @title CapitalPipelinePlugin
/// @notice Runs one flow: the budget is read once, then each stage runs its action
///         (preconditions → build → postconditions) and its splitter, and passes what it didn't
///         transfer out to the next stage. The budget commits once, after the last stage.
/// @dev Each stage is planned (view) right before it executes in its own `dao.execute`, so it
///      always sees real balances. After every stage the plugin checks balances: each recipient
///      received its allocation, the DAO received the declared output, and the DAO spent no more
///      than the declared input. That makes each stage's leftover safe for the next stage to spend.
contract CapitalPipelinePlugin is PluginCloneable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    /// @dev Balances taken right before a stage executes
    struct Snapshot {
        uint256 inBalance;
        uint256 outBalance;
        uint256 transferred;
        uint256 recipientCount;
        address[] recipients;
        uint256[] expected;
    }

    /// @notice What the flow may spend; read at the start, committed at the end
    IBudget public budget;

    Stage[] internal _stages;

    /// @dev Makes every execution ID unique
    uint256 internal _nonce;

    event FlowUpdated(IBudget budget, Stage[] stages);
    event StageExecuted(uint256 indexed stageIndex, address indexed caller, bytes32 executionId, Plan plan);
    event BudgetCommitted(bytes32 executionId);

    error NoBudget();
    error NoStages();
    error EmptyStage(uint256 stageIndex);
    error BudgetMismatch(uint256 stageIndex);
    error DataLengthMismatch(uint256 expected, uint256 actual);
    error InputTokenMismatch(uint256 stageIndex);
    error InAmountExceedsInput(uint256 stageIndex, uint256 inAmount, uint256 input);
    error BeneficiaryChanged(uint256 stageIndex);
    error AllocationExceedsOutput(uint256 stageIndex, uint256 allocated, uint256 outAmount);
    error InvalidOutToken(uint256 stageIndex);
    error ActionTargetsDao(uint256 stageIndex, uint256 actionIndex);
    error UnexpectedBalance(uint256 stageIndex, address account, address token, uint256 expected, uint256 actual);

    function initialize(IDAO _dao, IBudget _budget, Stage[] calldata _newStages) external initializer {
        __PluginCloneable_init(_dao);
        __Pausable_init();
        __ReentrancyGuard_init();
        _setFlow(_budget, _newStages);
    }

    /// @notice Runs the flow
    /// @param _data Empty, or one entry per stage (passed to that stage's action)
    function trigger(bytes[] calldata _data) external nonReentrant whenNotPaused auth(TRIGGER_PERMISSION_ID) {
        uint256 _len = _stages.length;
        if (_data.length != 0 && _data.length != _len) revert DataLengthMismatch(_len, _data.length);

        uint256 _callNonce = _nonce++;
        IERC20 _token = budget.token();
        uint256 _available = budget.available();
        Plan memory _input = Plan(_token, _available, _token, _available, address(0));
        Plan memory _first;

        for (uint256 i; i < _len && _input.inAmount != 0; ++i) {
            Plan memory _plan;
            (_plan, _input) = _runStage(i, _input, _data.length == 0 ? msg.data[0:0] : _data[i], _callNonce);
            if (_plan.inAmount == 0) break; // this stage and the rest are skipped
            if (i == 0) _first = _plan;
        }

        // The budget is consumed once the first stage ran. A skipped first stage leaves it untouched.
        if (_first.inAmount != 0) _commitBudget(_first, _callNonce);
    }

    /// @notice Replaces the flow. DAO only: an action can return arbitrary DAO actions.
    function setFlow(IBudget _budget, Stage[] calldata _newStages) external auth(CONFIGURE_PERMISSION_ID) {
        _setFlow(_budget, _newStages);
    }

    /// @notice Stops the flow until `unpause`
    function pause() external auth(MANAGER_PERMISSION_ID) {
        _pause();
    }

    /// @notice Resumes the flow
    function unpause() external auth(MANAGER_PERMISSION_ID) {
        _unpause();
    }

    function stages() external view returns (Stage[] memory) {
        return _stages;
    }

    // Stage execution

    /// @return _plan What the stage did (`inAmount == 0` if it was skipped)
    /// @return _next The next stage's input: what this stage produced and didn't transfer out
    function _runStage(uint256 _index, Plan memory _draft, bytes calldata _data, uint256 _callNonce)
        internal
        returns (Plan memory _plan, Plan memory _next)
    {
        Action[] memory _actions;
        Allocation[] memory _transfers;
        (_plan, _actions, _transfers) = _planStage(_index, _stages[_index], _draft, _data);
        if (_plan.inAmount == 0) return (_plan, _next);

        Snapshot memory _before = _snapshot(_plan, _transfers);

        bytes32 _executionId = keccak256(abi.encode(address(this), _callNonce, _index));
        _execute(_index, _actions, _executionId);
        _verify(_index, _plan, _before);

        uint256 _leftover = _plan.outAmount - _before.transferred;
        _next = Plan(_plan.outToken, _leftover, _plan.outToken, _leftover, _plan.beneficiary);

        emit StageExecuted(_index, msg.sender, _executionId, _plan);
    }

    /// @dev Calls the stage's components in order and concatenates their actions
    function _planStage(uint256 _index, Stage memory _stage, Plan memory _draft, bytes calldata _data)
        internal
        view
        returns (Plan memory _plan, Action[] memory _actions, Allocation[] memory _transfers)
    {
        _plan = _draft;
        Action[] memory _work;
        Action[] memory _checks;

        if (address(_stage.action) != address(0)) {
            _stage.action.preconditions(msg.sender, _draft);
            (_plan, _work) = _stage.action.build(msg.sender, _data, _draft);
            if (_plan.inAmount == 0) return (_plan, _actions, _transfers);

            if (_plan.inToken != _draft.inToken) revert InputTokenMismatch(_index);
            _plan.beneficiary = _keepBeneficiary(_index, _draft.beneficiary, _plan.beneficiary);
            _checks = _stage.action.postconditions(msg.sender, _plan);
        }
        if (_plan.inAmount > _draft.inAmount) revert InAmountExceedsInput(_index, _plan.inAmount, _draft.inAmount);
        if (_plan.outAmount != 0 && address(_plan.outToken).code.length == 0) revert InvalidOutToken(_index);

        _transfers = _split(_index, _stage.splitter, _plan);
        _actions = _concat(_work, _checks, _transferActions(_plan.outToken, _transfers));
    }

    /// @dev Non-zero allocations to anyone but the DAO. Allocations to the DAO stay as leftover.
    function _split(uint256 _index, ISplitter _splitter, Plan memory _plan)
        internal
        view
        returns (Allocation[] memory _transfers)
    {
        if (address(_splitter) == address(0) || _plan.outAmount == 0) return _transfers;

        Allocation[] memory _allocations = _splitter.split(_plan);
        address _dao = address(dao());

        uint256 _total;
        uint256 _count;
        for (uint256 i; i < _allocations.length; ++i) {
            _total += _allocations[i].amount;
            if (_allocations[i].amount != 0 && _allocations[i].recipient != _dao) ++_count;
        }
        if (_total > _plan.outAmount) revert AllocationExceedsOutput(_index, _total, _plan.outAmount);

        _transfers = new Allocation[](_count);
        uint256 _j;
        for (uint256 i; i < _allocations.length; ++i) {
            if (_allocations[i].amount != 0 && _allocations[i].recipient != _dao) _transfers[_j++] = _allocations[i];
        }
    }

    function _execute(uint256 _index, Action[] memory _actions, bytes32 _executionId) internal {
        if (_actions.length == 0) return;

        address _dao = address(dao());
        for (uint256 i; i < _actions.length; ++i) {
            if (_actions[i].to == _dao) revert ActionTargetsDao(_index, i);
        }
        IExecutor(_dao).execute(_executionId, _actions, 0);
    }

    function _commitBudget(Plan memory _first, uint256 _callNonce) internal {
        Action[] memory _actions = budget.commitActions(_first);
        if (_actions.length == 0) return;

        bytes32 _executionId = keccak256(abi.encode(address(this), _callNonce, type(uint256).max));
        _execute(_stages.length, _actions, _executionId);
        emit BudgetCommitted(_executionId);
    }

    // Balance checks

    /// @dev Records the DAO's in/out balances and, per unique recipient, the balance it must reach
    function _snapshot(Plan memory _plan, Allocation[] memory _transfers) internal view returns (Snapshot memory _s) {
        address _dao = address(dao());
        _s.inBalance = _plan.inToken.balanceOf(_dao);
        if (_plan.outToken != _plan.inToken && _plan.outAmount != 0) _s.outBalance = _plan.outToken.balanceOf(_dao);

        _s.recipients = new address[](_transfers.length);
        _s.expected = new uint256[](_transfers.length);
        for (uint256 i; i < _transfers.length; ++i) {
            _s.transferred += _transfers[i].amount;

            uint256 k;
            while (k < _s.recipientCount && _s.recipients[k] != _transfers[i].recipient) ++k;
            if (k == _s.recipientCount) {
                _s.recipients[k] = _transfers[i].recipient;
                _s.expected[k] = _plan.outToken.balanceOf(_transfers[i].recipient);
                ++_s.recipientCount;
            }
            _s.expected[k] += _transfers[i].amount;
        }
    }

    function _verify(uint256 _index, Plan memory _plan, Snapshot memory _s) internal view {
        for (uint256 k; k < _s.recipientCount; ++k) {
            uint256 _actual = _plan.outToken.balanceOf(_s.recipients[k]);
            if (_actual < _s.expected[k]) {
                revert UnexpectedBalance(_index, _s.recipients[k], address(_plan.outToken), _s.expected[k], _actual);
            }
        }

        if (_plan.outToken == _plan.inToken) {
            // One token: it may drop by at most the input, and must gain the output, net of transfers
            _checkDao(_index, _plan.inToken, _s.inBalance + _plan.outAmount, _plan.inAmount + _s.transferred);
        } else {
            _checkDao(_index, _plan.inToken, _s.inBalance, _plan.inAmount);
            if (_plan.outAmount != 0) {
                _checkDao(_index, _plan.outToken, _s.outBalance + _plan.outAmount, _s.transferred);
            }
        }
    }

    /// @dev Reverts unless `balance + spent >= target`
    function _checkDao(uint256 _index, IERC20 _token, uint256 _target, uint256 _spent) internal view {
        address _dao = address(dao());
        uint256 _actual = _token.balanceOf(_dao);
        if (_actual + _spent < _target) {
            revert UnexpectedBalance(_index, _dao, address(_token), _target > _spent ? _target - _spent : 0, _actual);
        }
    }

    // Helpers

    /// @dev Once set, the beneficiary carries on; an action may leave it unset but not change it
    function _keepBeneficiary(uint256 _index, address _current, address _proposed) internal pure returns (address) {
        if (_current == address(0) || _proposed == _current) return _proposed;
        if (_proposed == address(0)) return _current;
        revert BeneficiaryChanged(_index);
    }

    function _transferActions(IERC20 _token, Allocation[] memory _transfers)
        internal
        pure
        returns (Action[] memory _actions)
    {
        _actions = new Action[](_transfers.length);
        for (uint256 i; i < _transfers.length; ++i) {
            _actions[i] = Action({
                to: address(_token),
                value: 0,
                data: abi.encodeCall(IERC20.transfer, (_transfers[i].recipient, _transfers[i].amount))
            });
        }
    }

    function _concat(Action[] memory _a, Action[] memory _b, Action[] memory _c)
        internal
        pure
        returns (Action[] memory _out)
    {
        _out = new Action[](_a.length + _b.length + _c.length);
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
    }

    function _setFlow(IBudget _budget, Stage[] calldata _newStages) internal {
        if (address(_budget) == address(0)) revert NoBudget();
        if (_newStages.length == 0) revert NoStages();

        delete _stages;
        for (uint256 i; i < _newStages.length; ++i) {
            Stage calldata _stage = _newStages[i];
            if (address(_stage.action) == address(0) && address(_stage.splitter) == address(0)) revert EmptyStage(i);
            if (address(_stage.action) != address(0)) {
                IBudget _bound = _stage.action.budget();
                if (address(_bound) != address(0) && (i != 0 || _bound != _budget)) revert BudgetMismatch(i);
            }
            _stages.push(_stage);
        }
        budget = _budget;

        emit FlowUpdated(_budget, _newStages);
    }
}
