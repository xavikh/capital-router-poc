// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {
    DaoAuthorizableUpgradeable
} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizableUpgradeable.sol";
import {IBudget} from "../interfaces/IBudget.sol";
import {Movement} from "../lib/types.sol";
import {tokenBalance, isToken} from "../lib/tokens.sol";

/// @title BalanceBudget
/// @notice The DAO's whole balance of a token, with nothing to commit. Used where something else
///         decides the amount, such as a Merkle claim, and the budget only caps it at what the DAO holds.
contract BalanceBudget is IBudget, Initializable, DaoAuthorizableUpgradeable {
    /// @inheritdoc IBudget
    IERC20 public token;

    /// @notice Thrown when the token is neither native ETH (`NATIVE`) nor a contract
    error InvalidToken();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IDAO _dao, IERC20 _token) external initializer {
        if (!isToken(_token)) revert InvalidToken();

        __DaoAuthorizableUpgradeable_init(_dao);
        token = _token;
    }

    /// @inheritdoc IBudget
    function available() external view returns (uint256) {
        return tokenBalance(token, address(dao()));
    }

    /// @inheritdoc IBudget
    function commitActions(Movement calldata) external pure returns (Action[] memory) {}
}
