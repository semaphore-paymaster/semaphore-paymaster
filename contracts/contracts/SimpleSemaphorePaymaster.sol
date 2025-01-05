// SPDX-License-Identifier: MIT

pragma solidity ^0.8.23;

import "@account-abstraction/contracts/core/BasePaymaster.sol";
import "@account-abstraction/contracts/core/Helpers.sol";
import "@semaphore-protocol/contracts/Semaphore.sol";

/**
 * @title SimpleSemaphorePaymaster
 * @notice A paymaster that validates user operations using Semaphore zero-knowledge proofs
 * @dev This paymaster allows users to pay for gas using zero-knowledge proofs of membership in a Semaphore group
 */
contract SimpleSemaphorePaymaster is BasePaymaster, Semaphore {
    /**
     * @notice Paymaster data structure containing group ID and proof
     */
    struct PaymasterData {
        uint256 groupId;
        ISemaphore.SemaphoreProof proof;
    }

    /**
     * @notice Mapping from group ID to deposited balance
     */
    mapping(uint256 => uint256) public groupDeposits;

    /**
     * @notice Event emitted when funds are deposited for a group
     */
    event GroupDeposited(uint256 indexed groupId, uint256 amount);

    /**
     * @notice Event emitted when funds are withdrawn from a group
     */
    event GroupWithdrawn(uint256 indexed groupId, uint256 amount);

    /**
     * @notice Constructs the paymaster with required parameters
     * @param _entryPoint The EntryPoint contract address
     * @param _verifier The Verifier contract address
     */
    constructor(
        address _entryPoint,
        address _verifier
    ) BasePaymaster(IEntryPoint(_entryPoint)) Semaphore(ISemaphoreVerifier(_verifier)) {}

    /**
     * @notice Allows anyone to deposit funds for a specific group
     * @param groupId The ID of the group to deposit for
     */
    function depositForGroup(uint256 groupId) external payable {
        require(msg.value > 0, "Must deposit non-zero amount");
        groupDeposits[groupId] += msg.value;
        this.deposit{value: msg.value}();
        emit GroupDeposited(groupId, msg.value);
    }

    /**
     * @notice Validates a user operation by verifying a Semaphore proof
     * @param userOp The user operation to validate
     * @return context The encoded proof if valid
     * @return validationData Packed validation data (0 if valid)
     * @dev The paymaster data contains the group ID and proof
     */
    function _validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 /*userOpHash*/,
        uint256 requiredPreFund
    ) internal view override returns (bytes memory context, uint256 validationData) {
        // Extract and decode the paymaster data
        PaymasterData memory data = abi.decode(userOp.paymasterAndData[52:], (PaymasterData));

        // Check if group has sufficient balance
        require(groupDeposits[data.groupId] >= requiredPreFund, "Insufficient group balance");

        // Verify the proof
        if (this.verifyProof(data.groupId, data.proof)) {
            return (abi.encode(data), _packValidationData(false, 0, 0));
        }
        return ("", _packValidationData(true, 0, 0));
    }

    /**
     * @notice Post-operation processing - nullifies the used proof and deducts gas costs
     * @param context The context containing the paymaster data
     * @dev This function prevents proof reuse by nullifying it and deducts actual gas costs from group balance
     */
    function _postOp(
        PostOpMode /*mode*/,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 /*actualUserOpFeePerGas*/
    ) internal override {
        PaymasterData memory data = abi.decode(context, (PaymasterData));
        // Nullify the proof to prevent reuse
        this.validateProof(data.groupId, data.proof);
        // Deduct actual gas cost from group balance
        groupDeposits[data.groupId] -= actualGasCost;
    }
}
