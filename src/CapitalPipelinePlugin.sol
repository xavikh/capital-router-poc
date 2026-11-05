// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {IExecutor, Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {PluginCloneable} from "@aragon/osx-commons-contracts/src/plugin/PluginCloneable.sol";
import {
    DaoAuthorizableUpgradeable
} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizableUpgradeable.sol";
import {IBudget} from "./interfaces/IBudget.sol";
import {INodeAction} from "./interfaces/INodeAction.sol";
import {Input, Movement, Node} from "./lib/types.sol";
import {
    TRIGGER_PERMISSION_ID,
    CONFIGURE_PERMISSION_ID,
    MANAGER_PERMISSION_ID,
    RATIO_BASE,
    MAX_NODES
} from "./lib/constants.sol";
import {tokenBalance, isToken} from "./lib/tokens.sol";

/// @title CapitalPipelinePlugin
/// @notice Runs one flow: a budget feeding a tree of actions. The budget is read once; the root
///         node takes up to what it allows; every node passes its output to its children (split by
///         fixed weights when there are several); leaves consume what they receive (transfer, burn,
///         keep). The budget commits once, after the whole tree ran.
/// @dev Every node must succeed: the root takes a non-zero amount, every other node takes exactly
///      its input, and leaves output nothing. Anything else reverts the whole trigger.
///      Each node with an action is built (view) right after its parent ran and executes in its
///      own `dao.execute`, followed by balance checks: the DAO spent no more than the node's input
///      and received at least its declared output. Recipient checks are the actions' own postconditions.
contract CapitalPipelinePlugin is PluginCloneable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    /// @notice What the flow may spend; read at the start, committed at the end
    IBudget public budget;

    Node[] internal _nodes;

    /// @dev Makes every execution ID unique
    uint256 internal _nonce;

    event FlowUpdated(IBudget budget, Node[] nodes);
    event NodeExecuted(uint256 indexed nodeIndex, address indexed caller, bytes32 executionId, Movement movement);
    event BudgetCommitted(bytes32 executionId);

    // Configuration errors
    error NoBudget();
    error ForeignComponent(address component);
    error InvalidNodeCount(uint256 count);
    error MissingAction(uint256 nodeIndex);
    error InvalidChild(uint256 nodeIndex, uint256 childIndex);
    error UnreachableNode(uint256 nodeIndex);
    error InvalidWeights(uint256 nodeIndex);
    error BudgetMismatch(uint256 nodeIndex);

    // Trigger errors
    error DataLengthMismatch(uint256 expected, uint256 actual);
    error EmptyInput(uint256 nodeIndex);
    error InputTokenMismatch(uint256 nodeIndex);
    error InAmountExceedsInput(uint256 nodeIndex, uint256 inAmount, uint256 input);
    error NodeIncomplete(uint256 nodeIndex, uint256 inAmount, uint256 input);
    error LeafLeftOutput(uint256 nodeIndex, uint256 outAmount);
    error InvalidOutToken(uint256 nodeIndex);
    error BeneficiaryChanged(uint256 nodeIndex);
    error ActionTargetsDao(uint256 nodeIndex, uint256 actionIndex);
    error ActionTargetsPlugin(uint256 nodeIndex, uint256 actionIndex);
    error UnexpectedBalance(uint256 nodeIndex, address token, uint256 expected, uint256 actual);

    function initialize(IDAO _dao, IBudget _budget, Node[] calldata _newNodes) external initializer {
        __PluginCloneable_init(_dao);
        __Pausable_init();
        __ReentrancyGuard_init();
        _setFlow(_budget, _newNodes);
    }

    /// @notice Runs the flow
    /// @param _data Empty, or one entry per node (passed to that node's action)
    function trigger(bytes[] calldata _data) external nonReentrant whenNotPaused auth(TRIGGER_PERMISSION_ID) {
        uint256 _len = _nodes.length;
        if (_data.length != 0 && _data.length != _len) revert DataLengthMismatch(_len, _data.length);

        uint256 _callNonce = _nonce++;
        _runNode(0, Input(budget.token(), budget.available(), address(0)), _data, _callNonce);
        _commitBudget(_callNonce);
    }

    /// @notice Replaces the flow. DAO only: an action can return arbitrary DAO actions.
    function setFlow(IBudget _budget, Node[] calldata _newNodes) external nonReentrant auth(CONFIGURE_PERMISSION_ID) {
        _setFlow(_budget, _newNodes);
    }

    /// @notice Stops the flow until `unpause`
    function pause() external auth(MANAGER_PERMISSION_ID) {
        _pause();
    }

    /// @notice Resumes the flow
    function unpause() external auth(MANAGER_PERMISSION_ID) {
        _unpause();
    }

    function nodes() external view returns (Node[] memory) {
        return _nodes;
    }

    // Running the tree

    /// @dev Runs node `_index` on `_input`, then its children, depth first
    function _runNode(uint256 _index, Input memory _input, bytes[] calldata _data, uint256 _callNonce) internal {
        if (_input.amount == 0) revert EmptyInput(_index);

        Node storage _node = _nodes[_index];
        Movement memory _movement;
        if (address(_node.action) == address(0)) {
            // A branch without an action passes its input on
            _movement = Movement(_input.token, _input.amount, _input.token, _input.amount, _input.beneficiary);
        } else {
            bytes calldata _nodeData = _data.length == 0 ? msg.data[0:0] : _data[_index];
            _movement = _runAction(_index, _node.action, _input, _nodeData, _node.children.length == 0, _callNonce);
        }

        _runChildren(_node, _movement, _data, _callNonce);
    }

    function _runChildren(Node storage _node, Movement memory _movement, bytes[] calldata _data, uint256 _callNonce)
        internal
    {
        uint256 _count = _node.children.length;
        if (_count == 0) return;
        if (_count == 1) {
            _runNode(_node.children[0], _childInput(_movement, _movement.outAmount), _data, _callNonce);
            return;
        }

        uint256[] memory _amounts = _weighted(_movement.outAmount, _node.weights);
        for (uint256 k; k < _count; ++k) {
            _runNode(_node.children[k], _childInput(_movement, _amounts[k]), _data, _callNonce);
        }
    }

    function _runAction(
        uint256 _index,
        INodeAction _action,
        Input memory _input,
        bytes calldata _data,
        bool _leaf,
        uint256 _callNonce
    ) internal returns (Movement memory _movement) {
        Action[] memory _actions;
        (_movement, _actions) = _buildAction(_index, _action, _input, _data, _leaf);

        (uint256 _inBefore, uint256 _outBefore) = _snapshot(_movement);
        bytes32 _executionId = keccak256(abi.encode(address(this), _callNonce, _index));
        _execute(_index, _actions, _executionId);
        _verify(_index, _movement, _inBefore, _outBefore);

        emit NodeExecuted(_index, msg.sender, _executionId, _movement);
    }

    /// @dev Calls the action's hooks in order and checks its movement against the node's input
    function _buildAction(uint256 _index, INodeAction _action, Input memory _input, bytes calldata _data, bool _leaf)
        internal
        view
        returns (Movement memory _movement, Action[] memory _actions)
    {
        _action.preconditions(msg.sender, _input);
        Action[] memory _work;
        (_movement, _work) = _action.build(msg.sender, _data, _input);

        if (_movement.inAmount > _input.amount) {
            revert InAmountExceedsInput(_index, _movement.inAmount, _input.amount);
        }
        // The root may take less than the budget allows (but something); every other node takes all of it
        if (_movement.inAmount == 0 || (_index != 0 && _movement.inAmount != _input.amount)) {
            revert NodeIncomplete(_index, _movement.inAmount, _input.amount);
        }
        if (_movement.inToken != _input.token) revert InputTokenMismatch(_index);
        if (_leaf && _movement.outAmount != 0) revert LeafLeftOutput(_index, _movement.outAmount);
        if (_movement.outAmount != 0 && !isToken(_movement.outToken)) revert InvalidOutToken(_index);
        _movement.beneficiary = _keepBeneficiary(_index, _input.beneficiary, _movement.beneficiary);

        _actions = _concat(_work, _action.postconditions(msg.sender, _movement));
    }

    function _execute(uint256 _index, Action[] memory _actions, bytes32 _executionId) internal {
        if (_actions.length == 0) return;

        address _dao = address(dao());
        for (uint256 i; i < _actions.length; ++i) {
            if (_actions[i].to == _dao) revert ActionTargetsDao(_index, i);
            if (_actions[i].to == address(this)) revert ActionTargetsPlugin(_index, i);
        }
        IExecutor(_dao).execute(_executionId, _actions, 0);
    }

    /// @dev After the whole tree ran, so a stream checkpoint sees the final balance
    function _commitBudget(uint256 _callNonce) internal {
        Action[] memory _actions = budget.commitActions();
        if (_actions.length == 0) return;

        bytes32 _executionId = keccak256(abi.encode(address(this), _callNonce, type(uint256).max));
        _execute(_nodes.length, _actions, _executionId);
        emit BudgetCommitted(_executionId);
    }

    // Balance checks

    function _snapshot(Movement memory _movement) internal view returns (uint256 _inBefore, uint256 _outBefore) {
        address _dao = address(dao());
        _inBefore = tokenBalance(_movement.inToken, _dao);
        if (_movement.outToken != _movement.inToken && _movement.outAmount != 0) {
            _outBefore = tokenBalance(_movement.outToken, _dao);
        }
    }

    /// @dev The DAO spent at most `inAmount` and received at least `outAmount`
    function _verify(uint256 _index, Movement memory _movement, uint256 _inBefore, uint256 _outBefore) internal view {
        if (_movement.outToken == _movement.inToken) {
            _checkDao(_index, _movement.inToken, _inBefore + _movement.outAmount, _movement.inAmount);
        } else {
            _checkDao(_index, _movement.inToken, _inBefore, _movement.inAmount);
            if (_movement.outAmount != 0) _checkDao(_index, _movement.outToken, _outBefore + _movement.outAmount, 0);
        }
    }

    /// @dev Reverts unless `balance + spent >= target`
    function _checkDao(uint256 _index, IERC20 _token, uint256 _target, uint256 _spent) internal view {
        uint256 _actual = tokenBalance(_token, address(dao()));
        if (_actual + _spent < _target) {
            revert UnexpectedBalance(_index, address(_token), _target > _spent ? _target - _spent : 0, _actual);
        }
    }

    // Helpers

    function _childInput(Movement memory _movement, uint256 _amount) internal pure returns (Input memory) {
        return Input(_movement.outToken, _amount, _movement.beneficiary);
    }

    /// @dev Splits `_amount` by `_weights`; the rounding remainder goes to the largest weight
    function _weighted(uint256 _amount, uint32[] storage _weights) internal view returns (uint256[] memory _amounts) {
        uint256 _count = _weights.length;
        _amounts = new uint256[](_count);

        uint256 _assigned;
        uint256 _largest;
        for (uint256 k; k < _count; ++k) {
            _amounts[k] = (_amount * _weights[k]) / RATIO_BASE;
            _assigned += _amounts[k];
            if (_weights[k] > _weights[_largest]) _largest = k;
        }
        _amounts[_largest] += _amount - _assigned;
    }

    /// @dev Once set, the beneficiary carries on; an action may leave it unset but not change it
    function _keepBeneficiary(uint256 _index, address _current, address _proposed) internal pure returns (address) {
        if (_current == address(0) || _proposed == _current) return _proposed;
        if (_proposed == address(0)) return _current;
        revert BeneficiaryChanged(_index);
    }

    function _concat(Action[] memory _a, Action[] memory _b) internal pure returns (Action[] memory _out) {
        _out = new Action[](_a.length + _b.length);
        for (uint256 i; i < _a.length; ++i) {
            _out[i] = _a[i];
        }
        for (uint256 i; i < _b.length; ++i) {
            _out[_a.length + i] = _b[i];
        }
    }

    // Configuration

    function _setFlow(IBudget _budget, Node[] calldata _newNodes) internal {
        if (address(_budget) == address(0)) revert NoBudget();
        _checkOwnDao(address(_budget));
        uint256 _len = _newNodes.length;
        if (_len == 0 || _len > MAX_NODES) revert InvalidNodeCount(_len);

        delete _nodes;
        bool[] memory _hasParent = new bool[](_len);
        for (uint256 i; i < _len; ++i) {
            _checkNode(i, _newNodes[i], _budget, _hasParent);

            Node storage _stored = _nodes.push();
            _stored.action = _newNodes[i].action;
            _stored.children = _newNodes[i].children;
            _stored.weights = _newNodes[i].weights;
        }
        for (uint256 i = 1; i < _len; ++i) {
            if (!_hasParent[i]) revert UnreachableNode(i);
        }
        budget = _budget;

        emit FlowUpdated(_budget, _newNodes);
    }

    /// @dev Children come after their parent and have exactly one parent, so the nodes form a tree
    ///      rooted at node 0 with no cycles. Weights are only for branches and sum to RATIO_BASE.
    function _checkNode(uint256 _index, Node calldata _node, IBudget _budget, bool[] memory _hasParent) internal view {
        uint256 _count = _node.children.length;
        if (address(_node.action) == address(0)) {
            if (_count < 2) revert MissingAction(_index);
        } else {
            _checkOwnDao(address(_node.action));
            IBudget _bound = _node.action.budget();
            if (address(_bound) != address(0) && (_index != 0 || _bound != _budget)) revert BudgetMismatch(_index);
        }

        for (uint256 k; k < _count; ++k) {
            uint256 _child = _node.children[k];
            if (_child <= _index || _child >= _hasParent.length || _hasParent[_child]) {
                revert InvalidChild(_index, _child);
            }
            _hasParent[_child] = true;
        }

        if (_count < 2) {
            if (_node.weights.length != 0) revert InvalidWeights(_index);
            return;
        }
        if (_node.weights.length != _count) revert InvalidWeights(_index);
        uint256 _sum;
        for (uint256 k; k < _count; ++k) {
            if (_node.weights[k] == 0) revert InvalidWeights(_index);
            _sum += _node.weights[k];
        }
        if (_sum != RATIO_BASE) revert InvalidWeights(_index);
    }

    /// @dev Every component is a clone initialized for this plugin's DAO. Implementations (bound to
    ///      no DAO) and other DAOs' components are rejected.
    function _checkOwnDao(address _component) internal view {
        if (DaoAuthorizableUpgradeable(_component).dao() != dao()) revert ForeignComponent(_component);
    }
}
