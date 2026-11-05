// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {ComponentRegistry} from "../src/registry/ComponentRegistry.sol";
import {FundedStreamBudget} from "../src/budgets/FundedStreamBudget.sol";
import {BalanceBudget} from "../src/budgets/BalanceBudget.sol";
import {OpenFillAction} from "../src/actions/OpenFillAction.sol";
import {MerkleClaimAction} from "../src/actions/MerkleClaimAction.sol";
import {TransferAction} from "../src/actions/TransferAction.sol";
import {TransferToBeneficiaryAction} from "../src/actions/TransferToBeneficiaryAction.sol";
import {BurnAction} from "../src/actions/BurnAction.sol";
import {KeepAction} from "../src/actions/KeepAction.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {Recipes} from "../script/Recipes.sol";
import {METADATA_URIS} from "./helpers/Fixture.sol";

/// @notice The metadata files describe the code they're registered with
contract MetadataTest is Test {
    function test_EachFileMatchesItsInitializer() public view {
        _assertMatches("FundedStreamBudget", FundedStreamBudget.initialize.selector);
        _assertMatches("BalanceBudget", BalanceBudget.initialize.selector);
        _assertMatches("OpenFillAction", OpenFillAction.initialize.selector);
        _assertMatches("MerkleClaimAction", MerkleClaimAction.initialize.selector);
        _assertMatches("TransferAction", TransferAction.initialize.selector);
        _assertMatches("TransferToBeneficiaryAction", TransferToBeneficiaryAction.initialize.selector);
        _assertMatches("BurnAction", BurnAction.initialize.selector);
        _assertMatches("KeepAction", KeepAction.initialize.selector);
    }

    function test_UrisFileListsEveryComponent() public view {
        string memory _uris = vm.readFile("metadata/uris.json");
        string[] memory _names = vm.parseJsonKeys(_uris, "$");

        assertEq(_names.length, 8);
        for (uint256 i; i < _names.length; ++i) {
            assertTrue(vm.exists(string.concat("metadata/components/", _names[i], ".json")), _names[i]);
        }
    }

    function test_DeployRegistersEachComponentWithItsLink() public {
        (ComponentRegistry _registry,) = new Deploy().deploy(IDAO(address(this)), METADATA_URIS);

        (, bytes memory _metadata) = _registry.entries(Recipes.OPEN_FILL);
        assertEq(_metadata, "ipfs://OpenFillAction");
        (, _metadata) = _registry.entries(Recipes.KEEP);
        assertEq(_metadata, "ipfs://KeepAction");
    }

    function test_RevertWhen_AComponentHasNoLink() public {
        Deploy _deploy = new Deploy();
        string memory _uris = vm.replace(METADATA_URIS, "ipfs://KeepAction", "");

        vm.expectRevert(abi.encodeWithSelector(Deploy.MissingMetadata.selector, "KeepAction"));
        _deploy.deploy(IDAO(address(this)), _uris);
    }

    /// @dev The input types in `metadata/components/<name>.json` give the initializer's selector
    function _assertMatches(string memory _name, bytes4 _selector) internal view {
        string memory _json = vm.readFile(string.concat("metadata/components/", _name, ".json"));
        assertEq(vm.parseJsonString(_json, ".name"), _name, "name");

        string memory _signature = "initialize(";
        for (uint256 i; vm.keyExistsJson(_json, _input(i)); ++i) {
            string memory _type = vm.parseJsonString(_json, string.concat(_input(i), ".type"));
            _signature = string.concat(_signature, i == 0 ? "" : ",", _type);
        }
        assertEq(bytes4(keccak256(bytes(string.concat(_signature, ")")))), _selector, _name);
    }

    function _input(uint256 _index) internal pure returns (string memory) {
        return string.concat(".initialize.inputs[", vm.toString(_index), "]");
    }
}
