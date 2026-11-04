// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {CapitalPipelinePlugin} from "../CapitalPipelinePlugin.sol";

/// @title TriggerBatch
/// @notice Triggers several plugins (on any DAOs) in one transaction. A plugin marked as allowed
///         to fail is skipped with an event instead of reverting the batch.
/// @dev Holds no state and no permissions: `trigger` is open to anyone by default. Each call is
///      sequential, not nested, so the plugins' reentrancy locks don't interfere.
contract TriggerBatch {
    event TriggerFailed(uint256 index, CapitalPipelinePlugin plugin, bytes reason);

    error LengthMismatch();

    /// @param _plugins The plugins to trigger, in order
    /// @param _data The `trigger` data for each plugin (empty bytes[] for none)
    /// @param _allowFailure Whether each plugin may fail without reverting the batch
    function triggerAll(
        CapitalPipelinePlugin[] calldata _plugins,
        bytes[][] calldata _data,
        bool[] calldata _allowFailure
    ) external {
        if (_data.length != _plugins.length || _allowFailure.length != _plugins.length) {
            revert LengthMismatch();
        }

        for (uint256 i; i < _plugins.length; ++i) {
            try _plugins[i].trigger(_data[i]) {}
            catch (bytes memory _reason) {
                if (!_allowFailure[i]) {
                    assembly {
                        revert(add(_reason, 0x20), mload(_reason))
                    }
                }
                emit TriggerFailed(i, _plugins[i], _reason);
            }
        }
    }
}
