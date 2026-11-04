// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {FundedStreamBudget} from "../../src/budgets/FundedStreamBudget.sol";
import {BalanceBudget} from "../../src/budgets/BalanceBudget.sol";
import {RatioSplitter} from "../../src/splitters/RatioSplitter.sol";
import {OpenFillAction} from "../../src/actions/OpenFillAction.sol";
import {MerkleClaimAction} from "../../src/actions/MerkleClaimAction.sol";
import {CapitalPipelinePlugin} from "../../src/CapitalPipelinePlugin.sol";
import {IBudget} from "../../src/interfaces/IBudget.sol";
import {IStageAction} from "../../src/interfaces/IStageAction.sol";
import {ISplitter} from "../../src/interfaces/ISplitter.sol";
import {Stage} from "../../src/lib/types.sol";
import {
    MANAGER_PERMISSION_ID,
    CHECKPOINT_PERMISSION_ID,
    TRIGGER_PERMISSION_ID,
    CONFIGURE_PERMISSION_ID
} from "../../src/lib/constants.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

/// @notice A DAO holding the offered token A and some pre-existing demanded token B.
///         The test contract is the DAO's ROOT, so it can grant permissions directly.
abstract contract Fixture is Test {
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;
    address internal constant ANY_ADDR = address(type(uint160).max);
    IStageAction internal constant NO_ACTION = IStageAction(address(0));
    ISplitter internal constant NO_SPLITTER = ISplitter(address(0));

    uint256 internal constant DAO_A = 100 ether; // offered token held by the DAO
    uint256 internal constant DAO_B = 500 ether; // pre-existing demanded token: must never be spent
    uint256 internal constant RATE = 10 ether; // offer growth per epoch
    uint256 internal constant EPOCH = 1 days;
    uint256 internal constant DEMAND = 1000 ether; // B demanded per fill
    uint256 internal constant MIN_PRICE = 50 ether; // 50 B per A, 1e18-scaled → maxOffered = 20 A

    address internal manager = makeAddr("manager");
    address internal fee = makeAddr("fee");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    DAO internal dao;
    ERC20Mock internal tokenA;
    ERC20Mock internal tokenB;
    bytes[] internal noData;

    function setUp() public virtual {
        vm.warp(1_000_000);

        dao = DAO(
            payable(ProxyLib.deployUUPSProxy(
                    address(new DAO()), abi.encodeCall(DAO.initialize, ("", address(this), address(0), ""))
                ))
        );

        tokenA = new ERC20Mock("Offered", "A");
        tokenB = new ERC20Mock("Demanded", "B");
        tokenA.mint(address(dao), DAO_A);
        tokenB.mint(address(dao), DAO_B);
    }

    // Budgets

    /// @dev Deploy after funding the DAO: the budget records the balance it sees at init
    function _deployBudget(uint256 _rate, uint256 _maxBudget) internal returns (FundedStreamBudget _budget) {
        _budget = FundedStreamBudget(
            ProxyLib.deployMinimalProxy(
                address(new FundedStreamBudget()),
                abi.encodeCall(FundedStreamBudget.initialize, (dao, tokenA, _rate, _maxBudget, EPOCH))
            )
        );
        dao.grant(address(_budget), manager, MANAGER_PERMISSION_ID);
        dao.grant(address(_budget), address(dao), CHECKPOINT_PERMISSION_ID);
    }

    function _deployBalanceBudget(IERC20 _token) internal returns (BalanceBudget _budget) {
        _budget = BalanceBudget(
            ProxyLib.deployMinimalProxy(
                address(new BalanceBudget()), abi.encodeCall(BalanceBudget.initialize, (dao, _token))
            )
        );
    }

    // Splitters

    /// @dev 95% to the burn address, 5% to the fee address
    function _deploySplitter() internal returns (RatioSplitter) {
        return _deployRatio(BURN, 950_000, fee, 50_000);
    }

    function _deployRatio(address _a, uint32 _ratioA, address _b, uint32 _ratioB) internal returns (RatioSplitter) {
        address[] memory _recipients = new address[](2);
        (_recipients[0], _recipients[1]) = (_a, _b);
        uint32[] memory _ratios = new uint32[](2);
        (_ratios[0], _ratios[1]) = (_ratioA, _ratioB);
        return _deployRatio(_recipients, _ratios);
    }

    /// @dev 100% to one recipient
    function _deployRatio(address _recipient) internal returns (RatioSplitter) {
        address[] memory _recipients = new address[](1);
        _recipients[0] = _recipient;
        uint32[] memory _ratios = new uint32[](1);
        _ratios[0] = 1_000_000;
        return _deployRatio(_recipients, _ratios);
    }

    function _deployRatio(address[] memory _recipients, uint32[] memory _ratios)
        internal
        returns (RatioSplitter _splitter)
    {
        _splitter = RatioSplitter(
            ProxyLib.deployMinimalProxy(
                address(new RatioSplitter()), abi.encodeCall(RatioSplitter.initialize, (dao, _recipients, _ratios))
            )
        );
        dao.grant(address(_splitter), manager, MANAGER_PERMISSION_ID);
    }

    // Actions

    /// @dev Bound to `_budget`, which it may restart when its price terms change
    function _deployAction(FundedStreamBudget _budget) internal returns (OpenFillAction _action) {
        _action = OpenFillAction(
            ProxyLib.deployMinimalProxy(
                address(new OpenFillAction()),
                abi.encodeCall(OpenFillAction.initialize, (dao, _budget, tokenB, DEMAND, MIN_PRICE))
            )
        );
        dao.grant(address(_action), manager, MANAGER_PERMISSION_ID);
        dao.grant(address(_budget), address(_action), CHECKPOINT_PERMISSION_ID);
    }

    function _deployMerkle(IBudget _budget, bytes32 _root) internal returns (MerkleClaimAction _merkle) {
        _merkle = MerkleClaimAction(
            ProxyLib.deployMinimalProxy(
                address(new MerkleClaimAction()), abi.encodeCall(MerkleClaimAction.initialize, (dao, _budget, _root))
            )
        );
        dao.grant(address(_merkle), manager, MANAGER_PERMISSION_ID);
    }

    // Plugin

    /// @dev Same grants as CapitalPipelinePluginSetup: anyone triggers, the DAO configures, the manager pauses
    function _deployPlugin(IBudget _budget, Stage[] memory _flow) internal returns (CapitalPipelinePlugin _plugin) {
        _plugin = CapitalPipelinePlugin(
            ProxyLib.deployMinimalProxy(
                address(new CapitalPipelinePlugin()),
                abi.encodeCall(CapitalPipelinePlugin.initialize, (dao, _budget, _flow))
            )
        );
        dao.grant(address(dao), address(_plugin), dao.EXECUTE_PERMISSION_ID());
        dao.grant(address(_plugin), ANY_ADDR, TRIGGER_PERMISSION_ID);
        dao.grant(address(_plugin), address(dao), CONFIGURE_PERMISSION_ID);
        dao.grant(address(_plugin), manager, MANAGER_PERMISSION_ID);
    }

    function _one(IStageAction _action, ISplitter _splitter) internal pure returns (Stage[] memory _flow) {
        _flow = new Stage[](1);
        _flow[0] = Stage({action: _action, splitter: _splitter});
    }

    function _two(IStageAction _action0, ISplitter _splitter0, IStageAction _action1, ISplitter _splitter1)
        internal
        pure
        returns (Stage[] memory _flow)
    {
        _flow = new Stage[](2);
        _flow[0] = Stage({action: _action0, splitter: _splitter0});
        _flow[1] = Stage({action: _action1, splitter: _splitter1});
    }
}
