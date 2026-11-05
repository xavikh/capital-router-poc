// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {PluginRepo} from "@aragon/osx/framework/plugin/repo/PluginRepo.sol";
import {PluginRepoFactory} from "@aragon/osx/framework/plugin/repo/PluginRepoFactory.sol";
import {PluginRepoRegistry} from "@aragon/osx/framework/plugin/repo/PluginRepoRegistry.sol";
import {PluginSetupProcessor} from "@aragon/osx/framework/plugin/setup/PluginSetupProcessor.sol";
import {ENSSubdomainRegistrar} from "@aragon/osx/framework/utils/ens/ENSSubdomainRegistrar.sol";
import {CapitalPipelinePlugin} from "../src/CapitalPipelinePlugin.sol";
import {CapitalPipelinePluginSetup} from "../src/setup/CapitalPipelinePluginSetup.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {Install} from "../script/Install.s.sol";
import {Recipes} from "../script/Recipes.sol";
import {Fixture, METADATA_URIS} from "./helpers/Fixture.sol";
import {MockFiller} from "./mocks/MockFiller.sol";

/// @notice Deploy, publish and install through Aragon's own framework contracts, deployed locally
///         without ENS (the plugin repo is published with an empty subdomain)
contract InstallationTest is Fixture {
    PluginSetupProcessor internal psp;
    CapitalPipelinePluginSetup internal setup;
    PluginRepo internal repo;
    Install internal installer;

    function setUp() public override {
        super.setUp();

        PluginRepoRegistry _registry = PluginRepoRegistry(
            ProxyLib.deployUUPSProxy(
                address(new PluginRepoRegistry()),
                abi.encodeCall(PluginRepoRegistry.initialize, (IDAO(address(dao)), ENSSubdomainRegistrar(address(0))))
            )
        );
        PluginRepoFactory _factory = new PluginRepoFactory(_registry);
        dao.grant(address(_registry), address(_factory), _registry.REGISTER_PLUGIN_REPO_PERMISSION_ID());
        psp = new PluginSetupProcessor(_registry);

        Deploy _deploy = new Deploy();
        (, setup) = _deploy.deploy(dao, METADATA_URIS);
        repo = _deploy.publish(_factory, setup, "", manager, METADATA_URIS);
        installer = new Install();
    }

    function test_PublishesTheSetupAsVersionOneDotOne() public view {
        PluginRepo.Version memory _version = repo.getLatestVersion(1);

        assertEq(_version.pluginSetup, address(setup));
        assertEq(_version.tag.build, 1);
        assertEq(_version.buildMetadata, "ipfs://build");
        assertTrue(repo.isGranted(address(repo), manager, repo.MAINTAINER_PERMISSION_ID(), ""), "maintainer");
    }

    /// The proposal's three actions install a buy-and-burn flow, which then burns a fill's proceeds
    function test_DaoInstallsBuyAndBurnWithTheProposalActions() public {
        (address _plugin, Action[] memory _actions) = installer.install(psp, repo, address(dao), _buyAndBurnConfig());

        dao.grant(address(dao), address(dao), dao.ROOT_PERMISSION_ID()); // as Aragon's DAOFactory does
        dao.grant(address(dao), address(this), dao.EXECUTE_PERMISSION_ID()); // stands in for a passed proposal
        dao.execute(bytes32(0), _actions, 0);

        MockFiller _filler = new MockFiller(CapitalPipelinePlugin(_plugin));
        tokenB.mint(address(_filler), DEMAND);
        uint256 _supply = tokenB.totalSupply();
        vm.warp(block.timestamp + EPOCH);

        _filler.fill("");

        assertEq(tokenB.totalSupply(), _supply - DEMAND, "proceeds burned");
        assertEq(tokenB.balanceOf(address(dao)), DAO_B);
        assertFalse(dao.hasPermission(address(dao), address(psp), dao.ROOT_PERMISSION_ID(), ""), "ROOT revoked");
    }

    function test_RevertWhen_SomeoneElseAppliesTheInstallation() public {
        (, Action[] memory _actions) = installer.install(psp, repo, address(dao), _buyAndBurnConfig());

        vm.prank(alice);
        (bool _ok, bytes memory _reason) = _actions[1].to.call(_actions[1].data);

        assertFalse(_ok);
        assertEq(
            _reason,
            abi.encodeWithSelector(
                PluginSetupProcessor.SetupApplicationUnauthorized.selector,
                address(dao),
                alice,
                psp.APPLY_INSTALLATION_PERMISSION_ID()
            )
        );
    }

    function test_ConfigBuildsTheSameRecipe() public view {
        Recipes.Stream memory _stream = Recipes.Stream(IERC20(tokenA), RATE, 0, EPOCH);
        Recipes.Swap memory _swap = Recipes.Swap(IERC20(tokenB), DEMAND, MIN_PRICE);

        assertEq(
            abi.encode(installer.recipe(_buyAndBurnConfig())), abi.encode(Recipes.buyAndBurn(manager, _stream, _swap))
        );
    }

    function test_EveryExampleConfigBuildsItsRecipe() public view {
        assertEq(installer.recipe(_example("buy-and-burn")).components.length, 3);
        assertEq(installer.recipe(_example("buyback")).components.length, 4);
        assertEq(installer.recipe(_example("merkle-claim")).components.length, 3);
        assertEq(installer.recipe(_example("payroll")).components.length, 3);
    }

    function test_RevertWhen_TheRecipeIsUnknown() public {
        vm.expectRevert(abi.encodeWithSelector(Install.UnknownRecipe.selector, "swapEverything"));
        installer.recipe('{"recipe":"swapEverything","manager":"0x0000000000000000000000000000000000000001"}');
    }

    // Helpers

    function _buyAndBurnConfig() internal view returns (string memory) {
        return string.concat(
            '{"recipe":"buyAndBurn","manager":"',
            vm.toString(manager),
            '","stream":{"token":"',
            vm.toString(address(tokenA)),
            '","amountPerEpoch":"',
            vm.toString(RATE),
            '","maxBudget":"0","epochInterval":"',
            vm.toString(EPOCH),
            '"},"swap":{"demandedToken":"',
            vm.toString(address(tokenB)),
            '","demandPerFill":"',
            vm.toString(DEMAND),
            '","minDemandedPerOffered":"',
            vm.toString(MIN_PRICE),
            '"}}'
        );
    }

    function _example(string memory _name) internal view returns (string memory) {
        return vm.readFile(string.concat("installs/", _name, ".example.json"));
    }
}
