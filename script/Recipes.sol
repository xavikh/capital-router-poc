// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {CapitalPipelinePluginSetup} from "../src/setup/CapitalPipelinePluginSetup.sol";
import {FundedStreamBudget} from "../src/budgets/FundedStreamBudget.sol";
import {BalanceBudget} from "../src/budgets/BalanceBudget.sol";
import {OpenFillAction} from "../src/actions/OpenFillAction.sol";
import {MerkleClaimAction} from "../src/actions/MerkleClaimAction.sol";
import {TransferAction} from "../src/actions/TransferAction.sol";
import {TransferToBeneficiaryAction} from "../src/actions/TransferToBeneficiaryAction.sol";
import {SplitTransferAction} from "../src/actions/SplitTransferAction.sol";
import {BurnAction} from "../src/actions/BurnAction.sol";
import {RatioSplitter} from "../src/splitters/RatioSplitter.sol";
import {IBudget, ICheckpointedBudget} from "../src/interfaces/IBudget.sol";
import {INodeAction} from "../src/interfaces/INodeAction.sol";
import {ISplitter} from "../src/interfaces/ISplitter.sol";
import {Node} from "../src/lib/types.sol";
import {
    TRIGGER_PERMISSION_ID,
    MANAGER_PERMISSION_ID,
    CHECKPOINT_PERMISSION_ID,
    RECORD_CLAIM_PERMISSION_ID,
    RATIO_BASE
} from "../src/lib/constants.sol";
import {DAO_REF, PLUGIN_REF, ref} from "../src/lib/placeholders.sol";

