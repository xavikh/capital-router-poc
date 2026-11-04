// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {ISplitter} from "../interfaces/ISplitter.sol";
import {Allocation, Plan} from "../lib/types.sol";

/// @title PayBeneficiary
/// @notice Sends a stage's whole output to the flow's beneficiary (e.g. the account a Merkle claim
///         paid). Stateless: one deployment serves every plugin.
contract PayBeneficiary is ISplitter {
    /// @notice Thrown when no action in the flow set a beneficiary
    error NoBeneficiary();

    /// @inheritdoc ISplitter
    function split(Plan calldata _plan) external pure returns (Allocation[] memory _allocations) {
        if (_plan.beneficiary == address(0)) revert NoBeneficiary();

        _allocations = new Allocation[](1);
        _allocations[0] = Allocation({recipient: _plan.beneficiary, amount: _plan.outAmount});
    }
}
