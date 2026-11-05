// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {TransferBase} from "./TransferBase.sol";
import {Plan} from "../lib/types.sol";

/// @title TransferToBeneficiaryAction
/// @notice Leaf that sends its whole input to the flow's beneficiary (set by a claim at the root)
contract TransferToBeneficiaryAction is TransferBase {
    /// @notice Thrown when no action in the flow set a beneficiary
    error NoBeneficiary();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IDAO _dao) external initializer {
        __DaoAuthorizableUpgradeable_init(_dao);
    }

    function _recipient(Plan calldata _plan) internal pure override returns (address) {
        if (_plan.beneficiary == address(0)) revert NoBeneficiary();
        return _plan.beneficiary;
    }
}
