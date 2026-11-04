// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {CapitalPipelinePlugin} from "../src/CapitalPipelinePlugin.sol";
import {FundedStreamBudget} from "../src/budgets/FundedStreamBudget.sol";
import {OpenFillAction} from "../src/actions/OpenFillAction.sol";
import {MerkleClaimAction} from "../src/actions/MerkleClaimAction.sol";
import {PayBeneficiary} from "../src/splitters/PayBeneficiary.sol";
import {Plan} from "../src/lib/types.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {MockFiller} from "./mocks/MockFiller.sol";

/// @notice Native ETH is `IERC20(address(0))` everywhere: budgets, actions, splits, checks
contract NativeEthTest is Fixture {
    IERC20 internal constant ETH = IERC20(address(0));
    uint256 internal constant DAO_ETH = 100 ether;

    function setUp() public override {
        super.setUp();
        vm.deal(address(dao), DAO_ETH);
    }

    function test_BudgetPaysOutEth() public {
        CapitalPipelinePlugin _plugin =
            _deployPlugin(_deployBalanceBudget(ETH), _one(NO_ACTION, _deployRatio(alice, 500_000, bob, 500_000)));

        _plugin.trigger(noData);

        assertEq(alice.balance, 50 ether);
        assertEq(bob.balance, 50 ether);
        assertEq(address(dao).balance, 0);
    }

    function test_StreamedEthIsSoldForTokens() public {
        FundedStreamBudget _budget = _deployStream(ETH, RATE, 0);
        CapitalPipelinePlugin _plugin = _deployPlugin(_budget, _one(_deployAction(_budget), _deploySplitter()));
        MockFiller _filler = new MockFiller(_plugin);
        tokenB.mint(address(_filler), DEMAND);
        vm.warp(block.timestamp + EPOCH);

        _filler.fill("");

        assertEq(address(_filler).balance, RATE, "the offer arrives as call value");
        assertEq(address(dao).balance, DAO_ETH - RATE);
        assertEq(tokenB.balanceOf(BURN), 950 ether);
        assertEq(tokenB.balanceOf(fee), 50 ether);
        assertEq(_budget.available(), 0);
    }

    function test_NativeOfferNeedsNoApproval() public {
        FundedStreamBudget _budget = _deployStream(ETH, RATE, 0);
        OpenFillAction _action = _deployAction(_budget);

        (, Action[] memory _actions) = _action.build(alice, "", Plan(ETH, 10 ether, ETH, 10 ether, address(0)));

        assertEq(_actions.length, 1, "callback only");
        assertEq(_actions[0].to, alice);
        assertEq(_actions[0].value, 10 ether);
    }

    function test_TokensAreSoldForEth() public {
        FundedStreamBudget _budget = _deployBudget(RATE, 0); // token A
        CapitalPipelinePlugin _plugin = _deployPlugin(_budget, _one(_deployOpenFill(_budget, ETH), _deploySplitter()));
        MockFiller _filler = new MockFiller(_plugin);
        vm.deal(address(_filler), DEMAND);
        vm.warp(block.timestamp + EPOCH);

        _filler.fill("");

        assertEq(tokenA.balanceOf(address(_filler)), RATE);
        assertEq(BURN.balance, 950 ether);
        assertEq(fee.balance, 50 ether);
        assertEq(address(dao).balance, DAO_ETH, "pre-existing ETH untouched");
    }

    function test_MerkleClaimPaysEth() public {
        bytes32 _root = keccak256(bytes.concat(keccak256(abi.encode(alice, 1 ether))));
        MerkleClaimAction _merkle = _deployMerkle(_deployBalanceBudget(ETH), _root);
        CapitalPipelinePlugin _plugin = _deployPlugin(_merkle.budget(), _one(_merkle, new PayBeneficiary()));

        bytes[] memory _data = new bytes[](1);
        _data[0] = abi.encode(alice, 1 ether, new bytes32[](0), address(0));
        _plugin.trigger(_data);

        assertEq(alice.balance, 1 ether);
    }

    function test_RevertWhen_RecipientRejectsEth() public {
        // An ERC20 contract has no receive(), so the native send fails inside the DAO
        CapitalPipelinePlugin _plugin =
            _deployPlugin(_deployBalanceBudget(ETH), _one(NO_ACTION, _deployRatio(address(tokenA))));

        vm.expectRevert(abi.encodeWithSelector(DAO.ActionFailed.selector, 0));
        _plugin.trigger(noData);
    }
}
