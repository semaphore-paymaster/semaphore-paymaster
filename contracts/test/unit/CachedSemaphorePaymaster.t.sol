// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {CachedSemaphorePaymaster} from "../../src/CachedSemaphorePaymaster.sol";
import {AlwaysValidVerifier} from "../../src/mocks/AlwaysValidVerifier.sol";
import {EntryPoint} from "@account-abstraction/contracts/core/EntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {ISemaphore} from "@semaphore-protocol/contracts/interfaces/ISemaphore.sol";
import {IPaymaster} from "@account-abstraction/contracts/interfaces/IPaymaster.sol";

contract CachedSemaphorePaymasterTest is Test {
    CachedSemaphorePaymaster public paymaster;
    AlwaysValidVerifier public verifier;
    address public entryPoint;
    address public sender = address(0x1234);
    uint256 public constant GROUP_ID = 0;

    function setUp() public {
        // Deploy mock contracts
        entryPoint = address(new EntryPoint());
        verifier = new AlwaysValidVerifier();

        // Deploy paymaster
        paymaster = new CachedSemaphorePaymaster(entryPoint, address(verifier));

        // Create group and fund it
        paymaster.createGroup();
        paymaster.depositForGroup{value: 10 ether}(GROUP_ID);
        paymaster.addStake{value: 1 ether}(1);
    }

    function test_DepositForGroup() public {
        uint256 initialDeposit = paymaster.groupDeposits(GROUP_ID);
        uint256 depositAmount = 5 ether;

        paymaster.depositForGroup{value: depositAmount}(GROUP_ID);

        assertEq(
            paymaster.groupDeposits(GROUP_ID),
            initialDeposit + depositAmount,
            "Deposit amount should be added to group balance"
        );
    }

    function _createAndCacheProof(address _sender) internal {
        // Create a valid proof structure
        uint256[8] memory points;
        ISemaphore.SemaphoreProof memory proof = ISemaphore.SemaphoreProof({
            merkleTreeDepth: 20,
            merkleTreeRoot: 123,
            nullifier: 456,
            message: uint256(uint160(_sender)),
            scope: 0,
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
        _mockAndExpect(address(paymaster), abi.encodeWithSelector(paymaster.verifyProof.selector), abi.encode(true));
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 1 ether);
        vm.stopPrank();
    }

    function test_ValidatePaymasterUserOpWithNewProof() public {
        _createAndCacheProof(sender);

        // Verify proof was cached
        bool hasValidCachedProof = paymaster.isValidCachedProof(sender, GROUP_ID);
        assertTrue(hasValidCachedProof, "Proof should be cached");
    }

    function test_ValidatePaymasterUserOpWithCachedProof() public {
        _createAndCacheProof(sender);

        bytes memory cachedPaymasterData = bytes.concat(
            hex"01", // Using cache
            bytes32(GROUP_ID)
        );

        // Create user operation
        PackedUserOperation memory userOp2;
        userOp2.sender = sender;
        userOp2.paymasterAndData = bytes.concat(
            abi.encodePacked(address(paymaster)),
            new bytes(32), // 32 byte offset
            cachedPaymasterData
        );

        // Validate with cached proof
        vm.prank(address(entryPoint));
        (, uint256 validationData2) = paymaster.validatePaymasterUserOp(userOp2, bytes32(0), 1 ether);
        vm.stopPrank();

        assertEq(validationData2, 0, "Validation should succeed with cached proof");
    }

    function test_CachedProofInvalidAfterMerkleRootChange() public {
        _createAndCacheProof(sender);

        // add member to group to change merkle root
        paymaster.addMember(GROUP_ID, 1);

        bool isValidCachedProof = paymaster.isValidCachedProof(sender, GROUP_ID);
        assertFalse(isValidCachedProof, "Proof should be invalid after merkle root change");

        // Try using cached proof after merkle root change
        bytes memory cachedPaymasterData = bytes.concat(
            hex"01", // Using cache
            bytes32(GROUP_ID)
        );

        PackedUserOperation memory userOp2;
        userOp2.sender = sender;
        userOp2.paymasterAndData = bytes.concat(
            abi.encodePacked(address(paymaster)),
            new bytes(32),
            cachedPaymasterData
        );

        // Validate with cached proof against new merkle root
        vm.prank(address(entryPoint));
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(
            userOp2,
            bytes32(0),
            1 ether
        );
        vm.stopPrank();

        assertEq(validationData, 1, "Validation should fail with cached proof after merkle root update");
        assertEq(context.length, 0, "Context should be empty");
    }

    function test_PostOp() public {
        uint256 initialDeposit = paymaster.groupDeposits(GROUP_ID);
        uint256 gasCost = 0.1 ether;

        bytes memory context = abi.encode(GROUP_ID);

        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, gasCost, 0);
        vm.stopPrank();

        assertEq(
            paymaster.groupDeposits(GROUP_ID),
            initialDeposit - gasCost,
            "Gas cost should be deducted from group deposit"
        );
    }

    function _mockAndExpect(address _target, bytes memory _call, bytes memory _ret) internal {
        vm.mockCall(_target, _call, _ret);
        vm.expectCall(_target, _call);
    }

    receive() external payable {}
}
