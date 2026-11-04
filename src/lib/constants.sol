// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

/// @dev Tunes parameters on components and pauses the plugin
bytes32 constant MANAGER_PERMISSION_ID = keccak256("MANAGER_PERMISSION");

/// @dev Calls `trigger()` on the plugin
bytes32 constant TRIGGER_PERMISSION_ID = keccak256("TRIGGER_PERMISSION");

/// @dev Installs and removes steps. DAO only: a step can return arbitrary DAO actions.
bytes32 constant CONFIGURE_PERMISSION_ID = keccak256("CONFIGURE_PERMISSION");

/// @dev Restarts a stream budget from zero
bytes32 constant CHECKPOINT_PERMISSION_ID = keccak256("CHECKPOINT_PERMISSION");

/// @dev Ratios are fractions of 1_000_000
uint256 constant RATIO_BASE = 1_000_000;

/// @dev Prices are 1e18-scaled: demanded_raw * 1e18 / offered_raw
uint256 constant EXCHANGE_RATE_SCALE = 1e18;
