// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBudget} from "../interfaces/IBudget.sol";
import {IStepAction} from "../interfaces/IStepAction.sol";
import {ISplitter} from "../interfaces/ISplitter.sol";

/// @notice What a step spends and what it produces. Passed from component to component.
struct Plan {
    IERC20 inToken;
    uint256 inAmount;
    IERC20 outToken;
    uint256 outAmount;
}

/// @notice An amount of the step's output for one recipient
struct Allocation {
    address recipient;
    uint256 amount;
}

/// @notice One step of the pipeline. `action` and `splitter` may be address(0).
struct Step {
    IBudget budget;
    IStepAction action;
    ISplitter splitter;
}
