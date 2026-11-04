// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {DaoUnauthorized} from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import {RatioSplitter} from "../src/splitters/RatioSplitter.sol";
import {Allocation, Plan} from "../src/lib/types.sol";
import {MANAGER_PERMISSION_ID, RATIO_BASE} from "../src/lib/constants.sol";
import {Fixture} from "./helpers/Fixture.sol";

contract RatioSplitterTest is Fixture {
    RatioSplitter internal splitter;

    function setUp() public override {
        super.setUp();
        splitter = _deploySplitter();
    }

    function test_SplitsNinetyFiveFive() public view {
        Allocation[] memory _allocations = splitter.split(_output(1000 ether));

        assertEq(_allocations.length, 2);
        assertEq(_allocations[0].recipient, BURN);
        assertEq(_allocations[0].amount, 950 ether);
        assertEq(_allocations[1].recipient, fee);
        assertEq(_allocations[1].amount, 50 ether);
    }

    function test_RemainderGoesToLargestShare() public view {
        Allocation[] memory _allocations = splitter.split(_output(1)); // both shares round down to 0

        assertEq(_allocations[0].amount, 1);
        assertEq(_allocations[1].amount, 0);
    }

    function testFuzz_AllocationsSumToAmount(uint256 _amount, uint256 _ratio) public {
        _amount = bound(_amount, 0, type(uint128).max);
        _ratio = bound(_ratio, 0, RATIO_BASE);
        _set(uint32(_ratio), uint32(RATIO_BASE - _ratio));

        Allocation[] memory _allocations = splitter.split(_output(_amount));

        assertEq(_allocations[0].amount + _allocations[1].amount, _amount);
    }

    function test_ManagerReplacesRecipients() public {
        _set(500_000, 500_000);

        Allocation[] memory _allocations = splitter.split(_output(10));
        assertEq(_allocations[0].amount, 5);
        assertEq(_allocations[1].amount, 5);
    }

    function test_RevertWhen_RatiosDoNotSumToBase() public {
        vm.expectRevert(RatioSplitter.InvalidRatios.selector);
        _set(500_000, 400_000);
    }

    function test_RevertWhen_LengthMismatch() public {
        vm.expectRevert(RatioSplitter.LengthMismatch.selector);
        vm.prank(manager);
        splitter.setRecipients(new address[](2), new uint32[](1));
    }

    function test_RevertWhen_NoRecipients() public {
        vm.expectRevert(RatioSplitter.NoRecipients.selector);
        vm.prank(manager);
        splitter.setRecipients(new address[](0), new uint32[](0));
    }

    function test_RevertWhen_ZeroRecipient() public {
        uint32[] memory _ratios = new uint32[](1);
        _ratios[0] = uint32(RATIO_BASE);

        vm.expectRevert(RatioSplitter.ZeroRecipient.selector);
        vm.prank(manager);
        splitter.setRecipients(new address[](1), _ratios);
    }

    function test_RevertWhen_SetRecipientsUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector, address(dao), address(splitter), address(this), MANAGER_PERMISSION_ID
            )
        );
        splitter.setRecipients(new address[](0), new uint32[](0));
    }

    function _output(uint256 _amount) internal view returns (Plan memory) {
        return Plan({inToken: tokenB, inAmount: 0, outToken: tokenB, outAmount: _amount, beneficiary: address(0)});
    }

    function _set(uint32 _burnRatio, uint32 _feeRatio) internal {
        address[] memory _recipients = new address[](2);
        (_recipients[0], _recipients[1]) = (BURN, fee);
        uint32[] memory _ratios = new uint32[](2);
        (_ratios[0], _ratios[1]) = (_burnRatio, _feeRatio);

        vm.prank(manager);
        splitter.setRecipients(_recipients, _ratios);
    }
}
