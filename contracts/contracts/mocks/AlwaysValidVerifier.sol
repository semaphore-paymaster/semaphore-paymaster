// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;
pragma abicoder v2;

import {IGroth16Verifier} from "../interfaces/IGroth16Verifier.sol";

contract AlwaysValidVerifier is IGroth16Verifier {
    function verifyProof(
        uint[2] calldata _pA,
        uint[2][2] calldata _pB,
        uint[2] calldata _pC,
        uint[3] calldata _pubSignals
    ) external view returns (bool r) {
        // For now, we'll keep the dummy implementation
        return true;
    }
}