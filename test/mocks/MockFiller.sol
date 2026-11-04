// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFiller} from "../../src/interfaces/IFiller.sol";
import {CapitalPipelinePlugin} from "../../src/CapitalPipelinePlugin.sol";
import {NATIVE} from "../../src/lib/tokens.sol";

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

    /// @notice This contract becomes the trigger caller, so the DAO calls it back. `_data` goes to
    ///         the root (the OpenFill node); the other nodes get none.
    function fill(bytes memory _data) external {
        bytes[] memory _perNode = new bytes[](plugin.nodes().length);
        _perNode[0] = _data;
        plugin.trigger(_perNode);
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
    ) external payable {
        if (reenter) {
            try plugin.trigger(new bytes[](0)) {}
            catch (bytes memory _reason) {
                reentryError = _reason;
            }
        }

        // A native offer already arrived as msg.value; an ERC20 offer is pulled
        if (_offeredToken != NATIVE) {
            _offeredToken.transferFrom(msg.sender, address(this), _offeredAmount);
        }

        uint256 _amount = uint256(int256(_demandedAmount) + fillDelta);
        if (_demandedToken == NATIVE) {
            (bool _ok,) = msg.sender.call{value: _amount}("");
            require(_ok, "MockFiller: ETH send failed");
        } else {
            _demandedToken.transfer(msg.sender, _amount);
        }
        totalDelivered += _amount;
    }

    receive() external payable {}
}
