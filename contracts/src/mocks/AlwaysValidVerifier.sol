// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;
pragma abicoder v2;

import {IGroth16Verifier} from "../interfaces/IGroth16Verifier.sol";
import {ISemaphoreVerifier} from "@semaphore-protocol/contracts/interfaces/ISemaphoreVerifier.sol";

contract AlwaysValidVerifier is ISemaphoreVerifier {
    function verifyProof(
        uint[2] calldata,
        uint[2][2] calldata,
        uint[2] calldata,
        uint[4] calldata,
        uint
    ) external pure returns (bool) {
        // Mock implementation that always returns true
        return true;
    }
}
