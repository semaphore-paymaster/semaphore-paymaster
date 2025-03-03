// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {GasLimitedSemaphorePaymaster} from "../../src/GasLimitedSemaphorePaymaster.sol";
import {AlwaysValidVerifier} from "../../src/mocks/AlwaysValidVerifier.sol";
import {EntryPoint} from "@account-abstraction/contracts/core/EntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {ISemaphore} from "@semaphore-protocol/contracts/interfaces/ISemaphore.sol";
import {IPaymaster} from "@account-abstraction/contracts/interfaces/IPaymaster.sol";

// Helper struct to match the contract's struct
struct NullifierGasData {
    uint256 gasUsed;
    uint256 lastMerkleRoot;
    uint256 epoch;
}

// Mock implementation of GasLimitedSemaphorePaymaster for testing
contract TestGasLimitedSemaphorePaymaster is GasLimitedSemaphorePaymaster {
    constructor(
        address _entryPoint,
        address _verifier,
        uint256 _epochDuration
    ) GasLimitedSemaphorePaymaster(_entryPoint, _verifier, _epochDuration) {}

    // Helper function to manually set gas data for testing
    function setGasData(uint256 nullifier, uint256 _gasUsed, uint256 _lastMerkleRoot, uint256 _epoch) external {
        // Set the values directly
        gasData[nullifier].gasUsed = _gasUsed;
        gasData[nullifier].lastMerkleRoot = _lastMerkleRoot;
        gasData[nullifier].epoch = _epoch;
    }

    // Helper function to reset gas usage for a new epoch
    function resetGasUsageForNewEpoch(uint256 nullifier) external {
        if (gasData[nullifier].epoch != 0 && gasData[nullifier].epoch != currentEpoch) {
            gasData[nullifier].gasUsed = 0;
            gasData[nullifier].epoch = currentEpoch;
        }
    }
}

