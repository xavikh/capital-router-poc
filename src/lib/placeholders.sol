// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

/// @dev Placeholder addresses for contracts a recipe can't know yet: the DAO, the plugin and the
///      recipe's own components. The setup replaces them wherever they appear (init data, budget,
///      node actions, grants). The upper bits are a fixed tag, the lower 16 bits say what it
///      stands for.
uint160 constant PLACEHOLDER_TAG = uint160(uint256(keccak256("capital-pipeline.placeholder"))) & ~uint160(0xFFFF);
uint256 constant DAO_INDEX = 0xFFFF;
uint256 constant PLUGIN_INDEX = 0xFFFE;

address constant DAO_REF = address(PLACEHOLDER_TAG | uint160(DAO_INDEX));
address constant PLUGIN_REF = address(PLACEHOLDER_TAG | uint160(PLUGIN_INDEX));

/// @notice Placeholder for the clone of the recipe's component `_index`
function ref(uint256 _index) pure returns (address) {
    return address(PLACEHOLDER_TAG | uint160(_index));
}

/// @notice Whether a 32-byte word is a placeholder
function isPlaceholder(uint256 _word) pure returns (bool) {
    return _word >> 16 == uint256(PLACEHOLDER_TAG) >> 16;
}
