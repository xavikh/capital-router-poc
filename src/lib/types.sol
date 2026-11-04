// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStageAction} from "../interfaces/IStageAction.sol";
import {ISplitter} from "../interfaces/ISplitter.sol";

/// @notice What a stage spends and what it produces. Passed from component to component and,
///         as the leftover, from stage to stage.
/// @param beneficiary Who the flowing amount belongs to, once an action sets it (e.g. a Merkle
///        claim). Carried to later stages; it can't be changed once set.
struct Plan {
    IERC20 inToken;
    uint256 inAmount;
    IERC20 outToken;
    uint256 outAmount;
    address beneficiary;
}

/// @notice An amount of a stage's output for one recipient. An allocation to the DAO itself is
///         kept for the next stage instead of transferred.
struct Allocation {
    address recipient;
    uint256 amount;
}

/// @notice One stage of a flow. Either may be address(0), not both.
struct Stage {
    IStageAction action;
    ISplitter splitter;
}
