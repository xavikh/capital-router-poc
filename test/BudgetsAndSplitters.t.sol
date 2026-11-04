// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {BalanceBudget} from "../src/budgets/BalanceBudget.sol";
import {PayBeneficiary} from "../src/splitters/PayBeneficiary.sol";
import {Allocation, Plan} from "../src/lib/types.sol";
import {Fixture} from "./helpers/Fixture.sol";

contract BalanceBudgetTest is Fixture {
    function test_AvailableIsTheDaoBalance() public {
        BalanceBudget _budget = _deployBalanceBudget(tokenA);

        assertEq(_budget.available(), DAO_A);
        assertEq(address(_budget.token()), address(tokenA));
    }

    function test_CommitsNothing() public {
        Plan memory _plan;
        assertEq(_deployBalanceBudget(tokenA).commitActions(_plan).length, 0);
    }

    function test_RevertWhen_TokenHasNoCode() public {
        BalanceBudget _budget = BalanceBudget(ProxyLib.deployMinimalProxy(address(new BalanceBudget()), ""));

        vm.expectRevert(BalanceBudget.InvalidToken.selector);
        _budget.initialize(dao, IERC20(address(0)));
    }
}

contract PayBeneficiaryTest is Fixture {
    PayBeneficiary internal splitter = new PayBeneficiary();

    function test_PaysTheWholeOutputToTheBeneficiary() public view {
        Allocation[] memory _allocations = splitter.split(Plan(tokenA, 5 ether, tokenB, 7 ether, alice));

        assertEq(_allocations.length, 1);
        assertEq(_allocations[0].recipient, alice);
        assertEq(_allocations[0].amount, 7 ether);
    }

    function test_RevertWhen_NoBeneficiary() public {
        vm.expectRevert(PayBeneficiary.NoBeneficiary.selector);
        splitter.split(Plan(tokenA, 5 ether, tokenB, 7 ether, address(0)));
    }
}
