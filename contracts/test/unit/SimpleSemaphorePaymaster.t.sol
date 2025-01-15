// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {SimpleSemaphorePaymaster} from "../../src/SimpleSemaphorePaymaster.sol";
import {AlwaysValidVerifier} from "../../src/mocks/AlwaysValidVerifier.sol";
import {EntryPoint} from "@account-abstraction/contracts/core/EntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {ISemaphore} from "@semaphore-protocol/contracts/interfaces/ISemaphore.sol";
import {IPaymaster} from "@account-abstraction/contracts/interfaces/IPaymaster.sol";

contract SimpleSemaphorePaymasterTest is Test {
    SimpleSemaphorePaymaster public paymaster;
    AlwaysValidVerifier public verifier;
    address public entryPoint;
    address public sender = address(0x1234);
    uint256 public constant GROUP_ID = 0;

    function setUp() public {
        // Deploy mock contracts
        entryPoint = address(new EntryPoint());
        verifier = new AlwaysValidVerifier();

        // Deploy paymaster
        paymaster = new SimpleSemaphorePaymaster(entryPoint, address(verifier));

        // Create group and fund it
        paymaster.createGroup();
        paymaster.depositForGroup{value: 10 ether}(GROUP_ID);
        paymaster.addStake{value: 1 ether}(1);
    }

    function test_sample() public {}

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

    function test_RevertZeroDeposit() public {
        vm.expectRevert("Must deposit non-zero amount");
        paymaster.depositForGroup{value: 0}(GROUP_ID);
    }

    function test_ValidatePaymasterUserOp() public {
        // Create a valid proof structure
        uint256[8] memory points;
        ISemaphore.SemaphoreProof memory proof = ISemaphore.SemaphoreProof({
            merkleTreeDepth: 20,
            merkleTreeRoot: 123,
            nullifier: 456,
            message: uint256(keccak256(abi.encode(sender, 0))), // Valid message
            scope: 0,
            points: points
        });

        // Encode paymaster data
        bytes memory paymasterData = abi.encode(
            SimpleSemaphorePaymaster.PaymasterData({groupId: GROUP_ID, proof: proof})
        );

        // Create user operation
        PackedUserOperation memory userOp;
        userOp.sender = sender;
        userOp.nonce = 0;

        // Need to account for 52 bytes that are skipped in decoding:
        // 20 bytes paymaster address + 32 bytes offset
        userOp.paymasterAndData = bytes.concat(
            abi.encodePacked(address(paymaster)),
            new bytes(32), // 32 byte offset
            paymasterData
        );

        // Validate - must be called from entrypoint
        vm.prank(address(entryPoint));
        _mockAndExpect(address(paymaster), abi.encodeWithSelector(paymaster.verifyProof.selector), abi.encode(true));
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(userOp, bytes32(0), 1 ether);
        vm.stopPrank();

        assertEq(validationData, 0, "Validation should succeed");
        assertGt(context.length, 0, "Context should not be empty");
    }

    function test_RevertInsufficientGroupBalance() public {
        // Create proof with valid message
        uint256[8] memory points;
        ISemaphore.SemaphoreProof memory proof = ISemaphore.SemaphoreProof({
            merkleTreeDepth: 20,
            merkleTreeRoot: 123,
            nullifier: 456,
            message: uint256(keccak256(abi.encode(sender, 0))),
            scope: 0,
            points: points
        });

        bytes memory paymasterData = abi.encode(
            SimpleSemaphorePaymaster.PaymasterData({
                groupId: 1, // Use non-existent group
                proof: proof
            })
        );

        PackedUserOperation memory userOp;
        userOp.sender = sender;
        userOp.nonce = 0;
        userOp.paymasterAndData = bytes.concat(
            abi.encodePacked(address(paymaster)),
            new bytes(32), // 32 byte offset
            paymasterData
        );

        vm.prank(address(entryPoint));
        (, uint256 validationData) = paymaster.validatePaymasterUserOp(userOp, bytes32(0), 1 ether);
        vm.stopPrank();

        assertTrue(validationData > 0, "Validation should fail for insufficient balance");
    }

    function test_PostOp() public {
        uint256 initialDeposit = paymaster.groupDeposits(GROUP_ID);
        uint256 gasCost = 0.1 ether;

        // Create valid proof and context
        uint256[8] memory points;
        ISemaphore.SemaphoreProof memory proof = ISemaphore.SemaphoreProof({
            merkleTreeDepth: 20,
            merkleTreeRoot: 123,
            nullifier: 456,
            message: uint256(keccak256(abi.encode(sender, 0))),
            scope: 0,
            points: points
        });

        bytes memory context = abi.encode(SimpleSemaphorePaymaster.PaymasterData({groupId: GROUP_ID, proof: proof}));

        // Execute postOp
        vm.prank(address(entryPoint));
        _mockAndExpect(address(paymaster), abi.encodeCall(paymaster.validateProof, (GROUP_ID, proof)), "");
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
