// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {
    DaoAuthorizableUpgradeable
} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizableUpgradeable.sol";
import {ISplitter} from "../interfaces/ISplitter.sol";
import {Allocation} from "../lib/types.sol";
import {MANAGER_PERMISSION_ID, RATIO_BASE} from "../lib/constants.sol";

/// @title RatioSplitter
/// @notice Splits an amount by fixed ratios (fractions of RATIO_BASE)
/// @dev The rounding remainder goes to the largest share, so allocations sum to exactly `amount`.
contract RatioSplitter is ISplitter, Initializable, DaoAuthorizableUpgradeable {
    address[] internal _recipients;
    uint32[] internal _ratios;

    /// @notice Emitted when recipients or ratios change
    event RecipientsUpdated(address[] recipients, uint32[] ratios);

    error NoRecipients();
    error LengthMismatch();
    error ZeroRecipient();
    error InvalidRatios();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IDAO _dao, address[] calldata _newRecipients, uint32[] calldata _newRatios)
        external
        initializer
    {
        __DaoAuthorizableUpgradeable_init(_dao);
        _setRecipients(_newRecipients, _newRatios);
    }

    /// @inheritdoc ISplitter
    function split(uint256 _amount) external view virtual returns (Allocation[] memory _allocations) {
        uint256 _len = _recipients.length;
        _allocations = new Allocation[](_len);

        uint256 _assigned;
        uint256 _largest;
        for (uint256 i; i < _len; ++i) {
            uint256 _share = (_amount * _ratios[i]) / RATIO_BASE;
            _allocations[i] = Allocation({recipient: _recipients[i], amount: _share});
            _assigned += _share;
            if (_ratios[i] > _ratios[_largest]) _largest = i;
        }
        _allocations[_largest].amount += _amount - _assigned;
    }

    /// @notice Replaces recipients and ratios. Safe at any time: a sweep keeps no memory.
    function setRecipients(address[] calldata _newRecipients, uint32[] calldata _newRatios)
        external
        virtual
        auth(MANAGER_PERMISSION_ID)
    {
        _setRecipients(_newRecipients, _newRatios);
    }

    function recipients() external view returns (address[] memory, uint32[] memory) {
        return (_recipients, _ratios);
    }

    function _setRecipients(address[] calldata _newRecipients, uint32[] calldata _newRatios) internal virtual {
        if (_newRecipients.length == 0) revert NoRecipients();
        if (_newRecipients.length != _newRatios.length) revert LengthMismatch();

        uint256 _sum;
        for (uint256 i; i < _newRecipients.length; ++i) {
            if (_newRecipients[i] == address(0)) revert ZeroRecipient();
            _sum += _newRatios[i];
        }
        if (_sum != RATIO_BASE) revert InvalidRatios();

        _recipients = _newRecipients;
        _ratios = _newRatios;

        emit RecipientsUpdated(_newRecipients, _newRatios);
    }
}
