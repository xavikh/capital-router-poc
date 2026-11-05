// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {PluginRepo} from "@aragon/osx/framework/plugin/repo/PluginRepo.sol";
import {PluginRepoFactory} from "@aragon/osx/framework/plugin/repo/PluginRepoFactory.sol";
import {ComponentRegistry} from "../../src/registry/ComponentRegistry.sol";
import {CapitalPipelinePluginSetup} from "../../src/setup/CapitalPipelinePluginSetup.sol";
import {ERC20Mock} from "../../test/mocks/ERC20Mock.sol";
import {Deploy} from "../Deploy.s.sol";
import {Recipes} from "../Recipes.sol";
import {PlaygroundFiller} from "./PlaygroundFiller.sol";

/// @notice Sets up a playground on an Anvil fork of Sepolia, where Aragon OSx v1.4.0 is deployed:
///         a DAO controlled by the first Anvil account, two test tokens, a funded filler, and the
///         whole system published to an Aragon plugin repo. Writes every address to
///         `playground/deployment.json`, which the playground UI reads.
/// @dev Run through `playground/up.sh`, or:
///      `forge script script/playground/Playground.s.sol --sig "play()" --rpc-url http://127.0.0.1:8545 --broadcast`
contract Playground is Deploy {
    /// @dev Aragon OSx v1.4.0 on Sepolia, from aragon/osx-commons configs/src/deployments/json/sepolia.json
    PluginRepoFactory internal constant PLUGIN_REPO_FACTORY =
        PluginRepoFactory(0x399Ce2a71ef78bE6890EB628384dD09D4382a7f0);
    address internal constant PLUGIN_SETUP_PROCESSOR = 0xC24188a73dc09aA7C721f96Ad8857B469C01dC9f;

    /// @dev The first Anvil account. Its key is public: never use it outside a local chain.
    uint256 internal constant ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    /// @dev The UI reads metadata from the local files, so the links only need to be non-empty
    string internal constant LINKS = '{"release":"ipfs://playground","build":"ipfs://playground","components":{'
        '"FundedStreamBudget":"ipfs://playground","BalanceBudget":"ipfs://playground",'
        '"OpenFillAction":"ipfs://playground","MerkleClaimAction":"ipfs://playground",'
        '"TransferAction":"ipfs://playground","TransferToBeneficiaryAction":"ipfs://playground",'
        '"BurnAction":"ipfs://playground","KeepAction":"ipfs://playground"}}';

    struct Deployment {
        address account;
        DAO dao;
        ERC20Mock tokenA;
        ERC20Mock tokenB;
        PlaygroundFiller filler;
        ComponentRegistry registry;
        CapitalPipelinePluginSetup setup;
        PluginRepo repo;
    }

    function play() external {
        uint256 _key = vm.envOr("PRIVATE_KEY", ANVIL_KEY);
        Deployment memory _d;
        _d.account = vm.addr(_key);
        uint256 _startBlock = block.number;

        vm.startBroadcast(_key);
        _d.dao = _deployDao(_d.account);
        _d.tokenA = new ERC20Mock("Token A", "A");
        _d.tokenB = new ERC20Mock("Token B", "B");
        _d.filler = new PlaygroundFiller();
        _d.tokenA.mint(address(_d.dao), 1_000_000 ether);
        _d.tokenB.mint(address(_d.filler), 1_000_000_000 ether);
        (_d.registry, _d.setup) = deploy(_d.dao, LINKS);
        string memory _subdomain = string.concat("capital-pipeline-", vm.toString(block.timestamp));
        _d.repo = publish(PLUGIN_REPO_FACTORY, _d.setup, _subdomain, _d.account, LINKS);
        vm.stopBroadcast();

        _write(_d, _startBlock);
    }

    /// @dev A DAO the account controls directly: it holds ROOT and EXECUTE, so it can run any
    ///      proposal's actions itself. The DAO also holds ROOT on itself, as Aragon's DAOFactory sets up.
    function _deployDao(address _account) internal returns (DAO _dao) {
        _dao = DAO(
            payable(ProxyLib.deployUUPSProxy(
                    address(new DAO()), abi.encodeCall(DAO.initialize, ("", _account, address(0), ""))
                ))
        );
        _dao.grant(address(_dao), address(_dao), _dao.ROOT_PERMISSION_ID());
        _dao.grant(address(_dao), _account, _dao.EXECUTE_PERMISSION_ID());
    }

    function _write(Deployment memory _d, uint256 _startBlock) internal {
        string memory _components = "components";
        bytes32[8] memory _ids = [
            Recipes.FUNDED_STREAM_BUDGET,
            Recipes.BALANCE_BUDGET,
            Recipes.OPEN_FILL,
            Recipes.MERKLE_CLAIM,
            Recipes.TRANSFER,
            Recipes.TRANSFER_TO_BENEFICIARY,
            Recipes.BURN,
            Recipes.KEEP
        ];
        string memory _componentsJson;
        for (uint256 i; i < _ids.length; ++i) {
            _componentsJson = vm.serializeAddress(_components, _idString(_ids[i]), _d.registry.implementation(_ids[i]));
        }

        string memory _root = "deployment";
        vm.serializeUint(_root, "chainId", block.chainid);
        vm.serializeUint(_root, "startBlock", _startBlock);
        vm.serializeAddress(_root, "account", _d.account);
        vm.serializeAddress(_root, "dao", address(_d.dao));
        vm.serializeAddress(_root, "tokenA", address(_d.tokenA));
        vm.serializeAddress(_root, "tokenB", address(_d.tokenB));
        vm.serializeAddress(_root, "filler", address(_d.filler));
        vm.serializeAddress(_root, "registry", address(_d.registry));
        vm.serializeAddress(_root, "setup", address(_d.setup));
        vm.serializeAddress(_root, "pluginRepo", address(_d.repo));
        vm.serializeAddress(_root, "pluginSetupProcessor", PLUGIN_SETUP_PROCESSOR);
        string memory _json = vm.serializeString(_root, "components", _componentsJson);
        vm.writeJson(_json, "playground/deployment.json");
    }

    /// @dev "OpenFillAction@1" from its bytes32 id
    function _idString(bytes32 _id) internal pure returns (string memory) {
        uint256 _length;
        while (_length < 32 && _id[_length] != 0) ++_length;
        bytes memory _out = new bytes(_length);
        for (uint256 i; i < _length; ++i) {
            _out[i] = _id[i];
        }
        return string(_out);
    }
}
