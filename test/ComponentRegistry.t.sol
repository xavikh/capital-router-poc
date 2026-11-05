// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {DaoUnauthorized} from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import {ComponentRegistry} from "../src/registry/ComponentRegistry.sol";
import {KeepAction} from "../src/actions/KeepAction.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {Recipes} from "../script/Recipes.sol";
import {Fixture} from "./helpers/Fixture.sol";

contract ComponentRegistryTest is Fixture {
    ComponentRegistry internal registry;
    address internal newKeep;

    function setUp() public override {
        super.setUp();
        (registry,) = new Deploy().deploy(dao);
        newKeep = address(new KeepAction());
        dao.grant(address(registry), manager, registry.REGISTER_PERMISSION_ID());
    }

    function test_RegistersTheInitialComponents() public view {
        address _openFill = registry.implementation(Recipes.OPEN_FILL);
        assertGt(_openFill.code.length, 0);
    }

    function test_ManagingDaoRegistersMore() public {
        vm.prank(manager);
        registry.register(ComponentRegistry.Registration("KeepAction@2", newKeep, "ipfs://keep"));

        assertEq(registry.implementation("KeepAction@2"), newKeep);
        (, bytes memory _metadata) = registry.entries("KeepAction@2");
        assertEq(_metadata, "ipfs://keep");
    }

    function test_RevertWhen_TheIdIsTaken() public {
        vm.expectRevert(abi.encodeWithSelector(ComponentRegistry.AlreadyRegistered.selector, Recipes.KEEP));
        vm.prank(manager);
        registry.register(ComponentRegistry.Registration(Recipes.KEEP, newKeep, ""));
    }

    function test_RevertWhen_RegisterUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector,
                address(dao),
                address(registry),
                address(this),
                registry.REGISTER_PERMISSION_ID()
            )
        );
        registry.register(ComponentRegistry.Registration("KeepAction@2", newKeep, ""));
    }

    function test_RevertWhen_TheImplementationHasNoCode() public {
        vm.expectRevert(abi.encodeWithSelector(ComponentRegistry.NotAContract.selector, address(0xBEEF)));
        vm.prank(manager);
        registry.register(ComponentRegistry.Registration("KeepAction@2", address(0xBEEF), ""));
    }

    function test_RevertWhen_TheIdIsUnknown() public {
        vm.expectRevert(abi.encodeWithSelector(ComponentRegistry.UnknownComponent.selector, bytes32("Unknown@1")));
        registry.implementation("Unknown@1");
    }
}
