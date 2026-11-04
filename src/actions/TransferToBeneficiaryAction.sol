// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {TransferBase} from "./TransferBase.sol";
import {Plan} from "../lib/types.sol";

/// @title TransferToBeneficiaryAction
/// @notice Leaf that sends its whole input to the flow's beneficiary (set by a claim at the root).
///         Stateless: one deployment serves every plugin.
contract TransferToBeneficiaryAction is TransferBase {
    /// @notice Thrown when no action in the flow set a beneficiary
    error NoBeneficiary();

    function _recipient(Plan calldata _plan) internal pure override returns (address) {
        if (_plan.beneficiary == address(0)) revert NoBeneficiary();
        return _plan.beneficiary;
    }
}
