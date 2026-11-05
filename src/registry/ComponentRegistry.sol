// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {DaoAuthorizable} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizable.sol";

/// @title ComponentRegistry
/// @notice Names the component implementations that recipes can clone. Entries are write-once,
///         so an id always means the same code and a recipe can't change under a vote.
/// @dev Maintained through a managing DAO's permissions (`REGISTER_PERMISSION_ID`)
contract ComponentRegistry is DaoAuthorizable {
    bytes32 public constant REGISTER_PERMISSION_ID = keccak256("REGISTER_PERMISSION");

    struct Registration {
        bytes32 id;
        address implementation;
        bytes metadata;
    }

    struct Entry {
        address implementation;
        bytes metadata;
    }

    /// @notice Registered components by id, e.g. "OpenFillAction@1"
    mapping(bytes32 id => Entry) public entries;

    event ComponentRegistered(bytes32 indexed id, address implementation, bytes metadata);

    error AlreadyRegistered(bytes32 id);
    error NotAContract(address implementation);
    error UnknownComponent(bytes32 id);

    /// @param _initial Registered at deployment, so the first set needs no proposal
    constructor(IDAO _managingDao, Registration[] memory _initial) DaoAuthorizable(_managingDao) {
        for (uint256 i; i < _initial.length; ++i) {
            _register(_initial[i]);
        }
    }

    function register(Registration calldata _registration) external auth(REGISTER_PERMISSION_ID) {
        _register(_registration);
    }

    /// @notice The implementation registered as `_id`; reverts if there is none
    function implementation(bytes32 _id) external view returns (address _implementation) {
        _implementation = entries[_id].implementation;
        if (_implementation == address(0)) revert UnknownComponent(_id);
    }

    function _register(Registration memory _registration) internal {
        if (entries[_registration.id].implementation != address(0)) revert AlreadyRegistered(_registration.id);
        if (_registration.implementation.code.length == 0) revert NotAContract(_registration.implementation);

        entries[_registration.id] = Entry(_registration.implementation, _registration.metadata);
        emit ComponentRegistered(_registration.id, _registration.implementation, _registration.metadata);
    }
}
