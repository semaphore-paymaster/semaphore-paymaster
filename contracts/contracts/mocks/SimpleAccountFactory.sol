// SPDX-License-Identifier: MIT

pragma solidity ^0.8.23;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "./SimpleAccount.sol";

contract SimpleAccountFactory {
    address public immutable entryPoint;
    address public immutable simpleAccountImplementation;

    event SimpleAccountCreated(address indexed accountAddress);

    constructor(address _entryPoint) {
        entryPoint = _entryPoint;
        simpleAccountImplementation = address(new SimpleAccount());
    }

    function createSimpleAccount(bytes32 salt) external returns (address) {
        address clone = Clones.cloneDeterministic(simpleAccountImplementation, salt);
        SimpleAccount(payable(clone)).initialize(entryPoint);
        emit SimpleAccountCreated(clone);
        return clone;
    }

    /// @notice Computes the address of a new SimpleAccount instance using EIP-1167 minimal proxy
    /// @return The address of the SimpleAccount that would be created
    function computeAddress(bytes32 salt) external view returns (address) {
        return Clones.predictDeterministicAddress(simpleAccountImplementation, salt, address(this));
    }
}
