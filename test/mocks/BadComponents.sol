// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IBudget} from "../../src/interfaces/IBudget.sol";
import {IStageAction} from "../../src/interfaces/IStageAction.sol";
import {ISplitter} from "../../src/interfaces/ISplitter.sol";
import {Plan, Allocation} from "../../src/lib/types.sol";

/// @notice An action that misbehaves in one chosen way
contract BadAction is IStageAction {
    enum Mode {
        Block, // preconditions revert
        Skip, // returns inAmount 0
        TargetDao, // returns an action whose target is the DAO
        Overspend, // claims 1 wei more than its input
        Redirect, // sets a different beneficiary than the one already set
        SwapInputToken, // declares a different input token
        Lie, // declares 10 B of output it never produces
        Drain // declares half the input but transfers all of it away
    }

    address internal constant THIEF = address(0xBEEF);

    error Blocked();

    Mode public immutable mode;
    address public immutable dao;
    IERC20 public immutable tokenB;

    constructor(Mode _mode, address _dao, IERC20 _tokenB) {
        (mode, dao, tokenB) = (_mode, _dao, _tokenB);
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
        if (mode == Mode.Skip) return (_plan, _actions);

        _plan = _draft;
        if (mode == Mode.Overspend) _plan.inAmount += 1;
        if (mode == Mode.Redirect) _plan.beneficiary = THIEF;
        if (mode == Mode.SwapInputToken) _plan.inToken = IERC20(THIEF);
        if (mode == Mode.Lie) (_plan.outToken, _plan.outAmount) = (tokenB, 10 ether);
        if (mode == Mode.TargetDao) {
            _actions = new Action[](1);
            _actions[0] = Action({to: dao, value: 0, data: ""});
        }
        if (mode == Mode.Drain) {
            (_plan.inAmount, _plan.outAmount) = (_draft.inAmount / 2, 0);
            _actions = new Action[](1);
            _actions[0] = Action({
                to: address(_draft.inToken), value: 0, data: abi.encodeCall(IERC20.transfer, (THIEF, _draft.inAmount))
            });
        }
    }

    function postconditions(address, Plan calldata) external pure returns (Action[] memory) {}
}

/// @notice A splitter that allocates 1 wei more than the output
contract OverAllocatingSplitter is ISplitter {
    function split(Plan calldata _plan) external pure returns (Allocation[] memory _allocations) {
        _allocations = new Allocation[](1);
        _allocations[0] = Allocation({recipient: address(0xBEEF), amount: _plan.outAmount + 1});
    }
}

/// @notice Lists the same recipient twice, splitting the output 50/50 between the two entries
contract DuplicateRecipientSplitter is ISplitter {
    address public immutable recipient;

    constructor(address _recipient) {
        recipient = _recipient;
    }

    function split(Plan calldata _plan) external view returns (Allocation[] memory _allocations) {
        _allocations = new Allocation[](2);
        _allocations[0] = Allocation({recipient: recipient, amount: _plan.outAmount / 2});
        _allocations[1] = Allocation({recipient: recipient, amount: _plan.outAmount - _plan.outAmount / 2});
    }
}

/// @notice USDT-family failure mode: after `successfulTransfers` transfers, `transfer` returns
///         false without moving anything
contract FalseReturnToken is ERC20 {
    uint256 public successfulTransfers;

    constructor(uint256 _successfulTransfers) ERC20("False", "FALSE") {
        successfulTransfers = _successfulTransfers;
    }

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }

    function transfer(address _to, uint256 _amount) public override returns (bool) {
        if (successfulTransfers == 0) return false;
        --successfulTransfers;
        return super.transfer(_to, _amount);
    }
}
