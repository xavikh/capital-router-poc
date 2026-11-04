// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {DaoUnauthorized} from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {FundedStreamBudget} from "../src/budgets/FundedStreamBudget.sol";
import {OpenFillAction} from "../src/actions/OpenFillAction.sol";
import {IFiller} from "../src/interfaces/IFiller.sol";
import {Plan} from "../src/lib/types.sol";
import {MANAGER_PERMISSION_ID} from "../src/lib/constants.sol";
import {Fixture} from "./helpers/Fixture.sol";

contract OpenFillActionTest is Fixture {
    FundedStreamBudget internal budget;
    OpenFillAction internal action;
    address internal filler = makeAddr("filler");

    function setUp() public override {
        super.setUp();
        budget = _deployBudget(RATE, 0);
        action = _deployAction(budget);
    }

    function test_MaxOfferedHoldsTheMinimumPrice() public view {
        assertEq(action.maxOffered(), 20 ether); // 1000 B / 50 B-per-A
    }

    function test_BuildCapsTheOfferAtMaxOffered() public view {
        (Plan memory _plan,) = action.build(filler, "", _draft(50 ether));

        assertEq(_plan.inAmount, 20 ether);
        assertEq(address(_plan.outToken), address(tokenB));
        assertEq(_plan.outAmount, DEMAND);
        assertEq(_plan.beneficiary, alice, "carries the beneficiary on");
    }

    function test_BuildApprovesCallsBackAndClearsApproval() public view {
        (, Action[] memory _actions) = action.build(filler, "solver-data", _draft(10 ether));

        assertEq(_actions.length, 3);
        assertEq(_actions[0].to, address(tokenA));
        assertEq(_actions[0].data, abi.encodeCall(IERC20.approve, (filler, 10 ether)));
        assertEq(_actions[1].to, filler);
        assertEq(
            _actions[1].data,
            abi.encodeCall(IFiller.fillOffer, (IERC20(tokenA), 10 ether, IERC20(tokenB), DEMAND, "solver-data"))
        );
        assertEq(_actions[2].to, address(tokenA));
        assertEq(_actions[2].data, abi.encodeCall(IERC20.approve, (filler, 0)));
    }

    function test_BuildReturnsNothingForAnEmptyBudget() public view {
        (Plan memory _plan, Action[] memory _actions) = action.build(filler, "", _draft(0));

        assertEq(_plan.inAmount, 0);
        assertEq(_actions.length, 0);
    }

    function test_PostconditionsAssertTheDaoReceivedTheDemand() public view {
        (Plan memory _plan,) = action.build(filler, "", _draft(10 ether));
        Action[] memory _checks = action.postconditions(filler, _plan);

        assertEq(_checks.length, 1);
        assertEq(_checks[0].to, address(action));
        assertEq(_checks[0].data, abi.encodeCall(action.assertReceived, (IERC20(tokenB), DAO_B + DEMAND)));
    }

    function test_RevertWhen_DemandNotReceived() public {
        vm.expectRevert(abi.encodeWithSelector(OpenFillAction.DemandNotMet.selector, DAO_B + DEMAND, DAO_B));
        action.assertReceived(tokenB, DAO_B + DEMAND);
    }

    function test_SetDemandPerFillRestartsTheAuction() public {
        vm.warp(block.timestamp + EPOCH);
        assertEq(budget.available(), RATE);

        vm.prank(manager);
        action.setDemandPerFill(500 ether);

        assertEq(action.demandPerFill(), 500 ether);
        assertEq(budget.available(), 0);
    }

    function test_SetMinDemandedPerOfferedRestartsTheAuction() public {
        vm.warp(block.timestamp + EPOCH);

        vm.prank(manager);
        action.setMinDemandedPerOffered(25 ether);

        assertEq(action.maxOffered(), 40 ether);
        assertEq(budget.available(), 0);
    }

    function test_RevertWhen_SetterUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector, address(dao), address(action), address(this), MANAGER_PERMISSION_ID
            )
        );
        action.setDemandPerFill(1);
    }

    function test_RevertWhen_DemandedTokenIsOfferedToken() public {
        OpenFillAction _action = _clone();
        vm.expectRevert(OpenFillAction.SameToken.selector);
        _action.initialize(dao, budget, tokenA, DEMAND, MIN_PRICE);
    }

    function test_RevertWhen_DemandedTokenHasNoCode() public {
        OpenFillAction _action = _clone();
        vm.expectRevert(OpenFillAction.InvalidToken.selector);
        _action.initialize(dao, budget, IERC20(address(0xBEEF)), DEMAND, MIN_PRICE);
    }

    function test_RevertWhen_ZeroDemand() public {
        vm.expectRevert(OpenFillAction.ZeroDemand.selector);
        vm.prank(manager);
        action.setDemandPerFill(0);
    }

    function test_RevertWhen_ZeroMinimumPrice() public {
        vm.expectRevert(OpenFillAction.ZeroMinDemandedPerOffered.selector);
        vm.prank(manager);
        action.setMinDemandedPerOffered(0);
    }

    function test_RevertWhen_MinimumPriceTooHigh() public {
        vm.expectRevert(OpenFillAction.MinDemandedPerOfferedTooHigh.selector);
        vm.prank(manager);
        action.setMinDemandedPerOffered(DEMAND * 1e18 + 1);
    }

    function _draft(uint256 _available) internal view returns (Plan memory) {
        return
            Plan({inToken: tokenA, inAmount: _available, outToken: tokenA, outAmount: _available, beneficiary: alice});
    }

    function _clone() internal returns (OpenFillAction) {
        return OpenFillAction(ProxyLib.deployMinimalProxy(address(new OpenFillAction()), ""));
    }
}
