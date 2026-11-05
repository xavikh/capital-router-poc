// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INodeAction} from "../interfaces/INodeAction.sol";

/// @notice What a node spends and what it produces
/// @param beneficiary Who the flowing amount belongs to, once an action sets it (a Merkle claim).
///        Carried down every branch; it can't be changed once set.
struct Plan {
    IERC20 inToken;
    uint256 inAmount;
    IERC20 outToken;
    uint256 outAmount;
    address beneficiary;
}

/// @notice One node of a flow tree. Node 0 is the root and receives the budget.
/// @param action What the node does with its input. May be address(0) only on a branch (2+
///        children): the node then passes its input to its children unchanged.
/// @param children Indexes of the child nodes, each greater than this node's index. None makes
///        the node a leaf, whose action must output nothing.
/// @param weights One per child when there are 2+ children, summing to RATIO_BASE. Empty otherwise.
struct Node {
    INodeAction action;
    uint32[] children;
    uint32[] weights;
}
