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
import {TransferAction} from "../../src/actions/TransferAction.sol";
import {TransferToBeneficiaryAction} from "../../src/actions/TransferToBeneficiaryAction.sol";
import {BurnAction} from "../../src/actions/BurnAction.sol";
import {KeepAction} from "../../src/actions/KeepAction.sol";
import {SplitTransferAction} from "../../src/actions/SplitTransferAction.sol";
import {CapitalPipelinePlugin} from "../../src/CapitalPipelinePlugin.sol";
import {IBudget} from "../../src/interfaces/IBudget.sol";
import {INodeAction} from "../../src/interfaces/INodeAction.sol";
import {ISplitter} from "../../src/interfaces/ISplitter.sol";
import {Node} from "../../src/lib/types.sol";
import {
    MANAGER_PERMISSION_ID,
    CHECKPOINT_PERMISSION_ID,
    TRIGGER_PERMISSION_ID,
    CONFIGURE_PERMISSION_ID,
    RECORD_CLAIM_PERMISSION_ID
} from "../../src/lib/constants.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

/// @notice A DAO holding the offered token A and some pre-existing demanded token B.
///         The test contract is the DAO's ROOT, so it can grant permissions directly.
abstract contract Fixture is Test {
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;
    address internal constant ANY_ADDR = address(type(uint160).max);
    INodeAction internal constant NO_ACTION = INodeAction(address(0));

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

    // Stateless leaves: one deployment serves every plugin
    BurnAction internal burn = new BurnAction();
    KeepAction internal keep = new KeepAction();
    TransferToBeneficiaryAction internal toBeneficiary = new TransferToBeneficiaryAction();

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

    /// @dev A stream of token A. Deploy after funding the DAO: the budget records the balance it sees at init.
    function _deployBudget(uint256 _rate, uint256 _maxBudget) internal returns (FundedStreamBudget) {
        return _deployStream(tokenA, _rate, _maxBudget);
    }

    /// @dev A stream of any token, or of native ETH (`NATIVE`)
    function _deployStream(IERC20 _token, uint256 _rate, uint256 _maxBudget)
        internal
        returns (FundedStreamBudget _budget)
    {
        _budget = FundedStreamBudget(
            ProxyLib.deployMinimalProxy(
                address(new FundedStreamBudget()),
                abi.encodeCall(FundedStreamBudget.initialize, (dao, _token, _rate, _maxBudget, EPOCH))
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

    // Splitters (used by SplitTransferAction)

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

    /// @dev Demands token B. Bound to `_budget`, which it may restart when its price terms change.
    function _deployAction(FundedStreamBudget _budget) internal returns (OpenFillAction) {
        return _deployOpenFill(_budget, tokenB);
    }

    /// @dev Demands any token, or native ETH (`NATIVE`)
    function _deployOpenFill(FundedStreamBudget _budget, IERC20 _demanded) internal returns (OpenFillAction _action) {
        _action = OpenFillAction(
            ProxyLib.deployMinimalProxy(
                address(new OpenFillAction()),
                abi.encodeCall(OpenFillAction.initialize, (dao, _budget, _demanded, DEMAND, MIN_PRICE))
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
        dao.grant(address(_merkle), address(dao), RECORD_CLAIM_PERMISSION_ID);
    }

    function _deployTransfer(address _to) internal returns (TransferAction) {
        return TransferAction(
            ProxyLib.deployMinimalProxy(address(new TransferAction()), abi.encodeCall(TransferAction.initialize, (_to)))
        );
    }

    function _deploySplitTransfer(ISplitter _splitter) internal returns (SplitTransferAction) {
        return SplitTransferAction(
            ProxyLib.deployMinimalProxy(
                address(new SplitTransferAction()), abi.encodeCall(SplitTransferAction.initialize, (_splitter))
            )
        );
    }

    // Plugin

    /// @dev Same grants as CapitalPipelinePluginSetup: anyone triggers, the DAO configures, the manager pauses
    function _deployPlugin(IBudget _budget, Node[] memory _tree) internal returns (CapitalPipelinePlugin _plugin) {
        _plugin = CapitalPipelinePlugin(
            ProxyLib.deployMinimalProxy(
                address(new CapitalPipelinePlugin()),
                abi.encodeCall(CapitalPipelinePlugin.initialize, (dao, _budget, _tree))
            )
        );
        dao.grant(address(dao), address(_plugin), dao.EXECUTE_PERMISSION_ID());
        dao.grant(address(_plugin), ANY_ADDR, TRIGGER_PERMISSION_ID);
        dao.grant(address(_plugin), address(dao), CONFIGURE_PERMISSION_ID);
        dao.grant(address(_plugin), manager, MANAGER_PERMISSION_ID);
    }

    // Trees

    /// @dev A single node with no children
    function _leaf(INodeAction _action) internal pure returns (Node memory _node) {
        _node.action = _action;
    }

    /// @dev A node with one child
    function _then(INodeAction _action, uint32 _child) internal pure returns (Node memory _node) {
        _node.action = _action;
        _node.children = new uint32[](1);
        _node.children[0] = _child;
    }

    /// @dev A node with two children, split by weights (fractions of RATIO_BASE)
    function _branch(INodeAction _action, uint32 _childA, uint32 _weightA, uint32 _childB, uint32 _weightB)
        internal
        pure
        returns (Node memory _node)
    {
        _node.action = _action;
        _node.children = new uint32[](2);
        (_node.children[0], _node.children[1]) = (_childA, _childB);
        _node.weights = new uint32[](2);
        (_node.weights[0], _node.weights[1]) = (_weightA, _weightB);
    }

    /// @dev A one-node tree
    function _one(INodeAction _action) internal pure returns (Node[] memory _tree) {
        _tree = new Node[](1);
        _tree[0] = _leaf(_action);
    }

    /// @dev `_a` → `_b`
    function _chain(INodeAction _a, INodeAction _b) internal pure returns (Node[] memory _tree) {
        _tree = new Node[](2);
        (_tree[0], _tree[1]) = (_then(_a, 1), _leaf(_b));
    }

    /// @dev `_a` → `_b` → `_c`
    function _chain(INodeAction _a, INodeAction _b, INodeAction _c) internal pure returns (Node[] memory _tree) {
        _tree = new Node[](3);
        (_tree[0], _tree[1], _tree[2]) = (_then(_a, 1), _then(_b, 2), _leaf(_c));
    }

    /// @dev `_root` split by weight between two leaves
    function _fork(INodeAction _root, uint32 _weightA, INodeAction _a, uint32 _weightB, INodeAction _b)
        internal
        pure
        returns (Node[] memory _tree)
    {
        _tree = new Node[](3);
        (_tree[0], _tree[1], _tree[2]) = (_branch(_root, 1, _weightA, 2, _weightB), _leaf(_a), _leaf(_b));
    }
}
