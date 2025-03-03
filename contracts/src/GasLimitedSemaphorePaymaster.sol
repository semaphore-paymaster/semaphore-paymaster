// SPDX-License-Identifier: MIT

pragma solidity ^0.8.23;

import "@account-abstraction/contracts/core/BasePaymaster.sol";
import "@account-abstraction/contracts/core/Helpers.sol";
import "@semaphore-protocol/contracts/Semaphore.sol";
import "./SimpleSemaphorePaymaster.sol";

/**
 * @notice Data structure to store gas used and last merkle root for a nullifier
 */
struct NullifierGasData {
    uint256 gasUsed; // cumulative gas used for the nullifier in the current epoch per group
    uint256 lastMerkleRoot; // last merkle root when proof was verified for the nullifier
    uint256 epoch; // epoch when the nullifier was verified
}

/**
 * @title GasLimitedSemaphorePaymaster
 * @notice A paymaster that validates user operations using Semaphore zero-knowledge proofs and caches the proof until the merkle root changes
 * @dev This paymaster allows users to pay for gas using zero-knowledge proofs of membership in a Semaphore group.
 * The proofs can be cached to save gas on subsequent operations.
 * The paymaster will only allow a certain amount of gas to be used per group per user.
 */
contract GasLimitedSemaphorePaymaster is SimpleSemaphorePaymaster {
    uint256 public epochDuration; // duration of an epoch in seconds
    uint256 public firstEpochTimestamp; // timestamp of the first epoch

    /**
     * @notice Mapping from group ID to max gas per user per epoch
     * @dev Stores the max gas per user per epoch for each group
     */
    mapping(uint256 => uint256) public maxGasPerUserPerEpoch;

    /**
     * @notice Mapping from nullifier to gas used per epoch
     * @dev Stores the gas used per epoch for each user (identified by nullifier)
     * since nullifier is based on scope, and scope is hash(groupId, epoch), we can use the nullifier as a unique identifier for the user's gas usage
     */
    mapping(uint256 => NullifierGasData) public gasData;

    /**
     * @notice Current epoch
     * @dev Cannot be calculated dynamically because block.timestamp is not available in validatePaymasterUserOp due to opcode restrictions
     * can be updated by calling updateEpoch()
     */
    uint256 public currentEpoch;

    /**
     * @notice Constructs the paymaster with required parameters
     * @param _entryPoint The EntryPoint contract address
     * @param _verifier The Semaphore verifier contract address
     * @param _epochDuration The duration of an epoch in seconds
     * @param _firstEpochTimestamp The timestamp of the first epoch
     * @dev max gas limit can be set for each group by the group admin
     */
    constructor(
        address _entryPoint,
        address _verifier,
        uint256 _epochDuration,
        uint256 _firstEpochTimestamp
    ) SimpleSemaphorePaymaster(_entryPoint, _verifier) {
        epochDuration = _epochDuration;
        firstEpochTimestamp = _firstEpochTimestamp;
        currentEpoch = 0;
    }

    /**
     * @notice Validates a user operation by verifying a Semaphore proof
     * @param userOp The user operation to validate
     * @param requiredPreFund The amount of funds required for the operation
     * @return context The encoded group ID if valid
     * @return validationData Packed validation data (0 if valid, non-zero if invalid)
     * @dev The paymaster data format is:
     *      - First byte: 0x01 for cached proof, 0x00 for new proof
     *      - Next 32 bytes: group ID
     *      - Remaining bytes (for new proof only): encoded SemaphoreProof
     */
    function _validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 /*userOpHash*/,
        uint256 requiredPreFund
    ) internal override returns (bytes memory context, uint256 validationData) {
        // First byte indicates if using cached proof
        bool useCached = userOp.paymasterAndData[PAYMASTER_DATA_OFFSET] == 0x01;

        // Next 32 bytes contain the group ID
        uint256 groupId = uint256(
            bytes32(userOp.paymasterAndData[PAYMASTER_DATA_OFFSET + 1:PAYMASTER_DATA_OFFSET + 33])
        );

        // Check if group has sufficient balance
        if (groupDeposits[groupId] < requiredPreFund) {
            return ("", _packValidationData(true, 0, 0));
        }

        uint256 nullifier;

        if (useCached) {
            // decode the indentifier from remaining data which is a uint256
            nullifier = abi.decode(userOp.paymasterAndData[PAYMASTER_DATA_OFFSET + 33:], (uint256));

            NullifierGasData memory nullifierGasData = gasData[nullifier];

            // check if the merkle root has changed since the last time the proof was checked
            if (nullifierGasData.lastMerkleRoot != getMerkleTreeRoot(groupId)) {
                return ("", _packValidationData(true, 0, 0));
            }

            // check if it belongs to the current epoch
            if (nullifierGasData.epoch != currentEpoch) {
                return ("", _packValidationData(true, 0, 0));
            }
        } else {
            // Decode new proof from remaining data
            ISemaphore.SemaphoreProof memory proof = abi.decode(
                userOp.paymasterAndData[PAYMASTER_DATA_OFFSET + 33:],
                (ISemaphore.SemaphoreProof)
            );

            uint256 expectedMessage = uint256(uint160(userOp.sender));
            uint256 expectedScope = uint256(keccak256(abi.encode(groupId, currentEpoch)));

            if (proof.message != expectedMessage || proof.scope != expectedScope) {
                return ("", _packValidationData(true, 0, 0));
            }

            if (!this.verifyProof(groupId, proof)) {
                return ("", _packValidationData(true, 0, 0));
            }

            nullifier = proof.nullifier;

            // cache the proof
            gasData[nullifier].lastMerkleRoot = getMerkleTreeRoot(groupId);
            gasData[nullifier].epoch = currentEpoch;
        }

        // check if user has enough gas left to pay for the operation, proof.nullifier is used as a unique identifier for the user's gas usage
        if (gasData[nullifier].gasUsed + requiredPreFund > maxGasPerUserPerEpoch[groupId]) {
            return ("", _packValidationData(true, 0, 0));
        }

        return (abi.encode(nullifier), _packValidationData(false, 0, 0));
    }

    /**
     * @notice Post-operation processing - deducts gas costs from group balance
     * @param context The context containing the group ID
     * @param actualGasCost The actual gas cost of the operation
     * @dev This function deducts actual gas costs from the group's deposited balance
     */
    function _postOp(
        PostOpMode /*mode*/,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 /*actualUserOpFeePerGas*/
    ) internal override {
        uint256 nullifier = abi.decode(context, (uint256));
        gasData[nullifier].gasUsed += actualGasCost;
    }

    /**
     * @notice Updates the current epoch
     * @dev Can only be called after the first epoch has started
     */
    function updateEpoch() public {
        currentEpoch = (block.timestamp - firstEpochTimestamp) / epochDuration;
    }

    /**
     * @notice Sets the maximum gas per user per epoch for a group
     * @param groupId The ID of the group
     * @param maxGas The maximum gas per user per epoch
     * @dev Can only be called by the group admin
     */
    function setMaxGasPerUserPerEpoch(uint256 groupId, uint256 maxGas) external onlyGroupAdmin(groupId) {
        maxGasPerUserPerEpoch[groupId] = maxGas;
    }
}
