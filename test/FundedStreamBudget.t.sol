// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {DaoUnauthorized} from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FundedStreamBudget} from "../src/budgets/FundedStreamBudget.sol";
import {Plan} from "../src/lib/types.sol";
import {MANAGER_PERMISSION_ID, CHECKPOINT_PERMISSION_ID} from "../src/lib/constants.sol";
import {Fixture} from "./helpers/Fixture.sol";

contract FundedStreamBudgetTest is Fixture {
    FundedStreamBudget internal budget;

    function setUp() public override {
        super.setUp();
        budget = _deployBudget(RATE, 0);
    }

    function test_GrowsAtRatePerEpoch() public {
        assertEq(budget.available(), 0);

        vm.warp(block.timestamp + EPOCH);
        assertEq(budget.available(), RATE);

        vm.warp(block.timestamp + EPOCH / 2);
        assertEq(budget.available(), RATE + RATE / 2);
    }

    function test_DepositDoesNotLiftTheCapUntilSync() public {
        vm.warp(block.timestamp + 20 * EPOCH); // 200 accrued, capped at the 100 seen
        assertEq(budget.available(), DAO_A);

        tokenA.mint(address(dao), 50 ether);
        assertEq(budget.available(), DAO_A, "deposit must not lift the cap");

        budget.sync();
        assertEq(budget.available(), DAO_A, "sync must not jump");

        vm.warp(block.timestamp + EPOCH);
        assertEq(budget.available(), DAO_A + RATE, "growth resumes from where it froze");
    }

    function test_CommitActionsWriteCheckpoint() public view {
        Plan memory _plan;
        Action[] memory _actions = budget.commitActions(_plan);

        assertEq(_actions.length, 1);
        assertEq(_actions[0].to, address(budget));
        assertEq(_actions[0].value, 0);
        assertEq(_actions[0].data, abi.encodeCall(budget.writeCheckpoint, ()));
    }

    function test_WriteCheckpointRestartsFromZero() public {
        vm.warp(block.timestamp + EPOCH);

        vm.prank(address(dao));
        budget.writeCheckpoint();

        assertEq(budget.available(), 0);
    }

    function test_SetAmountPerEpochKeepsWhatAccrued() public {
        vm.warp(block.timestamp + EPOCH);

        vm.prank(manager);
        budget.setAmountPerEpoch(2 * RATE);
        assertEq(budget.available(), RATE, "no change in the same block");

        vm.warp(block.timestamp + EPOCH);
        assertEq(budget.available(), RATE + 2 * RATE, "new rate from now on");
    }

    function test_RaisingMaxBudgetDoesNotJump() public {
        vm.prank(manager);
        budget.setMaxBudget(5 ether);

        vm.warp(block.timestamp + 2 * EPOCH); // 20 accrued, capped at 5
        assertEq(budget.available(), 5 ether);

        vm.prank(manager);
        budget.setMaxBudget(0);
        assertEq(budget.available(), 5 ether, "hidden accrual must not be released");

        vm.warp(block.timestamp + EPOCH);
        assertEq(budget.available(), 5 ether + RATE);
    }

    function test_SetEpochIntervalKeepsWhatAccrued() public {
        vm.warp(block.timestamp + EPOCH);

        vm.prank(manager);
        budget.setEpochInterval(2 * EPOCH);
        assertEq(budget.available(), RATE);

        vm.warp(block.timestamp + 2 * EPOCH);
        assertEq(budget.available(), 2 * RATE);
    }

    function test_RevertWhen_WriteCheckpointUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector, address(dao), address(budget), address(this), CHECKPOINT_PERMISSION_ID
            )
        );
        budget.writeCheckpoint();
    }

    function test_RevertWhen_SetterUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector, address(dao), address(budget), address(this), MANAGER_PERMISSION_ID
            )
        );
        budget.setAmountPerEpoch(1);
    }

    function test_RevertWhen_TokenHasNoCode() public {
        FundedStreamBudget _budget =
            FundedStreamBudget(ProxyLib.deployMinimalProxy(address(new FundedStreamBudget()), ""));

        vm.expectRevert(FundedStreamBudget.InvalidToken.selector);
        _budget.initialize(dao, IERC20(address(0)), RATE, 0, EPOCH);
    }
}
