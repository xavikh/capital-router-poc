// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Allocation} from "../lib/types.sol";

/// @title ISplitter
/// @notice Divides a step's output among recipients
interface ISplitter {
    /// @notice Allocations of `amount`. The plugin rejects allocations that add up to more.
    function split(uint256 amount) external view returns (Allocation[] memory);
}
