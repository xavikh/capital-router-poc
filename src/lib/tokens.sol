// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";

/// @dev Native ETH is `IERC20(address(0))` everywhere in the pipeline
IERC20 constant NATIVE = IERC20(address(0));

/// @notice `_account`'s balance of `_token`, or of native ETH
function tokenBalance(IERC20 _token, address _account) view returns (uint256) {
    return _token == NATIVE ? _account.balance : _token.balanceOf(_account);
}

/// @notice A DAO action that sends `_amount` of `_token` (or native ETH) to `_to`
function transferAction(IERC20 _token, address _to, uint256 _amount) pure returns (Action memory) {
    if (_token == NATIVE) return Action({to: _to, value: _amount, data: ""});
    return Action({to: address(_token), value: 0, data: abi.encodeCall(IERC20.transfer, (_to, _amount))});
}

/// @notice True for native ETH or a contract; rejects typos and EOAs
function isToken(IERC20 _token) view returns (bool) {
    return _token == NATIVE || address(_token).code.length != 0;
}
