// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {TransferBase} from "./TransferBase.sol";
import {Plan} from "../lib/types.sol";

/// @title TransferAction
/// @notice Leaf that sends its whole input to a fixed recipient
contract TransferAction is TransferBase, Initializable {
    /// @notice Who receives the node's input
    address public recipient;

    /// @notice Thrown when the recipient is address(0)
    error NoRecipient();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _to) external initializer {
        if (_to == address(0)) revert NoRecipient();
        recipient = _to;
    }

    function _recipient(Plan calldata) internal view override returns (address) {
        return recipient;
    }
}
