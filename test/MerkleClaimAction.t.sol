// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {DaoUnauthorized} from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import {CapitalPipelinePlugin} from "../src/CapitalPipelinePlugin.sol";
import {BalanceBudget} from "../src/budgets/BalanceBudget.sol";
import {MerkleClaimAction} from "../src/actions/MerkleClaimAction.sol";
import {PayBeneficiary} from "../src/splitters/PayBeneficiary.sol";
import {MANAGER_PERMISSION_ID} from "../src/lib/constants.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {MockExchange, MockSwapAction} from "./mocks/MockSwap.sol";

/// @notice Two-leaf tree: alice is owed 10 A, bob 30 A (cumulative)
contract MerkleClaimActionTest is Fixture {
    uint256 internal aliceAmount;
    uint256 internal bobAmount;

    BalanceBudget internal budget;
    MerkleClaimAction internal merkle;
    PayBeneficiary internal payBeneficiary;
    CapitalPipelinePlugin internal plugin;

    function setUp() public override {
        super.setUp();
        budget = _deployBalanceBudget(tokenA);
        merkle = _deployMerkle(budget, _root(10 ether, 30 ether));
        payBeneficiary = new PayBeneficiary();
        plugin = _deployPlugin(budget, _one(merkle, payBeneficiary));
    }

    function test_AccountClaimsItsAmount() public {
        vm.prank(alice);
        plugin.trigger(_claim(alice, 10 ether, address(0)));

        assertEq(tokenA.balanceOf(alice), 10 ether);
        assertEq(tokenA.balanceOf(address(dao)), DAO_A - 10 ether);
        assertEq(merkle.claimed(alice), 10 ether);
    }

    function test_SecondClaimPaysNothing() public {
        vm.startPrank(alice);
        plugin.trigger(_claim(alice, 10 ether, address(0)));
        plugin.trigger(_claim(alice, 10 ether, address(0)));
        vm.stopPrank();

        assertEq(tokenA.balanceOf(alice), 10 ether);
    }

    function test_RelayerClaimsForTheAccount() public {
        vm.prank(carol);
        plugin.trigger(_claim(bob, 30 ether, address(0)));

        assertEq(tokenA.balanceOf(bob), 30 ether, "paid to the account, not the relayer");
        assertEq(tokenA.balanceOf(carol), 0);
    }

    function test_AccountRedirectsToAnotherBeneficiary() public {
        vm.prank(alice);
        plugin.trigger(_claim(alice, 10 ether, carol));

        assertEq(tokenA.balanceOf(carol), 10 ether);
        assertEq(tokenA.balanceOf(alice), 0);
    }

    function test_RevertWhen_RelayerRedirects() public {
        vm.expectRevert(MerkleClaimAction.OnlyAccountCanRedirect.selector);
        vm.prank(carol);
        plugin.trigger(_claim(alice, 10 ether, carol));
    }

    function test_RevertWhen_BeneficiaryIsTheDao() public {
        vm.expectRevert(MerkleClaimAction.InvalidBeneficiary.selector);
        vm.prank(alice);
        plugin.trigger(_claim(alice, 10 ether, address(dao)));
    }

    function test_RevertWhen_ProofIsInvalid() public {
        vm.expectRevert(MerkleClaimAction.InvalidProof.selector);
        plugin.trigger(_claim(alice, 20 ether, address(0))); // the tree says 10
    }

    function test_NewRootPaysTheDifference() public {
        vm.prank(alice);
        plugin.trigger(_claim(alice, 10 ether, address(0)));

        vm.prank(manager);
        merkle.setRoot(_root(25 ether, 30 ether));

        vm.prank(alice);
        plugin.trigger(_claim(alice, 25 ether, address(0)));

        assertEq(tokenA.balanceOf(alice), 25 ether, "10 in round one, 15 more in round two");
    }

    function test_RevertWhen_SetRootUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector, address(dao), address(merkle), address(this), MANAGER_PERMISSION_ID
            )
        );
        merkle.setRoot(bytes32(0));
    }

    function test_RevertWhen_TheDaoCannotPay() public {
        vm.prank(manager);
        merkle.setRoot(_root(1_000 ether, 30 ether));

        vm.expectRevert(
            abi.encodeWithSelector(CapitalPipelinePlugin.InAmountExceedsInput.selector, 0, 1_000 ether, DAO_A)
        );
        plugin.trigger(_claim(alice, 1_000 ether, address(0)));
    }

    function test_RevertWhen_RecordClaimIsNotCalledByTheDao() public {
        vm.expectRevert(MerkleClaimAction.OnlyDao.selector);
        merkle.recordClaim(alice, 10 ether, alice);
    }

    function test_ClaimThenSwap() public {
        // Stage 0: claim 10 A (kept). Stage 1: swap it to B at 2 B per A and pay the beneficiary.
        MockExchange _exchange = new MockExchange(2e18);
        tokenB.mint(address(_exchange), 1_000 ether);
        MockSwapAction _swap = new MockSwapAction(_exchange, tokenB, address(dao));
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _two(merkle, NO_SPLITTER, _swap, payBeneficiary));

        bytes[] memory _data = new bytes[](2);
        _data[0] = _claim(alice, 10 ether, carol)[0];
        vm.prank(alice);
        _plugin.trigger(_data);

        assertEq(tokenB.balanceOf(carol), 20 ether, "beneficiary receives the swapped amount");
        assertEq(tokenA.balanceOf(address(dao)), DAO_A - 10 ether);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B, "treasury B untouched");
    }

    // Helpers

    function _leaf(address _account, uint256 _cumulative) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(_account, _cumulative))));
    }

    /// @dev OpenZeppelin MerkleProof hashes sorted pairs
    function _hashPair(bytes32 _a, bytes32 _b) internal pure returns (bytes32) {
        return _a < _b ? keccak256(abi.encode(_a, _b)) : keccak256(abi.encode(_b, _a));
    }

    function _root(uint256 _alice, uint256 _bob) internal returns (bytes32) {
        (aliceAmount, bobAmount) = (_alice, _bob);
        return _hashPair(_leaf(alice, _alice), _leaf(bob, _bob));
    }

    /// @dev The proof for a leaf in a two-leaf tree is the other leaf
    function _claim(address _account, uint256 _cumulative, address _beneficiary)
        internal
        view
        returns (bytes[] memory _data)
    {
        bytes32[] memory _proof = new bytes32[](1);
        _proof[0] = _account == alice ? _leaf(bob, bobAmount) : _leaf(alice, aliceAmount);

        _data = new bytes[](1);
        _data[0] = abi.encode(_account, _cumulative, _proof, _beneficiary);
    }
}
