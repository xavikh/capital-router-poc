// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CapitalPipelinePlugin} from "../../src/CapitalPipelinePlugin.sol";
import {IFiller} from "../../src/interfaces/IFiller.sol";
import {NATIVE} from "../../src/lib/tokens.sol";

/// @notice A filler for the playground: takes the open-fill offer at the root of any flow and pays
///         the demanded amount from its own balance. Anyone can make it fill.
contract PlaygroundFiller is IFiller {
    /// @notice Triggers `_plugin`, whose root must be an OpenFillAction, and takes its offer
    function fill(CapitalPipelinePlugin _plugin) external {
        _plugin.trigger(new bytes[](0));
    }

    /// @inheritdoc IFiller
    /// @dev Called by the DAO: pulls the offer and sends the demanded amount back
    function fillOffer(
        IERC20 _offeredToken,
        uint256 _offeredAmount,
        IERC20 _demandedToken,
        uint256 _demandedAmount,
        bytes calldata
    ) external payable {
        if (_offeredToken != NATIVE) {
            _offeredToken.transferFrom(msg.sender, address(this), _offeredAmount);
        }

        if (_demandedToken == NATIVE) {
            (bool _sent,) = msg.sender.call{value: _demandedAmount}("");
            require(_sent, "ETH payment failed");
        } else {
            _demandedToken.transfer(msg.sender, _demandedAmount);
        }
    }

    receive() external payable {}
}
