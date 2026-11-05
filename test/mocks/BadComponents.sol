// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IBudget} from "../../src/interfaces/IBudget.sol";
import {INodeAction} from "../../src/interfaces/INodeAction.sol";
import {Input, Movement} from "../../src/lib/types.sol";

/// @notice A node action that misbehaves in one chosen way. Otherwise it passes its input through.
contract BadAction is INodeAction {
    enum Mode {
        Pass, // behaves: passes its whole input on
        Block, // preconditions revert
        Skip, // takes nothing
        TakeHalf, // takes half its input
        Overspend, // claims 1 wei more than its input
        TargetDao, // returns an action whose target is the DAO
        TargetPlugin, // returns an action whose target is the plugin
        Redirect, // sets a different beneficiary than the one already set
        SwapInputToken, // declares a different input token
        Lie, // declares 10 B of output it never produces
        Drain // declares half its input as a leaf but transfers all of it away
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

    function preconditions(address, Input calldata) external view {
        if (mode == Mode.Block) revert Blocked();
    }

    function build(address, bytes calldata, Input calldata _input)
        external
        view
        returns (Movement memory _movement, Action[] memory _actions)
    {
        if (mode == Mode.Skip) return (_movement, _actions);

        _movement = Movement(_input.token, _input.amount, _input.token, _input.amount, _input.beneficiary);
        if (mode == Mode.TakeHalf) (_movement.inAmount, _movement.outAmount) = (_input.amount / 2, _input.amount / 2);
        if (mode == Mode.Overspend) _movement.inAmount += 1;
        if (mode == Mode.Redirect) _movement.beneficiary = THIEF;
        if (mode == Mode.SwapInputToken) _movement.inToken = IERC20(THIEF);
        if (mode == Mode.Lie) (_movement.outToken, _movement.outAmount) = (tokenB, 10 ether);
        if (mode == Mode.TargetDao || mode == Mode.TargetPlugin) {
            _actions = new Action[](1);
            _actions[0] = Action({to: mode == Mode.TargetDao ? dao : msg.sender, value: 0, data: ""});
        }
        if (mode == Mode.Drain) {
            (_movement.inAmount, _movement.outAmount) = (_input.amount / 2, 0);
            _actions = new Action[](1);
            _actions[0] = Action({
                to: address(_input.token), value: 0, data: abi.encodeCall(IERC20.transfer, (THIEF, _input.amount))
            });
        }
    }

    function postconditions(address, Movement calldata) external pure returns (Action[] memory) {}
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