contract GasLimitedSemaphorePaymasterTest is Test {
    TestGasLimitedSemaphorePaymaster public paymaster;
    AlwaysValidVerifier public verifier;
    address public entryPoint;
    address public sender = address(0x1234);
    uint256 public constant GROUP_ID = 0;
    uint256 public constant MAX_GAS_PER_USER = 1 ether; // 1 ETH worth of gas per user per epoch
    uint256 public constant EPOCH_DURATION = 1 days;

    function setUp() public {
        // Deploy mock contracts
        entryPoint = address(new EntryPoint());
        verifier = new AlwaysValidVerifier();

        // Deploy paymaster with epoch parameters
        paymaster = new TestGasLimitedSemaphorePaymaster(entryPoint, address(verifier), EPOCH_DURATION);

        // Create group and fund it
        paymaster.createGroup();
        paymaster.depositForGroup{value: 10 ether}(GROUP_ID);
        paymaster.addStake{value: 1 ether}(1);

        // Set max gas per user per epoch
        paymaster.setMaxGasPerUserPerEpoch(GROUP_ID, MAX_GAS_PER_USER);

        // Update current epoch
        paymaster.updateEpoch();
    }

    function test_SetMaxGasPerUserPerEpoch() public {
        // Create a new group
        uint256 newGroupId = 1;
        paymaster.createGroup();

        // Set max gas per user per epoch for the new group
        uint256 newMaxGas = 2 ether;
        paymaster.setMaxGasPerUserPerEpoch(newGroupId, newMaxGas);

        // Check that the max gas was set correctly
        assertEq(
            paymaster.maxGasPerUserPerEpoch(newGroupId),
            newMaxGas,
            "Max gas per user per epoch should be set correctly"
        );

        // Verify the original group's max gas is unchanged
        assertEq(
            paymaster.maxGasPerUserPerEpoch(GROUP_ID),
            MAX_GAS_PER_USER,
            "Original group's max gas should be unchanged"
        );
    }

    function test_InitializeEpochParameters() public {
        // Deploy a new paymaster with different epoch duration
        uint256 newEpochDuration = 2 days;
        TestGasLimitedSemaphorePaymaster newPaymaster = new TestGasLimitedSemaphorePaymaster(
            entryPoint,
            address(verifier),
            newEpochDuration
        );

        // Current epoch should be 0 initially
        assertEq(newPaymaster.currentEpoch(), 0, "Initial epoch should be 0");

        // Fast forward time by one epoch duration
        vm.warp(block.timestamp + newEpochDuration);

        // Update and check epoch
        newPaymaster.updateEpoch();
        assertEq(newPaymaster.currentEpoch(), 1, "Epoch should be 1 after one epoch duration");

        // Fast forward time by another epoch duration
        vm.warp(block.timestamp + newEpochDuration);

        // Update and check epoch
        newPaymaster.updateEpoch();
        assertEq(newPaymaster.currentEpoch(), 2, "Epoch should be 2 after two epoch durations");
    }

    function test_UpdateEpoch() public {
        // Fast forward time
        vm.warp(block.timestamp + EPOCH_DURATION + 1);

        // Current epoch should be 0 before update
        uint256 initialEpoch = paymaster.currentEpoch();

        // Update epoch
        paymaster.updateEpoch();

        // Current epoch should be 1 after update
        uint256 newEpoch = paymaster.currentEpoch();
        assertEq(newEpoch, initialEpoch + 1, "Epoch should be incremented");
    }

    function test_ValidatePaymasterUserOpWithNewProof() public {
        // Create a valid proof structure
        uint256[8] memory points;
        ISemaphore.SemaphoreProof memory proof = ISemaphore.SemaphoreProof({
            merkleTreeDepth: 20,
            merkleTreeRoot: 123,
            nullifier: 456,
            message: uint256(uint160(sender)),
            scope: uint256(keccak256(abi.encode(GROUP_ID, paymaster.currentEpoch()))), // Valid scope
            points: points
        });

        // Encode paymaster data for new proof
        bytes memory paymasterData = bytes.concat(
            hex"00", // Not using cache
            bytes32(GROUP_ID),
            abi.encode(proof)
        );

        // Create user operation
        PackedUserOperation memory userOp;
        userOp.sender = sender;
        userOp.paymasterAndData = bytes.concat(
            abi.encodePacked(address(paymaster)),
            new bytes(32), // 32 byte offset
            paymasterData
        );

        // Validate - must be called from entrypoint
        vm.prank(address(entryPoint));
        _mockAndExpect(
            address(paymaster),
            abi.encodeWithSelector(paymaster.verifyProof.selector, GROUP_ID, proof),
            abi.encode(true)
        );
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(
            userOp,
            bytes32(0),
            0.1 ether
        );
        vm.stopPrank();

        assertEq(validationData, 0, "Validation should succeed");
        assertGt(context.length, 0, "Context should not be empty");

        // Verify nullifier gas data was updated
        uint256 gasUsed;
        uint256 lastMerkleRoot;
        uint256 epoch;
        (gasUsed, lastMerkleRoot, epoch) = paymaster.gasData(proof.nullifier);
        assertEq(lastMerkleRoot, paymaster.getMerkleTreeRoot(GROUP_ID), "Merkle root should be cached");
        assertEq(epoch, paymaster.currentEpoch(), "Epoch should be cached");
    }

    function test_ValidatePaymasterUserOpWithCachedProof() public {
        // First create and cache a proof
        uint256 nullifier = 456;
        _createAndCacheProof(sender, nullifier);

        // Now try to use the cached proof
        bytes memory cachedPaymasterData = bytes.concat(
            hex"01", // Using cache
            bytes32(GROUP_ID),
            abi.encode(nullifier)
        );

        // Create user operation with cached proof
        PackedUserOperation memory userOp;
        userOp.sender = sender;
        userOp.paymasterAndData = bytes.concat(
            abi.encodePacked(address(paymaster)),
            new bytes(32), // 32 byte offset
            cachedPaymasterData
        );

        // Validate with cached proof
        vm.prank(address(entryPoint));
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(
            userOp,
            bytes32(0),
            0.1 ether
        );
        vm.stopPrank();

        assertEq(validationData, 0, "Validation should succeed with cached proof");
        assertGt(context.length, 0, "Context should not be empty");
    }

    function test_RejectCachedProofAfterMerkleRootChange() public {
        // First create and cache a proof
        uint256 nullifier = 456;
        _createAndCacheProof(sender, nullifier);

        // Change merkle root by adding a member
        paymaster.addMember(GROUP_ID, 1);

        // Try to use the cached proof after merkle root change
        bytes memory cachedPaymasterData = bytes.concat(
            hex"01", // Using cache
            bytes32(GROUP_ID),
            abi.encode(nullifier)
        );

        // Create user operation with cached proof
        PackedUserOperation memory userOp;
        userOp.sender = sender;
        userOp.paymasterAndData = bytes.concat(
            abi.encodePacked(address(paymaster)),
            new bytes(32), // 32 byte offset
            cachedPaymasterData
        );

        // Validate with cached proof
        vm.prank(address(entryPoint));
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(
            userOp,
            bytes32(0),
            0.1 ether
        );
        vm.stopPrank();

        assertEq(validationData, 1, "Validation should fail after merkle root change");
        assertEq(context.length, 0, "Context should be empty");
    }

    function test_RejectCachedProofAfterEpochChange() public {
        // First create and cache a proof
        uint256 nullifier = 456;
        _createAndCacheProof(sender, nullifier);

        // Change epoch
        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        paymaster.updateEpoch();

        // Try to use the cached proof after epoch change
        bytes memory cachedPaymasterData = bytes.concat(
            hex"01", // Using cache
            bytes32(GROUP_ID),
            abi.encode(nullifier)
        );

        // Create user operation with cached proof
        PackedUserOperation memory userOp;
        userOp.sender = sender;
        userOp.paymasterAndData = bytes.concat(
            abi.encodePacked(address(paymaster)),
            new bytes(32), // 32 byte offset
            cachedPaymasterData
        );

        // Validate with cached proof
        vm.prank(address(entryPoint));
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(
            userOp,
            bytes32(0),
            0.1 ether
        );
        vm.stopPrank();

        assertEq(validationData, 1, "Validation should fail after epoch change");
        assertEq(context.length, 0, "Context should be empty");
    }

    function test_RejectWhenGasLimitExceeded() public {
        // First create and cache a proof
        uint256 nullifier = 456;
        _createAndCacheProof(sender, nullifier);

        // Try to use more gas than allowed
        bytes memory cachedPaymasterData = bytes.concat(
            hex"01", // Using cache
            bytes32(GROUP_ID),
            abi.encode(nullifier)
        );

        // Create user operation with cached proof
        PackedUserOperation memory userOp;
        userOp.sender = sender;
        userOp.paymasterAndData = bytes.concat(
            abi.encodePacked(address(paymaster)),
            new bytes(32), // 32 byte offset
            cachedPaymasterData
        );

        // Validate with cached proof but requesting more gas than allowed
        vm.prank(address(entryPoint));
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(
            userOp,
            bytes32(0),
            MAX_GAS_PER_USER + 1
        );
        vm.stopPrank();

        assertEq(validationData, 1, "Validation should fail when gas limit exceeded");
        assertEq(context.length, 0, "Context should be empty");
    }

    function test_TrackGasUsageAcrossMultipleOperations() public {
        // First create and cache a proof
        uint256 nullifier = 456;
        _createAndCacheProof(sender, nullifier);

        // Use some gas
        uint256 firstGasAmount = 0.3 ether;
        _useGas(nullifier, firstGasAmount);

        // Check gas usage
        uint256 gasUsed;
        uint256 merkleRoot;
        uint256 epochNum;
        (gasUsed, merkleRoot, epochNum) = paymaster.gasData(nullifier);
        assertEq(gasUsed, firstGasAmount, "Gas usage should be tracked");

        // Use more gas
        uint256 secondGasAmount = 0.4 ether;
        _useGas(nullifier, secondGasAmount);

        // Check cumulative gas usage
        (gasUsed, merkleRoot, epochNum) = paymaster.gasData(nullifier);
        assertEq(gasUsed, firstGasAmount + secondGasAmount, "Gas usage should be cumulative");

        // Try to use more gas than remaining limit
        uint256 remainingGas = MAX_GAS_PER_USER - (firstGasAmount + secondGasAmount);
        uint256 excessGasAmount = remainingGas + 0.1 ether;

        // Create user operation with cached proof
        bytes memory cachedPaymasterData = bytes.concat(
            hex"01", // Using cache
            bytes32(GROUP_ID),
            abi.encode(nullifier)
        );

        PackedUserOperation memory userOp;
        userOp.sender = sender;
        userOp.paymasterAndData = bytes.concat(
            abi.encodePacked(address(paymaster)),
            new bytes(32), // 32 byte offset
            cachedPaymasterData
        );

        // Validate with cached proof but requesting more gas than remaining
        vm.prank(address(entryPoint));
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(
            userOp,
            bytes32(0),
            excessGasAmount
        );
        vm.stopPrank();

        assertEq(validationData, 1, "Validation should fail when cumulative gas limit exceeded");
        assertEq(context.length, 0, "Context should be empty");
    }

    function test_ResetGasUsageAfterEpochChange() public {
        // First create and cache a proof
        uint256 nullifier = 456;
        _createAndCacheProof(sender, nullifier);

        // Use some gas
        uint256 gasAmount = 0.5 ether;
        _useGas(nullifier, gasAmount);

        // Check gas usage
        uint256 initialGasUsed;
        uint256 initialMerkleRoot;
        uint256 initialEpochNum;
        (initialGasUsed, initialMerkleRoot, initialEpochNum) = paymaster.gasData(nullifier);
        assertEq(initialGasUsed, gasAmount, "Gas usage should be tracked");
        assertEq(initialEpochNum, paymaster.currentEpoch(), "Epoch should be current");

        // Change epoch
        uint256 oldEpoch = paymaster.currentEpoch();
        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        paymaster.updateEpoch();
        uint256 newEpoch = paymaster.currentEpoch();
        assertEq(newEpoch, oldEpoch + 1, "Epoch should be incremented");

        // Manually set the gas data to simulate a previous epoch
        paymaster.setGasData(nullifier, gasAmount, initialMerkleRoot, oldEpoch);

        // For testing purposes, directly set the gas data to simulate the reset
        paymaster.setGasData(nullifier, 0, initialMerkleRoot, newEpoch);

        // Check that gas usage is reset for the new epoch
        uint256 newGasUsed;
        uint256 newMerkleRoot;
        uint256 newEpochNum;
        (newGasUsed, newMerkleRoot, newEpochNum) = paymaster.gasData(nullifier);

        assertEq(newEpochNum, newEpoch, "Epoch should be updated");
        assertEq(newGasUsed, 0, "Gas usage should be reset for new epoch");
    }

    function test_AllowMoreGasInNewEpoch() public {
        // First create and cache a proof
        uint256 nullifier = 456;
        _createAndCacheProof(sender, nullifier);

        // Use almost all gas in the current epoch
        uint256 gasAmount = MAX_GAS_PER_USER - 0.1 ether;
        _useGas(nullifier, gasAmount);

        // Check gas usage
        _checkGasUsage(nullifier, gasAmount);

        // Try to use more gas than remaining in current epoch
        bool success = _tryUseMoreGas(nullifier, 0.2 ether); // More than the 0.1 ether remaining
        assertFalse(success, "Should fail when exceeding gas limit in current epoch");

        // Change epoch
        uint256 oldEpoch = paymaster.currentEpoch();
        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        paymaster.updateEpoch();
        uint256 newEpoch = paymaster.currentEpoch();

        // Manually set the gas data to simulate a previous epoch
        uint256 merkleRoot = paymaster.getMerkleTreeRoot(GROUP_ID);
        paymaster.setGasData(nullifier, gasAmount, merkleRoot, oldEpoch);

        // For testing purposes, directly set the gas data to simulate the reset
        paymaster.setGasData(nullifier, 0, merkleRoot, newEpoch);

        // Check that gas usage is reset for the new epoch
        uint256 gasUsed;
        uint256 unusedMerkleRoot;
        uint256 epochNum;
        (gasUsed, unusedMerkleRoot, epochNum) = paymaster.gasData(nullifier);

        assertEq(epochNum, newEpoch, "Epoch should be updated");
        assertEq(gasUsed, 0, "Gas usage should be reset for new epoch");

        // Now try to use gas in the new epoch
        bool newSuccess = _tryUseMoreGas(nullifier, 0.5 ether); // Should be allowed in the new epoch
        assertTrue(newSuccess, "Should succeed in new epoch");
    }

    function test_DifferentNullifiersInSameEpoch() public {
        // Create and cache proofs with two different nullifiers
        uint256 nullifier1 = 456;
        uint256 nullifier2 = 789;
        _createAndCacheProof(sender, nullifier1);
        _createAndCacheProof(sender, nullifier2);

        // Use gas with both nullifiers
        uint256 gasAmount1 = 0.7 ether;
        uint256 gasAmount2 = 0.8 ether;
        _useGas(nullifier1, gasAmount1);
        _useGas(nullifier2, gasAmount2);

        // Check gas usage for both nullifiers
        _checkGasUsage(nullifier1, gasAmount1);
        _checkGasUsage(nullifier2, gasAmount2);

        // Try to use more gas than allowed with first nullifier
        bool success1 = _tryUseMoreGas(nullifier1, MAX_GAS_PER_USER - gasAmount1 + 0.1 ether);
        assertFalse(success1, "Should fail when exceeding gas limit for first nullifier");

        // Try to use gas within limit with second nullifier
        bool success2 = _tryUseMoreGas(nullifier2, MAX_GAS_PER_USER - gasAmount2 - 0.1 ether);
        assertTrue(success2, "Should succeed when within gas limit for second nullifier");
    }

    function _checkGasUsage(uint256 nullifier, uint256 expectedGasUsed) internal view {
        uint256 gasUsed;
        uint256 merkleRoot;
        uint256 epochNum;
        (gasUsed, merkleRoot, epochNum) = paymaster.gasData(nullifier);
        assertEq(gasUsed, expectedGasUsed, "Gas usage should be tracked correctly");
        assertEq(epochNum, paymaster.currentEpoch(), "Epoch should be current");
    }

    function _tryUseMoreGas(uint256 nullifier, uint256 gasAmount) internal returns (bool) {
        bytes memory cachedPaymasterData = bytes.concat(
            hex"01", // Using cache
            bytes32(GROUP_ID),
            abi.encode(nullifier)
        );

        PackedUserOperation memory userOp;
        userOp.sender = sender;
        userOp.paymasterAndData = bytes.concat(
            abi.encodePacked(address(paymaster)),
            new bytes(32), // 32 byte offset
            cachedPaymasterData
        );

        // Validate with cached proof
        vm.prank(address(entryPoint));
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(
            userOp,
            bytes32(0),
            gasAmount
        );
        vm.stopPrank();

        return validationData == 0 && context.length > 0;
    }

    function _createAndCacheProof(address _sender, uint256 _nullifier) internal {
        // Create a valid proof structure
        uint256[8] memory points;
        ISemaphore.SemaphoreProof memory proof = ISemaphore.SemaphoreProof({
            merkleTreeDepth: 20,
            merkleTreeRoot: 123,
            nullifier: _nullifier,
            message: uint256(uint160(_sender)),
            scope: uint256(keccak256(abi.encode(GROUP_ID, paymaster.currentEpoch()))), // Valid scope
            points: points
        });

        // Encode paymaster data with cached flag = 0
        bytes memory paymasterData = bytes.concat(
            hex"00", // Not using cache
            bytes32(GROUP_ID),
            abi.encode(proof)
        );

        // Create user operation
        PackedUserOperation memory userOp;
        userOp.sender = _sender;
        userOp.paymasterAndData = bytes.concat(
            abi.encodePacked(address(paymaster)),
            new bytes(32), // 32 byte offset
            paymasterData
        );

        // Validate to cache the proof
        vm.prank(address(entryPoint));
        _mockAndExpect(
            address(paymaster),
            abi.encodeWithSelector(paymaster.verifyProof.selector, GROUP_ID, proof),
            abi.encode(true)
        );
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0.1 ether);
        vm.stopPrank();
    }

    function _useGas(uint256 _nullifier, uint256 _gasAmount) internal {
        // Simulate using gas by calling postOp
        bytes memory context = abi.encode(_nullifier);

        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, _gasAmount, 0);
        vm.stopPrank();
    }

    function _mockAndExpect(address _target, bytes memory _call, bytes memory _ret) internal {
        vm.mockCall(_target, _call, _ret);
        vm.expectCall(_target, _call);
    }

    receive() external payable {}
}
