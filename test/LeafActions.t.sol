// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {CapitalPipelinePlugin} from "../src/CapitalPipelinePlugin.sol";
import {BalanceBudget} from "../src/budgets/BalanceBudget.sol";
import {TransferAction} from "../src/actions/TransferAction.sol";
import {TransferBase} from "../src/actions/base/TransferBase.sol";
import {TransferToBeneficiaryAction} from "../src/actions/TransferToBeneficiaryAction.sol";
import {BurnAction} from "../src/actions/BurnAction.sol";
import {KeepAction} from "../src/actions/KeepAction.sol";
import {Input, Movement} from "../src/lib/types.sol";
import {NATIVE} from "../src/lib/tokens.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {FalseReturnToken} from "./mocks/BadComponents.sol";

contract LeafActionsTest is Fixture {
    BalanceBudget internal budget;

    function setUp() public override {
        super.setUp();
        budget = _deployBalanceBudget(tokenA); // 100 A
    }

    // Transfer

    function test_TransferSendsTheWholeInput() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _one(_deployTransfer(alice)));

        _plugin.trigger(noData);

        assertEq(tokenA.balanceOf(alice), DAO_A);
        assertEq(tokenA.balanceOf(address(dao)), 0);
    }

    function test_TransferPostconditionMeasuresTheRecipient() public {
        TransferAction _transfer = _deployTransfer(alice);
        Movement memory _movement = Movement(tokenA, 7 ether, tokenA, 0, address(0));

        Action[] memory _checks = _transfer.postconditions(address(0), _movement);

        assertEq(_checks.length, 1);
        assertEq(_checks[0].to, address(_transfer));
        assertEq(_checks[0].data, abi.encodeCall(TransferBase.assertReceived, (IERC20(tokenA), alice, 7 ether)));
    }

    function test_RevertWhen_ATransferSilentlyFails() public {
        FalseReturnToken _token = new FalseReturnToken(0);
        _token.mint(address(dao), 100 ether);
        CapitalPipelinePlugin _plugin =
            _deployPlugin(_deployBalanceBudget(IERC20(address(_token))), _one(_deployTransfer(alice)));

        // Action 0 is the transfer (returns false), action 1 the postcondition, which catches it
        vm.expectRevert(abi.encodeWithSelector(DAO.ActionFailed.selector, 1));
        _plugin.trigger(noData);
    }

    function test_RevertWhen_TransferRecipientIsUnset() public {
        TransferAction _transfer = TransferAction(ProxyLib.deployMinimalProxy(address(new TransferAction()), ""));

        vm.expectRevert(TransferAction.NoRecipient.selector);
        _transfer.initialize(dao, address(0));
    }

    // Transfer to beneficiary

    function test_RevertWhen_ThereIsNoBeneficiary() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _one(toBeneficiary));

        vm.expectRevert(TransferToBeneficiaryAction.NoBeneficiary.selector);
        _plugin.trigger(noData);
    }

    // Burn

    function test_BurnLowersTheSupply() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _one(burn));
        uint256 _supply = tokenA.totalSupply();

        _plugin.trigger(noData);

        assertEq(tokenA.totalSupply(), _supply - DAO_A);
    }

    function test_RevertWhen_BurningNativeEth() public {
        vm.expectRevert(BurnAction.CannotBurnNative.selector);
        burn.preconditions(address(0), Input(NATIVE, 1 ether, address(0)));
    }

    // Keep

    function test_KeepLeavesTheInputInTheDao() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _one(keep));

        _plugin.trigger(noData);

        assertEq(tokenA.balanceOf(address(dao)), DAO_A);
    }

    // Branches of transfers

    /// capital-router checks each transfer against a snapshot taken before any of them, so a
    /// recipient listed twice can miss a silent failure. Here every leaf checks its own receipt.
    function test_RevertWhen_ARepeatedRecipientMissesATransfer() public {
        FalseReturnToken _token = new FalseReturnToken(1); // the second transfer silently fails
        _token.mint(address(dao), 100 ether);
        CapitalPipelinePlugin _plugin = _deployPlugin(
            _deployBalanceBudget(IERC20(address(_token))),
            _fork(NO_ACTION, 500_000, _deployTransfer(alice), 500_000, _deployTransfer(alice))
        );

        // In the second leaf, action 0 is the transfer (returns false), action 1 the postcondition
        vm.expectRevert(abi.encodeWithSelector(DAO.ActionFailed.selector, 1));
        _plugin.trigger(noData);
    }

    // Implementations

    function test_RevertWhen_InitializingAnImplementation() public {
        BurnAction _burn = new BurnAction();
        KeepAction _keep = new KeepAction();
        TransferToBeneficiaryAction _toBeneficiary = new TransferToBeneficiaryAction();

        vm.expectRevert("Initializable: contract is already initialized");
        _burn.initialize(dao);
        vm.expectRevert("Initializable: contract is already initialized");
        _keep.initialize(dao);
        vm.expectRevert("Initializable: contract is already initialized");
        _toBeneficiary.initialize(dao);
    }
}

contract BalanceBudgetTest is Fixture {
    function test_AvailableIsTheDaoBalance() public {
        BalanceBudget _budget = _deployBalanceBudget(tokenA);

        assertEq(_budget.available(), DAO_A);
        assertEq(address(_budget.token()), address(tokenA));
    }

    function test_CommitsNothing() public {
        assertEq(_deployBalanceBudget(tokenA).commitActions().length, 0);
    }

    function test_RevertWhen_TokenHasNoCode() public {
        BalanceBudget _budget = BalanceBudget(ProxyLib.deployMinimalProxy(address(new BalanceBudget()), ""));

        vm.expectRevert(BalanceBudget.InvalidToken.selector);
        _budget.initialize(dao, IERC20(address(0xBEEF)));
    }

    function test_RevertWhen_TokenIsUnset() public {
        BalanceBudget _budget = BalanceBudget(ProxyLib.deployMinimalProxy(address(new BalanceBudget()), ""));

        vm.expectRevert(BalanceBudget.InvalidToken.selector);
        _budget.initialize(dao, IERC20(address(0)));
    }
}
