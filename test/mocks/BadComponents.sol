// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IBudget} from "../../src/interfaces/IBudget.sol";
import {IStepAction} from "../../src/interfaces/IStepAction.sol";
import {ISplitter} from "../../src/interfaces/ISplitter.sol";
import {Plan, Allocation} from "../../src/lib/types.sol";

/// @notice An action that misbehaves in one of three ways
contract BadAction is IStepAction {
    enum Mode {
        Block, // preconditions revert
        TargetDao, // build returns an action whose target is the DAO
        Overspend // build claims 1 wei more than the budget allows
    }

    error Blocked();

    Mode public immutable mode;
    address public immutable dao;

    constructor(Mode _mode, address _dao) {
        mode = _mode;
        dao = _dao;
    }

    function budget() external pure returns (IBudget) {}

    function preconditions(address, Plan calldata) external view {
        if (mode == Mode.Block) revert Blocked();
    }

    function build(address, bytes calldata, Plan calldata _draft)
        external
        view
        returns (Plan memory _plan, Action[] memory _actions)
    {
        _plan = _draft;
        if (mode == Mode.Overspend) _plan.inAmount += 1;
        if (mode == Mode.TargetDao) {
            _actions = new Action[](1);
            _actions[0] = Action({to: dao, value: 0, data: ""});
        }
    }

    function postconditions(address, Plan calldata) external pure returns (Action[] memory) {}
}

/// @notice A splitter that allocates 1 wei more than it was given
contract OverAllocatingSplitter is ISplitter {
    function split(uint256 _amount) external pure returns (Allocation[] memory _allocations) {
        _allocations = new Allocation[](1);
        _allocations[0] = Allocation({recipient: address(0xBEEF), amount: _amount + 1});
    }
}
