// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    DaoAuthorizableUpgradeable
} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizableUpgradeable.sol";
import {IPluginSetup} from "@aragon/osx-commons-contracts/src/plugin/setup/IPluginSetup.sol";
import {PermissionLib} from "@aragon/osx-commons-contracts/src/permission/PermissionLib.sol";
import {CapitalPipelinePluginSetup} from "../src/setup/CapitalPipelinePluginSetup.sol";
import {CapitalPipelinePlugin} from "../src/CapitalPipelinePlugin.sol";
import {ComponentRegistry} from "../src/registry/ComponentRegistry.sol";
import {INodeAction} from "../src/interfaces/INodeAction.sol";
import {
    TRIGGER_PERMISSION_ID,
    CONFIGURE_PERMISSION_ID,
    MANAGER_PERMISSION_ID,
    CHECKPOINT_PERMISSION_ID
} from "../src/lib/constants.sol";
import {DAO_REF, PLUGIN_REF, ref} from "../src/lib/placeholders.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {Recipes} from "../script/Recipes.sol";
import {Fixture, METADATA_URIS} from "./helpers/Fixture.sol";
import {MockFiller} from "./mocks/MockFiller.sol";

contract CapitalPipelinePluginSetupTest is Fixture {
    ComponentRegistry internal registry;
    CapitalPipelinePluginSetup internal setup;

    function setUp() public override {
        super.setUp();
        (registry, setup) = new Deploy().deploy(dao, METADATA_URIS);
    }

    // =========================================================================================
    // Recipes
    // =========================================================================================

    function test_BuyAndBurnBurnsEverything() public {
        (CapitalPipelinePlugin _plugin,) = _install(Recipes.buyAndBurn(manager, _stream(), _swap()));
        MockFiller _filler = _newFiller(_plugin);
        uint256 _supply = tokenB.totalSupply();

        _filler.fill("");

        assertEq(tokenB.totalSupply(), _supply - DEMAND);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B);
    }

    function test_BuybackBurnsAndPaysTheFee() public {
        (CapitalPipelinePlugin _plugin,) = _install(_buyback());
        MockFiller _filler = _newFiller(_plugin);
        uint256 _supply = tokenB.totalSupply();

        _filler.fill("");

        assertEq(tokenB.totalSupply(), _supply - 950 ether);
        assertEq(tokenB.balanceOf(fee), 50 ether);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B);
    }

    function test_MerkleClaimPaysTheAccount() public {
        bytes32 _aliceLeaf = _leafHash(alice, 10 ether);
        bytes32 _bobLeaf = _leafHash(bob, 30 ether);
        (CapitalPipelinePlugin _plugin,) =
            _install(Recipes.merkleClaim(manager, IERC20(tokenA), _hashPair(_aliceLeaf, _bobLeaf)));

        bytes32[] memory _proof = new bytes32[](1);
        _proof[0] = _bobLeaf;
        bytes[] memory _data = new bytes[](2);
        _data[0] = abi.encode(alice, 10 ether, _proof, address(0));

        vm.prank(alice);
        _plugin.trigger(_data);

        assertEq(tokenA.balanceOf(alice), 10 ether);
    }

    function test_PayrollPaysEachRecipient() public {
        (CapitalPipelinePlugin _plugin,) = _install(Recipes.payroll(manager, _stream(), _pair(alice, bob), _weights()));
        vm.warp(block.timestamp + EPOCH);

        _plugin.trigger(noData);

        assertEq(tokenA.balanceOf(alice), 9.5 ether);
        assertEq(tokenA.balanceOf(bob), 0.5 ether);
    }

    // =========================================================================================
    // Components and permissions
    // =========================================================================================

    function test_EveryComponentIsAFreshCloneOfTheDao() public {
        (, address[] memory _first) = _install(_buyback());
        (, address[] memory _second) = _install(_buyback());

        for (uint256 i; i < _first.length; ++i) {
            assertTrue(_first[i] != _second[i], "a new clone per install");
            assertEq(address(DaoAuthorizableUpgradeable(_first[i]).dao()), address(dao));
        }
        assertTrue(_first[1] != registry.implementation(Recipes.OPEN_FILL), "never the implementation");
    }

    function test_GrantsTheRecipePermissions() public {
        (CapitalPipelinePlugin _plugin, address[] memory _helpers) = _install(_buyback());

        _assertPermissions(address(_plugin), _helpers, true);
        assertFalse(
            dao.hasPermission(address(_plugin), manager, CONFIGURE_PERMISSION_ID, ""), "manager can't set the flow"
        );
    }

    function test_UninstallRevokesEverything() public {
        CapitalPipelinePluginSetup.InstallParams memory _params = _buyback();
        (CapitalPipelinePlugin _plugin, address[] memory _helpers) = _install(_params);

        dao.applyMultiTargetPermissions(_prepareUninstall(_plugin, _helpers, _params.grants));

        _assertPermissions(address(_plugin), _helpers, false);
    }

    function test_RevertWhen_UninstallGrantsDiffer() public {
        CapitalPipelinePluginSetup.InstallParams memory _params = _buyback();
        (CapitalPipelinePlugin _plugin, address[] memory _helpers) = _install(_params);
        CapitalPipelinePluginSetup.Grant[] memory _fewer = new CapitalPipelinePluginSetup.Grant[](1);
        _fewer[0] = _params.grants[0];

        vm.expectRevert(CapitalPipelinePluginSetup.GrantsMismatch.selector);
        _prepareUninstall(_plugin, _helpers, _fewer);
    }

    // =========================================================================================
    // Rejected recipes
    // =========================================================================================

    function test_RevertWhen_AComponentIsNotRegistered() public {
        CapitalPipelinePluginSetup.InstallParams memory _params = _buyback();
        _params.components[0].id = "Unknown@1";

        _expectInstallRevert(
            _params, abi.encodeWithSelector(ComponentRegistry.UnknownComponent.selector, bytes32("Unknown@1"))
        );
    }

    function test_RevertWhen_AReferenceIsUnknown() public {
        CapitalPipelinePluginSetup.InstallParams memory _params = _buyback();
        _params.nodes[1].action = INodeAction(ref(9));

        _expectInstallRevert(_params, abi.encodeWithSelector(CapitalPipelinePluginSetup.UnknownReference.selector, 9));
    }

    function test_RevertWhen_AGrantTargetsTheDao() public {
        CapitalPipelinePluginSetup.InstallParams memory _params = _buyback();
        _params.grants[0] = CapitalPipelinePluginSetup.Grant(DAO_REF, manager, keccak256("ROOT_PERMISSION"));

        _expectInstallRevert(
            _params, abi.encodeWithSelector(CapitalPipelinePluginSetup.GrantOutsideInstallation.selector, DAO_REF)
        );
    }

    function test_RevertWhen_AGrantTargetsAnOutsideContract() public {
        CapitalPipelinePluginSetup.InstallParams memory _params = _buyback();
        _params.grants[0] = CapitalPipelinePluginSetup.Grant(address(tokenA), manager, MANAGER_PERMISSION_ID);

        _expectInstallRevert(
            _params,
            abi.encodeWithSelector(CapitalPipelinePluginSetup.GrantOutsideInstallation.selector, address(tokenA))
        );
    }

    function test_RevertWhen_AGrantGivesConfigure() public {
        CapitalPipelinePluginSetup.InstallParams memory _params = _buyback();
        _params.grants[1] = CapitalPipelinePluginSetup.Grant(PLUGIN_REF, manager, CONFIGURE_PERMISSION_ID);

        _expectInstallRevert(
            _params,
            abi.encodeWithSelector(CapitalPipelinePluginSetup.ReservedPermission.selector, CONFIGURE_PERMISSION_ID)
        );
    }

    // =========================================================================================
    // Helpers
    // =========================================================================================

    function _install(CapitalPipelinePluginSetup.InstallParams memory _params)
        internal
        returns (CapitalPipelinePlugin _plugin, address[] memory _helpers)
    {
        (address _pluginAddress, IPluginSetup.PreparedSetupData memory _prepared) =
            setup.prepareInstallation(address(dao), abi.encode(_params));
        dao.applyMultiTargetPermissions(_prepared.permissions);

        return (CapitalPipelinePlugin(_pluginAddress), _prepared.helpers);
    }

    function _expectInstallRevert(CapitalPipelinePluginSetup.InstallParams memory _params, bytes memory _error)
        internal
    {
        bytes memory _data = abi.encode(_params);
        vm.expectRevert(_error);
        setup.prepareInstallation(address(dao), _data);
    }

    function _prepareUninstall(
        CapitalPipelinePlugin _plugin,
        address[] memory _helpers,
        CapitalPipelinePluginSetup.Grant[] memory _grants
    ) internal view returns (PermissionLib.MultiTargetPermission[] memory) {
        return setup.prepareUninstallation(
            address(dao),
            IPluginSetup.SetupPayload({plugin: address(_plugin), currentHelpers: _helpers, data: abi.encode(_grants)})
        );
    }

    /// @dev Swap 10 A for 1,000 B, then burn 95% and pay 5% to the fee address
    function _buyback() internal view returns (CapitalPipelinePluginSetup.InstallParams memory) {
        return Recipes.buyback(manager, _stream(), _swap(), fee, 50_000);
    }

    function _stream() internal view returns (Recipes.Stream memory) {
        return Recipes.Stream({token: IERC20(tokenA), amountPerEpoch: RATE, maxBudget: 0, epochInterval: EPOCH});
    }

    function _swap() internal view returns (Recipes.Swap memory) {
        return Recipes.Swap({demandedToken: IERC20(tokenB), demandPerFill: DEMAND, minDemandedPerOffered: MIN_PRICE});
    }

    function _pair(address _a, address _b) internal pure returns (address[] memory _recipients) {
        _recipients = new address[](2);
        (_recipients[0], _recipients[1]) = (_a, _b);
    }

    function _weights() internal pure returns (uint32[] memory _shares) {
        _shares = new uint32[](2);
        (_shares[0], _shares[1]) = (950_000, 50_000);
    }

    function _newFiller(CapitalPipelinePlugin _plugin) internal returns (MockFiller _mock) {
        _mock = new MockFiller(_plugin);
        tokenB.mint(address(_mock), 1_000_000 ether);
        vm.warp(block.timestamp + EPOCH);
    }

    function _leafHash(address _account, uint256 _cumulative) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(_account, _cumulative))));
    }

    function _hashPair(bytes32 _a, bytes32 _b) internal pure returns (bytes32) {
        return _a < _b ? keccak256(abi.encode(_a, _b)) : keccak256(abi.encode(_b, _a));
    }

    function _assertPermissions(address _plugin, address[] memory _helpers, bool _expected) internal view {
        (address _budget, address _action) = (_helpers[0], _helpers[1]);

        assertEq(dao.hasPermission(address(dao), _plugin, dao.EXECUTE_PERMISSION_ID(), ""), _expected, "execute");
        assertEq(dao.hasPermission(_plugin, address(0xA11CE), TRIGGER_PERMISSION_ID, ""), _expected, "trigger");
        assertEq(dao.hasPermission(_plugin, address(dao), CONFIGURE_PERMISSION_ID, ""), _expected, "configure");
        assertEq(dao.hasPermission(_plugin, manager, MANAGER_PERMISSION_ID, ""), _expected, "manage plugin");
        assertEq(dao.hasPermission(_budget, manager, MANAGER_PERMISSION_ID, ""), _expected, "manage budget");
        assertEq(dao.hasPermission(_action, manager, MANAGER_PERMISSION_ID, ""), _expected, "manage action");
        assertEq(dao.hasPermission(_budget, address(dao), CHECKPOINT_PERMISSION_ID, ""), _expected, "dao checkpoint");
        assertEq(dao.hasPermission(_budget, _action, CHECKPOINT_PERMISSION_ID, ""), _expected, "action checkpoint");
    }
}
