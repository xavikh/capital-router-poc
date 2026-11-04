// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {
    DaoAuthorizableUpgradeable
} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizableUpgradeable.sol";
import {IStageAction} from "../interfaces/IStageAction.sol";
import {IBudget} from "../interfaces/IBudget.sol";
import {Plan} from "../lib/types.sol";
import {MANAGER_PERMISSION_ID} from "../lib/constants.sol";

/// @title MerkleClaimAction
/// @notice Cumulative Merkle distribution. Each leaf is (account, cumulative amount); an account
///         can claim `cumulative − claimed` at any time. A new root raises the cumulative amounts
///         for the next round.
/// @dev Outputs only what the claimed account is owed (not the whole budget) and sets it as the
///      flow's beneficiary, so later stages can swap it and a `PayBeneficiary` splitter pays it out.
///      Leaves use OpenZeppelin's StandardMerkleTree format: keccak256(bytes.concat(keccak256(abi.encode(account, cumulative)))).
///
///      Stage data: abi.encode(address account, uint256 cumulative, bytes32[] proof, address beneficiary).
///      Anyone may submit a claim (relayers), and the payout then goes to `account`. Only the account
///      itself may set a different beneficiary.
contract MerkleClaimAction is IStageAction, Initializable, DaoAuthorizableUpgradeable {
    /// @inheritdoc IStageAction
    IBudget public budget;

    /// @notice The current Merkle root of (account, cumulative amount) leaves
    bytes32 public root;

    /// @notice Cumulative amount already claimed per account
    mapping(address => uint256) public claimed;

    event RootUpdated(bytes32 root);
    event Claimed(address indexed account, address indexed beneficiary, uint256 amount);

    error NoBudget();
    error InvalidProof();
    error OnlyAccountCanRedirect();
    error InvalidBeneficiary();
    error OnlyDao();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IDAO _dao, IBudget _budget, bytes32 _root) external initializer {
        if (address(_budget) == address(0)) revert NoBudget();

        __DaoAuthorizableUpgradeable_init(_dao);
        budget = _budget;
        _setRoot(_root);
    }

    // IStageAction

    /// @inheritdoc IStageAction
    function preconditions(address, Plan calldata) external view virtual {}

    /// @inheritdoc IStageAction
    function build(address _caller, bytes calldata _data, Plan calldata _draft)
        external
        view
        virtual
        returns (Plan memory _plan, Action[] memory _actions)
    {
        (address _account, uint256 _cumulative, bytes32[] memory _proof, address _beneficiary) =
            abi.decode(_data, (address, uint256, bytes32[], address));

        if (!MerkleProof.verify(_proof, root, leaf(_account, _cumulative))) revert InvalidProof();
        if (_beneficiary == address(0)) _beneficiary = _account;
        if (_beneficiary != _account && _caller != _account) revert OnlyAccountCanRedirect();
        if (_beneficiary == address(dao())) revert InvalidBeneficiary();

        if (_cumulative <= claimed[_account]) return (_plan, _actions); // nothing new: skip
        uint256 _owed = _cumulative - claimed[_account];

        _plan = Plan({
            inToken: _draft.inToken,
            inAmount: _owed,
            outToken: _draft.inToken,
            outAmount: _owed,
            beneficiary: _beneficiary
        });

        _actions = new Action[](1);
        _actions[0] = Action({
            to: address(this), value: 0, data: abi.encodeCall(this.recordClaim, (_account, _cumulative, _beneficiary))
        });
    }

    /// @inheritdoc IStageAction
    /// @dev None: the plugin's balance checks verify the payout
    function postconditions(address, Plan calldata) external view virtual returns (Action[] memory) {}

    // Claim record

    /// @notice Records a claim. Executed by the DAO inside the claim's stage, so it rolls back with it.
    function recordClaim(address _account, uint256 _cumulative, address _beneficiary) external virtual {
        if (msg.sender != address(dao())) revert OnlyDao();

        emit Claimed(_account, _beneficiary, _cumulative - claimed[_account]);
        claimed[_account] = _cumulative;
    }

    /// @notice Replaces the root, usually with higher cumulative amounts for a new round
    /// @dev Whoever holds this can direct payouts up to the DAO's balance of the token
    function setRoot(bytes32 _root) external virtual auth(MANAGER_PERMISSION_ID) {
        _setRoot(_root);
    }

    /// @notice The leaf for `(account, cumulative)`, in OpenZeppelin's StandardMerkleTree format
    function leaf(address _account, uint256 _cumulative) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(_account, _cumulative))));
    }

    function _setRoot(bytes32 _root) internal {
        root = _root;
        emit RootUpdated(_root);
    }
}
