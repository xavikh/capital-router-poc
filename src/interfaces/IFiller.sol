// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IFiller
/// @notice The callback a filler contract implements to take an open-fill offer. The filler calls
///         `trigger()` on the plugin; the DAO approves `offeredAmount` to it and calls this function
///         on that same caller. The filler pulls the offered tokens and must leave the DAO holding
///         at least `demandedAmount` more of `demandedToken` before returning.
/// @dev Same selector as capital-router's `ISwapSolver.fillOffer`, so existing fillers keep working.
///      Native ETH is `0xEeee…EEeE` (see `NATIVE` in lib/tokens.sol) on either side, never both: a native offer arrives as
///      `msg.value` with no approval; a native demand must be sent to the DAO as ETH.
interface IFiller {
    function fillOffer(
        IERC20 offeredToken,
        uint256 offeredAmount,
        IERC20 demandedToken,
        uint256 demandedAmount,
        bytes calldata data
    ) external payable;
}
