// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {
    DaoAuthorizableUpgradeable
} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizableUpgradeable.sol";
import {INodeAction} from "../interfaces/INodeAction.sol";
import {IBudget, ICheckpointedBudget} from "../interfaces/IBudget.sol";
import {IFiller} from "../interfaces/IFiller.sol";
import {Input, Movement} from "../lib/types.sol";
import {MANAGER_PERMISSION_ID, EXCHANGE_RATE_SCALE} from "../lib/constants.sol";
import {NATIVE, tokenBalance, isToken} from "../lib/tokens.sol";

/// @title OpenFillAction
/// @notice Take-it-or-leave-it swap priced as a Dutch auction. The bound budget grows the offer
///         from zero; the DAO demands a flat `demandPerFill` back; any filler can take it.
/// @dev The price obtained is `demandPerFill / offered`, so it worsens as the offer grows.
///      `maxOffered()` caps the offer at `demandPerFill / minDemandedPerOffered`, which holds the
///      worst acceptable price. Price terms are 1e18-scaled: `demanded_raw * 1e18 / offered_raw`.
///      Changing either price term restarts the auction, so a filler cannot take an offer that
///      accumulated under the old terms at the new price.
///
///      Native ETH (`NATIVE`) works on either side, never both: a native offer is sent as call
///      value with the callback (no approvals); a native demand is measured on the DAO's ETH balance.
contract OpenFillAction is INodeAction, DaoAuthorizableUpgradeable {
    /// @inheritdoc INodeAction
    IBudget public budget;

    /// @notice The token the DAO must receive back
    IERC20 public demandedToken;

    /// @notice How much of the demanded token must come back per fill
    uint256 public demandPerFill;

    /// @notice The lowest acceptable price, 1e18-scaled demanded per offered
    uint256 public minDemandedPerOffered;

    /// @notice Emitted when the price terms are set or updated
    event TermsUpdated(uint256 demandPerFill, uint256 minDemandedPerOffered);

    /// @notice Thrown when the budget is address(0)
    error NoBudget();

    /// @notice Thrown when the demanded token is neither native ETH (`NATIVE`) nor a contract
    error InvalidToken();

    /// @notice Thrown when the demanded token is the budget's token
    error SameToken();

    /// @notice Thrown when the demand is zero (it would give the offered token away)
    error ZeroDemand();

    /// @notice Thrown when no minimum price is given
    error ZeroMinDemandedPerOffered();

    /// @notice Thrown when the minimum price is so high that not even 1 wei could be offered
    error MinDemandedPerOfferedTooHigh();

    /// @notice Thrown when the DAO holds less of the demanded token than the fill requires
    error DemandNotMet(uint256 required, uint256 actual);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param _dao The DAO executing the fills
    /// @param _budget The budget growing the offer; this action restarts it when terms change
    /// @param _demandedToken The token the DAO must receive back (`NATIVE` for native ETH)
    /// @param _demandPerFill How much of the demanded token must come back per fill
    /// @param _minDemandedPerOffered The lowest acceptable price, 1e18-scaled
    function initialize(
        IDAO _dao,
        ICheckpointedBudget _budget,
        IERC20 _demandedToken,
        uint256 _demandPerFill,
        uint256 _minDemandedPerOffered
    ) external initializer {
        if (address(_budget) == address(0)) revert NoBudget();
        if (!isToken(_demandedToken)) revert InvalidToken();
        if (_demandedToken == _budget.token()) revert SameToken();

        __DaoAuthorizableUpgradeable_init(_dao);

        budget = _budget;
        demandedToken = _demandedToken;
        _setTerms(_demandPerFill, _minDemandedPerOffered);
    }

    // INodeAction

    /// @inheritdoc INodeAction
    /// @dev None in v1
    function preconditions(address, Input calldata) external view virtual {}

    /// @inheritdoc INodeAction
    /// @dev ERC20 offer: approve it to the caller, call it back, clear the approval.
    ///      Native offer: call the caller back with the offer as call value.
    function build(address _caller, bytes calldata _data, Input calldata _input)
        external
        view
        virtual
        returns (Movement memory _movement, Action[] memory _actions)
    {
        uint256 _offered = Math.min(_input.amount, maxOffered());

        _movement = Movement({
            inToken: _input.token,
            inAmount: _offered,
            outToken: demandedToken,
            outAmount: demandPerFill,
            beneficiary: _input.beneficiary
        });

        bytes memory _callback =
            abi.encodeCall(IFiller.fillOffer, (_input.token, _offered, demandedToken, demandPerFill, _data));

        if (_input.token == NATIVE) {
            _actions = new Action[](1);
            _actions[0] = Action({to: _caller, value: _offered, data: _callback});
            return (_movement, _actions);
        }

        address _in = address(_input.token);
        _actions = new Action[](3);
        _actions[0] = Action({to: _in, value: 0, data: abi.encodeCall(IERC20.approve, (_caller, _offered))});
        _actions[1] = Action({to: _caller, value: 0, data: _callback});
        _actions[2] = Action({to: _in, value: 0, data: abi.encodeCall(IERC20.approve, (_caller, 0))});
    }

    /// @inheritdoc INodeAction
    /// @dev Reverts the whole trigger unless the DAO received at least `outAmount`
    function postconditions(address, Movement calldata _movement)
        external
        view
        virtual
        returns (Action[] memory _actions)
    {
        uint256 _minBalance = tokenBalance(_movement.outToken, address(dao())) + _movement.outAmount;

        _actions = new Action[](1);
        _actions[0] = Action({
            to: address(this), value: 0, data: abi.encodeCall(this.assertReceived, (_movement.outToken, _minBalance))
        });
    }

    /// @notice Reverts unless the DAO holds at least `_minBalance` of `_token`
    /// @dev Executed by the DAO as the postcondition of a fill. View, so harmless to call from anywhere.
    function assertReceived(IERC20 _token, uint256 _minBalance) external view virtual {
        uint256 _balance = tokenBalance(_token, address(dao()));
        if (_balance < _minBalance) revert DemandNotMet(_minBalance, _balance);
    }

    /// @notice The most the DAO hands over in one fill: `demandPerFill / minDemandedPerOffered`
    /// @dev Rounded down, so the price obtained lands at or above `minDemandedPerOffered`
    function maxOffered() public view virtual returns (uint256) {
        return (demandPerFill * EXCHANGE_RATE_SCALE) / minDemandedPerOffered;
    }

    // Manager settings. Both restart the auction.

    /// @notice Updates how much must come back per fill, and restarts the auction
    function setDemandPerFill(uint256 _demandPerFill) external virtual auth(MANAGER_PERMISSION_ID) {
        _setTerms(_demandPerFill, minDemandedPerOffered);
        _restartAuction();
    }

    /// @notice Updates the lowest acceptable price, and restarts the auction
    function setMinDemandedPerOffered(uint256 _minDemandedPerOffered) external virtual auth(MANAGER_PERMISSION_ID) {
        _setTerms(demandPerFill, _minDemandedPerOffered);
        _restartAuction();
    }

    // Internal

    /// @dev Bound at init to an ICheckpointedBudget, so the cast is safe
    function _restartAuction() internal virtual {
        ICheckpointedBudget(address(budget)).writeCheckpoint();
    }

    function _setTerms(uint256 _demandPerFill, uint256 _minDemandedPerOffered) internal virtual {
        if (_demandPerFill == 0) revert ZeroDemand();
        if (_minDemandedPerOffered == 0) revert ZeroMinDemandedPerOffered();
        // Keeps maxOffered() >= 1, so a non-empty input always gets an offer
        if (_demandPerFill * EXCHANGE_RATE_SCALE < _minDemandedPerOffered) revert MinDemandedPerOfferedTooHigh();

        demandPerFill = _demandPerFill;
        minDemandedPerOffered = _minDemandedPerOffered;

        emit TermsUpdated(_demandPerFill, _minDemandedPerOffered);
    }
}