/// @title Recipes
/// @notice Registry ids and install recipes for the common flows. A recipe is
///         `abi.encode(CapitalPipelinePluginSetup.InstallParams)`.
library Recipes {
    bytes32 internal constant FUNDED_STREAM_BUDGET = "FundedStreamBudget@1";
    bytes32 internal constant BALANCE_BUDGET = "BalanceBudget@1";
    bytes32 internal constant OPEN_FILL = "OpenFillAction@1";
    bytes32 internal constant MERKLE_CLAIM = "MerkleClaimAction@1";
    bytes32 internal constant TRANSFER = "TransferAction@1";
    bytes32 internal constant TRANSFER_TO_BENEFICIARY = "TransferToBeneficiaryAction@1";
    bytes32 internal constant SPLIT_TRANSFER = "SplitTransferAction@1";
    bytes32 internal constant BURN = "BurnAction@1";
    bytes32 internal constant KEEP = "KeepAction@1";
    bytes32 internal constant RATIO_SPLITTER = "RatioSplitter@1";

    address internal constant ANY_ADDR = address(type(uint160).max);

    struct Stream {
        IERC20 token;
        uint256 amountPerEpoch;
        uint256 maxBudget;
        uint256 epochInterval;
    }

    struct Swap {
        IERC20 demandedToken;
        uint256 demandPerFill;
        uint256 minDemandedPerOffered;
    }

    /// @notice Stream → OpenFill → pay a ratio list.
    ///         Components: 0 budget, 1 OpenFill, 2 RatioSplitter, 3 SplitTransfer.
    function swapAndSplit(
        address _manager,
        Stream memory _stream,
        Swap memory _swap,
        address[] memory _recipients,
        uint32[] memory _ratios
    ) internal pure returns (CapitalPipelinePluginSetup.InstallParams memory _params) {
        _params.components = new CapitalPipelinePluginSetup.Component[](4);
        _params.components[0] = _streamBudget(_stream);
        _params.components[1] = _openFill(_swap);
        _params.components[2] = _ratio(_recipients, _ratios);
        _params.components[3] = _splitTransfer(2);

        _params.budget = IBudget(ref(0));
        _params.nodes = new Node[](2);
        _params.nodes[0] = _then(1, 1);
        _params.nodes[1] = _leaf(3);

        _params.grants = new CapitalPipelinePluginSetup.Grant[](7);
        _params.grants[0] = _grant(PLUGIN_REF, ANY_ADDR, TRIGGER_PERMISSION_ID);
        _params.grants[1] = _grant(PLUGIN_REF, _manager, MANAGER_PERMISSION_ID);
        _params.grants[2] = _grant(ref(0), _manager, MANAGER_PERMISSION_ID);
        _params.grants[3] = _grant(ref(1), _manager, MANAGER_PERMISSION_ID);
        _params.grants[4] = _grant(ref(2), _manager, MANAGER_PERMISSION_ID);
        _params.grants[5] = _grant(ref(0), DAO_REF, CHECKPOINT_PERMISSION_ID);
        _params.grants[6] = _grant(ref(0), ref(1), CHECKPOINT_PERMISSION_ID);
    }

    /// @notice Stream → OpenFill → burn the proceeds, except `_feeWeight` (of RATIO_BASE) to `_fee`.
    ///         Components: 0 budget, 1 OpenFill, 2 Burn, 3 Transfer.
    function buyback(address _manager, Stream memory _stream, Swap memory _swap, address _fee, uint32 _feeWeight)
        internal
        pure
        returns (CapitalPipelinePluginSetup.InstallParams memory _params)
    {
        _params.components = new CapitalPipelinePluginSetup.Component[](4);
        _params.components[0] = _streamBudget(_stream);
        _params.components[1] = _openFill(_swap);
        _params.components[2] = _component(BURN, abi.encodeCall(BurnAction.initialize, (IDAO(DAO_REF))));
        _params.components[3] = _component(TRANSFER, abi.encodeCall(TransferAction.initialize, (IDAO(DAO_REF), _fee)));

        _params.budget = IBudget(ref(0));
        _params.nodes = new Node[](3);
        _params.nodes[0].action = INodeAction(ref(1));
        _params.nodes[0].children = new uint32[](2);
        (_params.nodes[0].children[0], _params.nodes[0].children[1]) = (1, 2);
        _params.nodes[0].weights = new uint32[](2);
        (_params.nodes[0].weights[0], _params.nodes[0].weights[1]) = (uint32(RATIO_BASE) - _feeWeight, _feeWeight);
        _params.nodes[1] = _leaf(2);
        _params.nodes[2] = _leaf(3);

        _params.grants = new CapitalPipelinePluginSetup.Grant[](6);
        _params.grants[0] = _grant(PLUGIN_REF, ANY_ADDR, TRIGGER_PERMISSION_ID);
        _params.grants[1] = _grant(PLUGIN_REF, _manager, MANAGER_PERMISSION_ID);
        _params.grants[2] = _grant(ref(0), _manager, MANAGER_PERMISSION_ID);
        _params.grants[3] = _grant(ref(1), _manager, MANAGER_PERMISSION_ID);
        _params.grants[4] = _grant(ref(0), DAO_REF, CHECKPOINT_PERMISSION_ID);
        _params.grants[5] = _grant(ref(0), ref(1), CHECKPOINT_PERMISSION_ID);
    }

    /// @notice The DAO's balance of `_token` → Merkle claim → pay the beneficiary.
    ///         Components: 0 budget, 1 MerkleClaim, 2 TransferToBeneficiary.
    function merkleClaim(address _manager, IERC20 _token, bytes32 _root)
        internal
        pure
        returns (CapitalPipelinePluginSetup.InstallParams memory _params)
    {
        _params.components = new CapitalPipelinePluginSetup.Component[](3);
        _params.components[0] =
            _component(BALANCE_BUDGET, abi.encodeCall(BalanceBudget.initialize, (IDAO(DAO_REF), _token)));
        _params.components[1] = _component(
            MERKLE_CLAIM, abi.encodeCall(MerkleClaimAction.initialize, (IDAO(DAO_REF), IBudget(ref(0)), _root))
        );
        _params.components[2] = _component(
            TRANSFER_TO_BENEFICIARY, abi.encodeCall(TransferToBeneficiaryAction.initialize, (IDAO(DAO_REF)))
        );

        _params.budget = IBudget(ref(0));
        _params.nodes = new Node[](2);
        _params.nodes[0] = _then(1, 1);
        _params.nodes[1] = _leaf(2);

        _params.grants = new CapitalPipelinePluginSetup.Grant[](4);
        _params.grants[0] = _grant(PLUGIN_REF, ANY_ADDR, TRIGGER_PERMISSION_ID);
        _params.grants[1] = _grant(PLUGIN_REF, _manager, MANAGER_PERMISSION_ID);
        _params.grants[2] = _grant(ref(1), _manager, MANAGER_PERMISSION_ID);
        _params.grants[3] = _grant(ref(1), DAO_REF, RECORD_CLAIM_PERMISSION_ID);
    }

    /// @notice Stream → pay a ratio list.
    ///         Components: 0 budget, 1 RatioSplitter, 2 SplitTransfer.
    function payroll(address _manager, Stream memory _stream, address[] memory _recipients, uint32[] memory _ratios)
        internal
        pure
        returns (CapitalPipelinePluginSetup.InstallParams memory _params)
    {
        _params.components = new CapitalPipelinePluginSetup.Component[](3);
        _params.components[0] = _streamBudget(_stream);
        _params.components[1] = _ratio(_recipients, _ratios);
        _params.components[2] = _splitTransfer(1);

        _params.budget = IBudget(ref(0));
        _params.nodes = new Node[](1);
        _params.nodes[0] = _leaf(2);

        _params.grants = new CapitalPipelinePluginSetup.Grant[](5);
        _params.grants[0] = _grant(PLUGIN_REF, ANY_ADDR, TRIGGER_PERMISSION_ID);
        _params.grants[1] = _grant(PLUGIN_REF, _manager, MANAGER_PERMISSION_ID);
        _params.grants[2] = _grant(ref(0), _manager, MANAGER_PERMISSION_ID);
        _params.grants[3] = _grant(ref(1), _manager, MANAGER_PERMISSION_ID);
        _params.grants[4] = _grant(ref(0), DAO_REF, CHECKPOINT_PERMISSION_ID);
    }

    // Components

    function _streamBudget(Stream memory _stream) private pure returns (CapitalPipelinePluginSetup.Component memory) {
        return _component(
            FUNDED_STREAM_BUDGET,
            abi.encodeCall(
                FundedStreamBudget.initialize,
                (IDAO(DAO_REF), _stream.token, _stream.amountPerEpoch, _stream.maxBudget, _stream.epochInterval)
            )
        );
    }

    /// @dev Bound to component 0, the budget
    function _openFill(Swap memory _swap) private pure returns (CapitalPipelinePluginSetup.Component memory) {
        return _component(
            OPEN_FILL,
            abi.encodeCall(
                OpenFillAction.initialize,
                (
                    IDAO(DAO_REF),
                    ICheckpointedBudget(ref(0)),
                    _swap.demandedToken,
                    _swap.demandPerFill,
                    _swap.minDemandedPerOffered
                )
            )
        );
    }

    function _ratio(address[] memory _recipients, uint32[] memory _ratios)
        private
        pure
        returns (CapitalPipelinePluginSetup.Component memory)
    {
        return
            _component(RATIO_SPLITTER, abi.encodeCall(RatioSplitter.initialize, (IDAO(DAO_REF), _recipients, _ratios)));
    }

    function _splitTransfer(uint256 _splitter) private pure returns (CapitalPipelinePluginSetup.Component memory) {
        return _component(
            SPLIT_TRANSFER, abi.encodeCall(SplitTransferAction.initialize, (IDAO(DAO_REF), ISplitter(ref(_splitter))))
        );
    }

    function _component(bytes32 _id, bytes memory _initData)
        private
        pure
        returns (CapitalPipelinePluginSetup.Component memory)
    {
        return CapitalPipelinePluginSetup.Component(_id, _initData);
    }

    // Tree

    function _leaf(uint256 _index) private pure returns (Node memory _node) {
        _node.action = INodeAction(ref(_index));
    }

    function _then(uint256 _index, uint32 _child) private pure returns (Node memory _node) {
        _node.action = INodeAction(ref(_index));
        _node.children = new uint32[](1);
        _node.children[0] = _child;
    }

    function _grant(address _where, address _who, bytes32 _id)
        private
        pure
        returns (CapitalPipelinePluginSetup.Grant memory)
    {
        return CapitalPipelinePluginSetup.Grant(_where, _who, _id);
    }
}
