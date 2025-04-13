// SPDX-License-Identifier: MIT

pragma solidity ^0.8.23;

import "@account-abstraction/contracts/core/BasePaymaster.sol";
import "@account-abstraction/contracts/core/Helpers.sol";
import "@excubiae/contracts/contracts/policy/BasePolicy.sol";

/**
 * @title ExcubiaePaymaster
 * @notice A paymaster that validates user operations using Excubiae policy
 * @dev This paymaster allows users to be subsidized for gas based on provided proof of Excubiae policy
 */
abstract contract ExcubiaePaymaster is BasePaymaster {
    /**
     * @notice Paymaster data structure containing group ID and proof
     * @dev Used to decode the paymaster data from the user operation
     */
    struct PaymasterData {
        uint256 groupId;
        bytes proof;
    }

    /**
     * @notice The Excubiae policy that is used to validate user operations
     * @dev Used to enforce the Excubiae policy on the user operation
     */
    BasePolicy public immutable POLICY;

    /**
     * @notice Mapping from group ID to deposited balance
     * @dev Tracks the available funds for each group to pay for gas
     */
    mapping(uint256 => uint256) public groupDeposits;

    /**
     * @notice Constructs the paymaster with required parameters
     * @param _entryPoint The EntryPoint contract address
     */
    constructor(
        address _entryPoint
    ) BasePaymaster(IEntryPoint(_entryPoint)) {}

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
    ) internal virtual override {
        uint256 groupId = abi.decode(context, (uint256));
        // Deduct actual gas cost from group balance
        groupDeposits[groupId] -= actualGasCost;
    }
}
