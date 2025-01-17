// SPDX-License-Identifier: MIT

pragma solidity ^0.8.23;

import "@account-abstraction/contracts/core/BasePaymaster.sol";
import "@account-abstraction/contracts/core/Helpers.sol";
import "@semaphore-protocol/contracts/Semaphore.sol";

/**
 * @title CachedSemaphorePaymaster
 * @notice A paymaster that validates user operations using Semaphore zero-knowledge proofs and caches the proof
 * @dev This paymaster allows users to pay for gas using zero-knowledge proofs of membership in a Semaphore group.
 * The proofs can be cached to save gas on subsequent operations.
 */
contract CachedSemaphorePaymaster is BasePaymaster, Semaphore {
    /**
     * @notice Cached proof data structure
     * @dev Stores a previously validated proof along with its group ID, merkle root, and validity status
     */
    struct CachedProof {
        uint256 groupId;
        ISemaphore.SemaphoreProof proof;
        uint256 merkleRoot;
        bool isValid;
    }

    /**
     * @notice Mapping from group ID to deposited balance
     * @dev Tracks the available funds for each group to pay for gas
     */
    mapping(uint256 => uint256) public groupDeposits;

    /**
     * @notice Mapping from address to cached proof data
     * @dev Stores cached proofs for each user address to avoid re-verification
     */
    mapping(address => CachedProof) public cachedProofs;

    /**
     * @notice Mapping from group ID to current merkle root
     * @dev Tracks the current merkle root for each group to detect membership changes
     */
    mapping(uint256 => uint256) public groupMerkleRoots;

    /**
     * @notice Constructs the paymaster with required parameters
     * @param _entryPoint The EntryPoint contract address
     * @param _verifier The Semaphore verifier contract address
     */
    constructor(
        address _entryPoint,
        address _verifier
    ) BasePaymaster(IEntryPoint(_entryPoint)) Semaphore(ISemaphoreVerifier(_verifier)) {}

    /**
     * @notice Allows anyone to deposit funds for a specific group to be used for gas payment for members of the group
     * @param groupId The ID of the group to deposit for
     * @dev Deposits are added to both the group's balance and the EntryPoint contract
     */
    function depositForGroup(uint256 groupId) external payable {
        require(msg.value > 0, "Must deposit non-zero amount");
        groupDeposits[groupId] += msg.value;
        this.deposit{value: msg.value}();
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

        // Generate message using only sender address
        uint256 expectedMessage = uint256(uint160(userOp.sender));

        if (useCached) {
            // Use cached proof
            CachedProof storage cached = cachedProofs[userOp.sender];
            if (!cached.isValid || cached.groupId != groupId) {
                return ("", _packValidationData(true, 0, 0));
            }

            // Check if merkle root has changed
            if (groupMerkleRoots[groupId] != cached.merkleRoot) {
                // Verify the cached proof against new merkle root
                if (!this.verifyProof(groupId, cached.proof)) {
                    return ("", _packValidationData(true, 0, 0));
                }
                // Update stored merkle root
                cached.merkleRoot = groupMerkleRoots[groupId];
            }

            // Verify message matches
            if (cached.proof.message != expectedMessage) {
                return ("", _packValidationData(true, 0, 0));
            }

            return (abi.encode(groupId), _packValidationData(false, 0, 0));
        } else {
            // Decode new proof from remaining data
            ISemaphore.SemaphoreProof memory proof = abi.decode(
                userOp.paymasterAndData[PAYMASTER_DATA_OFFSET + 33:],
                (ISemaphore.SemaphoreProof)
            );

            // Verify message
            if (proof.message != expectedMessage) {
                return ("", _packValidationData(true, 0, 0));
            }

            // Verify new proof
            if (this.verifyProof(groupId, proof)) {
                // Cache the proof
                cachedProofs[userOp.sender] = CachedProof({
                    groupId: groupId,
                    proof: proof,
                    merkleRoot: groupMerkleRoots[groupId],
                    isValid: true
                });
                return (abi.encode(groupId), _packValidationData(false, 0, 0));
            }
        }
        return ("", _packValidationData(true, 0, 0));
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
        uint256 groupId = abi.decode(context, (uint256));
        // Deduct actual gas cost from group balance
        groupDeposits[groupId] -= actualGasCost;
    }
}
