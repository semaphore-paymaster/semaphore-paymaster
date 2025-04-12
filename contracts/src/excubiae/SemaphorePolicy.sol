// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BasePolicy} from "@excubiae/contracts/contracts/policy/BasePolicy.sol";
import {ISemaphore} from "@excubiae/contracts/contracts/extensions/semaphore/ISemaphore.sol";

/// @title SemaphorePolicy
/// @notice A policy contract enforcing semaphore validation.
/// Only if they can prove they are part of a semaphore group.
/// @dev Please note that once a identity is used to enforce, it cannot be used again.
/// This is because we store the nullifier which is
/// hash(secret, groupId)
contract SemaphorePolicy is BasePolicy {
    /// @notice The enforced identities
    mapping(uint256 => bool) public spentNullifiers;

    /// @notice Create a new instance of the Policy
    // solhint-disable-next-line no-empty-blocks
    constructor() payable {}

    /// @notice Enforce an user if they can prove they belong to a semaphore group
    /// @dev Throw if the proof is not valid or just complete silently
    /// @param _evidence The ABI-encoded schemaId as a uint256.
    function _enforce(address _subject, bytes calldata _evidence) internal override {
        // Note: Unlike Excubiae's SemaphorePolicy, we do not check for nullifier uniqueness.
        // This is because Paymaster's validatePaymasterUserOp call doesn't have write access to subsequent calls.

        super._enforce(_subject, _evidence);
    }

    /// @notice Get the trait of the Policy
    /// @return The type of the Policy
    function trait() public pure override returns (string memory) {
        return "Semaphore";
    }
}
