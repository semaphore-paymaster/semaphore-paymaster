// SPDX-License-Identifier: MIT

pragma solidity ^0.8.23;

import "@account-abstraction/contracts/core/BasePaymaster.sol";
import "@account-abstraction/contracts/core/Helpers.sol";
import "@semaphore-protocol/contracts/Semaphore.sol";
import "./SimpleSemaphorePaymaster.sol";

/**
 * @title CachedSemaphorePaymaster
 * @notice A paymaster that validates user operations using Semaphore zero-knowledge proofs and caches the proof until the merkle root changes
 * @dev This paymaster allows users to pay for gas using zero-knowledge proofs of membership in a Semaphore group.
 * The proofs can be cached to save gas on subsequent operations.
 */
contract CachedSemaphorePaymaster is SimpleSemaphorePaymaster {
    /**
     * @notice Mapping from address to group ID to last merkle root when proof was verified
     * @dev Stores cached proofs for each user address and group combination
     */
    mapping(address => mapping(uint256 => uint256)) public lastMerkleRoot;

    /**
     * @notice Constructs the paymaster with required parameters
     * @param _entryPoint The EntryPoint contract address
     * @param _verifier The Semaphore verifier contract address
     */
    constructor(address _entryPoint, address _verifier) SimpleSemaphorePaymaster(_entryPoint, _verifier) {}

    function isValidCachedProof(address user, uint256 groupId) public view returns (bool) {
        return lastMerkleRoot[user][groupId] == getMerkleTreeRoot(groupId);
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

        if (useCached) {
            // Use cached proof validation
            if (lastMerkleRoot[userOp.sender][groupId] != getMerkleTreeRoot(groupId)) {
                return ("", _packValidationData(true, 0, 0));
            }
            return (abi.encode(groupId), _packValidationData(false, 0, 0));
        } else {
            // Decode new proof from remaining data
            ISemaphore.SemaphoreProof memory proof = abi.decode(
                userOp.paymasterAndData[PAYMASTER_DATA_OFFSET + 33:],
                (ISemaphore.SemaphoreProof)
            );

            // Set the message to the expected message
            uint256 expectedMessage = uint256(uint160(userOp.sender));

            if (proof.message != expectedMessage) {
                return ("", _packValidationData(true, 0, 0));
            }

            // Verify new proof
            if (this.verifyProof(groupId, proof)) {
                // Cache the proof
                lastMerkleRoot[userOp.sender][groupId] = getMerkleTreeRoot(groupId);
                return (abi.encode(groupId), _packValidationData(false, 0, 0));
            }
        }
        return ("", _packValidationData(true, 0, 0));
    }
}
