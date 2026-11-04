// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IBudget} from "../../src/interfaces/IBudget.sol";
import {IStageAction} from "../../src/interfaces/IStageAction.sol";
import {Plan} from "../../src/lib/types.sol";

/// @notice Pulls `amountIn` and pays `amountIn * rate / 1e18` of `tokenOut` from its own balance
contract MockExchange {
    uint256 public immutable rate;

    constructor(uint256 _rate) {
        rate = _rate;
    }

    function swap(IERC20 _tokenIn, uint256 _amountIn, IERC20 _tokenOut, address _recipient) external {
        _tokenIn.transferFrom(msg.sender, address(this), _amountIn);
        _tokenOut.transfer(_recipient, _amountIn * rate / 1e18);
    }
}

/// @notice A chainable swap: converts whatever it receives at the exchange's fixed rate
contract MockSwapAction is IStageAction {
    MockExchange public immutable exchange;
    IERC20 public immutable tokenOut;
    address public immutable dao;

    constructor(MockExchange _exchange, IERC20 _tokenOut, address _dao) {
        (exchange, tokenOut, dao) = (_exchange, _tokenOut, _dao);
    }

    function budget() external pure returns (IBudget) {}

    function preconditions(address, Plan calldata) external pure {}

    function build(address, bytes calldata, Plan calldata _draft)
        external
        view
        returns (Plan memory _plan, Action[] memory _actions)
    {
        uint256 _out = _draft.inAmount * exchange.rate() / 1e18;
        _plan = Plan(_draft.inToken, _draft.inAmount, tokenOut, _out, _draft.beneficiary);

        _actions = new Action[](2);
        _actions[0] =
            Action(address(_draft.inToken), 0, abi.encodeCall(IERC20.approve, (address(exchange), _draft.inAmount)));
        _actions[1] = Action(
            address(exchange), 0, abi.encodeCall(MockExchange.swap, (_draft.inToken, _draft.inAmount, tokenOut, dao))
        );
    }

    function postconditions(address, Plan calldata) external pure returns (Action[] memory) {}
}
