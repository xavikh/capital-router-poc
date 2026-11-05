// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {
    DaoAuthorizableUpgradeable
} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizableUpgradeable.sol";
import {INodeAction} from "../interfaces/INodeAction.sol";
import {IBudget} from "../interfaces/IBudget.sol";
import {Input, Movement} from "../lib/types.sol";
import {NATIVE} from "../lib/tokens.sol";

/// @title BurnAction
/// @notice Leaf that burns its whole input with `ERC20Burnable.burn`, lowering the total supply
/// @dev The token must implement `burn(uint256)`; otherwise the DAO action reverts. The plugin's
///      balance check confirms the DAO spent no more than the input.
contract BurnAction is INodeAction, DaoAuthorizableUpgradeable {
    /// @notice Thrown when the input is native ETH, which can't be burned
    error CannotBurnNative();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IDAO _dao) external initializer {
        __DaoAuthorizableUpgradeable_init(_dao);
    }

    /// @inheritdoc INodeAction
    function budget() external pure returns (IBudget) {}

    /// @inheritdoc INodeAction
    function preconditions(address, Input calldata _input) external pure {
        if (_input.token == NATIVE) revert CannotBurnNative();
    }

    /// @inheritdoc INodeAction
    function build(address, bytes calldata, Input calldata _input)
        external
        pure
        returns (Movement memory _movement, Action[] memory _actions)
    {
        _movement = Movement(_input.token, _input.amount, _input.token, 0, _input.beneficiary);
        _actions = new Action[](1);
        _actions[0] =
            Action({to: address(_input.token), value: 0, data: abi.encodeCall(ERC20Burnable.burn, (_input.amount))});
    }

    /// @inheritdoc INodeAction
    function postconditions(address, Movement calldata) external pure returns (Action[] memory) {}
}
