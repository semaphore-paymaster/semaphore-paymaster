// SPDX-License-Identifier: MIT

pragma solidity ^0.8.23;

import "@account-abstraction/contracts/core/BasePaymaster.sol";
import "@account-abstraction/contracts/core/Helpers.sol";
import "./excubiae/SemaphorePolicy.sol";
import "./ExcubiaePaymaster.sol";

/**
 * @title ExcubiaeSemaphorePaymaster
 * @notice A paymaster that validates user operations using Excubiae SemaphorePolicy
 * @dev This paymaster allows users to be subsidized for gas based on provided proof of Excubiae SemaphorePolicy
 */
contract ExcubiaeSemaphorePaymaster is ExcubiaePaymaster {
    /**
     * @notice Constructs the paymaster with required parameters
     * @param _entryPoint The EntryPoint contract address
     * @param _policy Address of the policy contract enforcing access control.
     */
    constructor(address _entryPoint, address _policy) ExcubiaePaymaster(_entryPoint) {
        POLICY = SemaphorePolicy(_policy);
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
        // Extract and decode the paymaster data
        PaymasterData memory data = abi.decode(userOp.paymasterAndData[52:], (PaymasterData));
        ISemaphore.SemaphoreProof memory proof = abi.decode(data.proof, (ISemaphore.SemaphoreProof));

        // Check if group has sufficient balance
        if (groupDeposits[data.groupId] < requiredPreFund) {
            return ("", _packValidationData(true, 0, 0));
        }        

        // message must be the sender address cast to uint256
        uint256 expectedMessage = uint256(uint160(userOp.sender));
        if (proof.message != expectedMessage) {
            return ("", _packValidationData(true, 0, 0));
        }

        // groupId must be lower 96 bits of the proof scope
        uint96 expectedGroupId = uint96(proof.scope & ((1 << 96) - 1));
        if (data.groupId != expectedGroupId) {
            return ("", _packValidationData(true, 0, 0));
        }

        // Enforce the proof using Excubiae policy
        POLICY.enforce(msg.sender, data.proof);

        return (abi.encode(data.groupId), _packValidationData(false, 0, 0));
    }
}
