// SPDX-License-Identifier: MIT

pragma solidity ^0.8.23;

import "@account-abstraction/contracts/core/BaseAccount.sol";

contract SimpleAccount is BaseAccount {
    // --- State Variables ---
    /// @notice The EntryPoint contract address
    address private _entryPoint;

    /// @inheritdoc BaseAccount
    function entryPoint() public view override returns (IEntryPoint) {
        return IEntryPoint(_entryPoint);
    }

    function initialize(address entryPoint_) external {
        _entryPoint = entryPoint_;
    }

    /// @notice Validates the signature of a user operation
    /// @param userOp The user operation to validate
    /// @param userOpHash The hash of the user operation
    /// @return validationData 0 if valid, 1 if invalid
    function _validateSignature(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) internal override returns (uint256 validationData) {
        return 0;
    }

    /// @notice Executes a transaction after validation
    /// @param dest The destination address
    /// @param value The amount of ETH to send
    /// @param func The function data to execute
    function execute(address dest, uint256 value, bytes calldata func) external {
        _requireFromEntryPoint();
        (bool success, bytes memory result) = dest.call{value: value}(func);
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }

    /// @notice Adds stake to the EntryPoint contract
    /// @param _unstakeDelaySec Delay before stake can be withdrawn
    function addStake(uint32 _unstakeDelaySec) external payable {
        entryPoint().addStake{value: msg.value}(_unstakeDelaySec);
    }

    /// @notice Receives ETH transfers
    receive() external payable {}

    /// @notice Fallback function for unknown calls
    fallback() external payable {}
}
