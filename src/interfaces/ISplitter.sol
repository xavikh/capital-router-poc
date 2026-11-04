// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Allocation, Plan} from "../lib/types.sol";

/// @title ISplitter
/// @notice Divides a stage's output among recipients
interface ISplitter {
    /// @notice Allocations of `plan.outAmount`. The plugin rejects allocations that add up to more.
    ///         Whatever isn't transferred out (including allocations to the DAO) passes to the next stage.
    function split(Plan calldata plan) external view returns (Allocation[] memory);
}
