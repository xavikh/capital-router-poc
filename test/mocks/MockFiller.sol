// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFiller} from "../../src/interfaces/IFiller.sol";
import {CapitalPipelinePlugin} from "../../src/CapitalPipelinePlugin.sol";

/// @notice Triggers the plugin and fills the offer, delivering `demandedAmount + fillDelta`
contract MockFiller is IFiller {
    CapitalPipelinePlugin public immutable plugin;

    /// @notice Added to the demanded amount when delivering (negative = under-deliver)
    int256 public fillDelta;

    /// @notice When true, tries to re-enter `trigger` from inside the callback
    bool public reenter;

    /// @notice The revert data of the last re-entry attempt
    bytes public reentryError;

    /// @notice Total demanded token delivered to the DAO
    uint256 public totalDelivered;

    constructor(CapitalPipelinePlugin _plugin) {
        plugin = _plugin;
    }

    function setFillDelta(int256 _delta) external {
        fillDelta = _delta;
    }

    function setReenter(bool _reenter) external {
        reenter = _reenter;
    }

    /// @notice This contract becomes the trigger caller, so the DAO calls it back
    function fill(bytes memory _data) external {
        bytes[] memory _perStep = new bytes[](1);
        _perStep[0] = _data;
        plugin.trigger(_perStep);
    }

    /// @notice Triggers with no data at all, which works for flows of any length
    function fillWithoutData() external {
        plugin.trigger(new bytes[](0));
    }

    function fillOffer(
        IERC20 _offeredToken,
        uint256 _offeredAmount,
        IERC20 _demandedToken,
        uint256 _demandedAmount,
        bytes calldata
    ) external {
        if (reenter) {
            try plugin.trigger(new bytes[](0)) {}
            catch (bytes memory _reason) {
                reentryError = _reason;
            }
        }

        _offeredToken.transferFrom(msg.sender, address(this), _offeredAmount);

        uint256 _amount = uint256(int256(_demandedAmount) + fillDelta);
        _demandedToken.transfer(msg.sender, _amount);
        totalDelivered += _amount;
    }
}
