// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DaoUnauthorized} from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import {CapitalPipelinePlugin} from "../src/CapitalPipelinePlugin.sol";
import {BalanceBudget} from "../src/budgets/BalanceBudget.sol";
import {MerkleClaimAction} from "../src/actions/MerkleClaimAction.sol";
import {Node} from "../src/lib/types.sol";
import {MANAGER_PERMISSION_ID, RECORD_CLAIM_PERMISSION_ID} from "../src/lib/constants.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockExchange, MockSwapAction} from "./mocks/MockSwap.sol";
import {BadAction} from "./mocks/BadComponents.sol";

/// @notice Two-leaf tree: alice is owed 10 A, bob 30 A (cumulative)
contract MerkleClaimActionTest is Fixture {
    uint256 internal aliceAmount;
    uint256 internal bobAmount;

    BalanceBudget internal budget;
    MerkleClaimAction internal merkle;
    CapitalPipelinePlugin internal plugin;

    function setUp() public override {
        super.setUp();
        budget = _deployBalanceBudget(tokenA);
        merkle = _deployMerkle(budget, _root(10 ether, 30 ether));
        plugin = _deployPlugin(budget, _chain(merkle, toBeneficiary));
    }

    function test_AccountClaimsItsAmount() public {
        vm.prank(alice);
        plugin.trigger(_claim(alice, 10 ether, address(0), 2));

        assertEq(tokenA.balanceOf(alice), 10 ether);
        assertEq(tokenA.balanceOf(address(dao)), DAO_A - 10 ether);
        assertEq(merkle.claimed(alice), 10 ether);
    }

    function test_RevertWhen_ClaimingAgain() public {
        vm.startPrank(alice);
        plugin.trigger(_claim(alice, 10 ether, address(0), 2));

        vm.expectRevert(MerkleClaimAction.NothingToClaim.selector);
        plugin.trigger(_claim(alice, 10 ether, address(0), 2));
        vm.stopPrank();
    }

    function test_RevertWhen_SomeoneElseClaims() public {
        vm.expectRevert(MerkleClaimAction.NotTheAccount.selector);
        vm.prank(carol);
        plugin.trigger(_claim(alice, 10 ether, address(0), 2));
    }

    function test_AccountRedirectsToAnotherBeneficiary() public {
        vm.prank(alice);
        plugin.trigger(_claim(alice, 10 ether, carol, 2));

        assertEq(tokenA.balanceOf(carol), 10 ether);
        assertEq(tokenA.balanceOf(alice), 0);
    }

    function test_RevertWhen_BeneficiaryIsTheDao() public {
        vm.expectRevert(MerkleClaimAction.InvalidBeneficiary.selector);
        vm.prank(alice);
        plugin.trigger(_claim(alice, 10 ether, address(dao), 2));
    }

    function test_RevertWhen_ProofIsInvalid() public {
        vm.expectRevert(MerkleClaimAction.InvalidProof.selector);
        vm.prank(alice);
        plugin.trigger(_claim(alice, 20 ether, address(0), 2)); // the tree says 10
    }

    function test_NewRootPaysTheDifference() public {
        vm.prank(alice);
        plugin.trigger(_claim(alice, 10 ether, address(0), 2));

        vm.prank(manager);
        merkle.setRoot(_root(25 ether, 30 ether));

        vm.prank(alice);
        plugin.trigger(_claim(alice, 25 ether, address(0), 2));

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

    function test_RevertWhen_RecordClaimUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector, address(dao), address(merkle), address(this), RECORD_CLAIM_PERMISSION_ID
            )
        );
        merkle.recordClaim(alice, 10 ether, alice);
    }

    function test_RevertWhen_TheDaoCannotPay() public {
        vm.prank(manager);
        merkle.setRoot(_root(1_000 ether, 30 ether));

        vm.expectRevert(
            abi.encodeWithSelector(CapitalPipelinePlugin.InAmountExceedsInput.selector, 0, 1_000 ether, DAO_A)
        );
        vm.prank(alice);
        plugin.trigger(_claim(alice, 1_000 ether, address(0), 2));
    }

    function test_RevertWhen_TheDaoIsEmpty() public {
        ERC20Mock _token = new ERC20Mock("Empty", "E"); // the DAO holds none
        BalanceBudget _budget = _deployBalanceBudget(IERC20(address(_token)));
        CapitalPipelinePlugin _plugin =
            _deployPlugin(_budget, _chain(_deployMerkle(_budget, _root(10 ether, 30 ether)), toBeneficiary));

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.EmptyInput.selector, 0));
        vm.prank(alice);
        _plugin.trigger(_claim(alice, 10 ether, address(0), 2));
    }

    /// Claim → swap A to B at 2 → pay the beneficiary (redirected to carol)
    function test_ClaimThenSwap() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _chain(merkle, _swap(), toBeneficiary));

        vm.prank(alice);
        _plugin.trigger(_claim(alice, 10 ether, carol, 3));

        assertEq(tokenB.balanceOf(carol), 20 ether);
        assertEq(tokenA.balanceOf(address(dao)), DAO_A - 10 ether);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B, "treasury B untouched");
    }

    /// Claim → 1% to the fee address, 99% swapped and paid to alice
    function test_ClaimWithAFeeBranch() public {
        Node[] memory _tree = new Node[](4);
        _tree[0] = _branch(merkle, 1, 10_000, 2, 990_000);
        _tree[1] = _leaf(_deployTransfer(fee));
        _tree[2] = _then(_swap(), 3);
        _tree[3] = _leaf(toBeneficiary);
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _tree);

        vm.prank(alice);
        _plugin.trigger(_claim(alice, 10 ether, address(0), 4));

        assertEq(tokenA.balanceOf(fee), 0.1 ether);
        assertEq(tokenB.balanceOf(alice), 19.8 ether);
    }

    /// Issue 1: if a later node can't run, the whole claim reverts and stays claimable
    function test_ClaimStaysOpenWhenALaterNodeCannotRun() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(
            budget, _chain(merkle, new BadAction(BadAction.Mode.Skip, address(dao), tokenB), toBeneficiary)
        );

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.NodeIncomplete.selector, 1, 0, 10 ether));
        vm.prank(alice);
        _plugin.trigger(_claim(alice, 10 ether, address(0), 3));

        assertEq(merkle.claimed(alice), 0, "nothing recorded");
    }

    // Helpers

    function _swap() internal returns (MockSwapAction) {
        MockExchange _exchange = new MockExchange(2e18);
        tokenB.mint(address(_exchange), 1_000 ether);
        return new MockSwapAction(_exchange, tokenB, address(dao));
    }

    function _leafHash(address _account, uint256 _cumulative) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(_account, _cumulative))));
    }

    /// @dev OpenZeppelin MerkleProof hashes sorted pairs
    function _hashPair(bytes32 _a, bytes32 _b) internal pure returns (bytes32) {
        return _a < _b ? keccak256(abi.encode(_a, _b)) : keccak256(abi.encode(_b, _a));
    }

    function _root(uint256 _alice, uint256 _bob) internal returns (bytes32) {
        (aliceAmount, bobAmount) = (_alice, _bob);
        return _hashPair(_leafHash(alice, _alice), _leafHash(bob, _bob));
    }

    /// @dev Root data for a flow of `_nodes` nodes. In a two-leaf tree, the proof is the other leaf.
    function _claim(address _account, uint256 _cumulative, address _beneficiary, uint256 _nodes)
        internal
        view
        returns (bytes[] memory _data)
    {
        bytes32[] memory _proof = new bytes32[](1);
        _proof[0] = _account == alice ? _leafHash(bob, bobAmount) : _leafHash(alice, aliceAmount);

        _data = new bytes[](_nodes);
        _data[0] = abi.encode(_account, _cumulative, _proof, _beneficiary);
    }
}
