// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Allocation} from "../lib/types.sol";

/// @title ISplitter
/// @notice Divides an amount among recipients. Used by `SplitTransferAction` to pay dynamic lists.
interface ISplitter {
    /// @notice Allocations of `amount`, adding up to at most `amount`
    function split(uint256 amount) external view returns (Allocation[] memory);
}
