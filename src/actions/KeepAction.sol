// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {INodeAction} from "../interfaces/INodeAction.sol";
import {Input, Movement} from "../lib/types.sol";
import {LeafAction} from "./LeafAction.sol";

/// @title KeepAction
/// @notice Leaf that leaves its whole input in the DAO, so keeping funds is an explicit choice
contract KeepAction is LeafAction {
    function initialize(IDAO _dao) external initializer {
        __DaoAuthorizableUpgradeable_init(_dao);
    }

    /// @inheritdoc INodeAction
    function build(address, bytes calldata, Input calldata _input)
        external
        pure
        returns (Movement memory, Action[] memory)
    {
        return (_consume(_input), new Action[](0)); // no actions: the input stays where it is
    }
}
