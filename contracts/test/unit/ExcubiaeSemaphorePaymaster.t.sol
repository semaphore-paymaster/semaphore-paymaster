// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, Vm} from "forge-std/Test.sol";
import {ExcubiaePaymaster} from "../../src/ExcubiaePaymaster.sol";
import {ExcubiaeSemaphorePaymaster} from "../../src/ExcubiaeSemaphorePaymaster.sol";
import {SemaphoreMock} from "@excubiae/contracts/contracts/test/extensions/mocks/SemaphoreMock.sol";
import {SemaphoreChecker} from "@excubiae/contracts/contracts/extensions/semaphore/SemaphoreChecker.sol";
import {SemaphoreCheckerFactory} from "@excubiae/contracts/contracts/extensions/semaphore/SemaphoreCheckerFactory.sol";
import {SemaphorePolicy} from "@excubiae/contracts/contracts/extensions/semaphore/SemaphorePolicy.sol";
import {SemaphorePolicyFactory} from "@excubiae/contracts/contracts/extensions/semaphore/SemaphorePolicyFactory.sol";
import {EntryPoint} from "@account-abstraction/contracts/core/EntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {ISemaphore} from "@semaphore-protocol/contracts/interfaces/ISemaphore.sol";
import {IPaymaster} from "@account-abstraction/contracts/interfaces/IPaymaster.sol";

contract ExcubiaeSemaphorePaymasterTest is Test {
    ExcubiaeSemaphorePaymaster public paymaster;
    SemaphoreMock internal semaphoreMock;
    SemaphoreChecker internal checker;
    SemaphoreCheckerFactory internal checkerFactory;
    SemaphorePolicy internal policy;
    SemaphorePolicyFactory internal policyFactory;
    ISemaphore.SemaphoreProof public validProof;
    ISemaphore.SemaphoreProof public invalidProof;
    address public entryPoint;
    address public deployer = vm.addr(0x1);
    address public sender = vm.addr(0x2);
    uint256 public validGroupId = 0;
    uint256 public invalidGroupId = 1;

    function setUp() public {
        vm.startPrank(deployer);
        vm.deal(deployer, 100 ether);

        // Deploy mock contracts
        entryPoint = address(new EntryPoint());
        checkerFactory = new SemaphoreCheckerFactory();
        policyFactory = new SemaphorePolicyFactory();

        validProof = ISemaphore.SemaphoreProof({
                merkleTreeDepth: 20,
                merkleTreeRoot: 123,
                nullifier: 456,
                message: uint256(uint160(sender)),
                scope: ((uint256(uint160(entryPoint)) << 96) | uint256(validGroupId)),
                points: [uint256(0), uint256(0), uint256(0), uint256(0), uint256(0), uint256(0), uint256(0), uint256(0)]
        });
        invalidProof = ISemaphore.SemaphoreProof({
            merkleTreeDepth: 20,
                merkleTreeRoot: 123,
                nullifier: 456,
            message: uint256(uint160(sender)),
            scope: ((uint256(uint160(entryPoint)) << 96) | uint256(invalidGroupId)),
            points: [uint256(1), uint256(0), uint256(0), uint256(0), uint256(0), uint256(0), uint256(0), uint256(0)]
        });

        uint256[] memory groupIds = new uint256[](1);
        uint256[] memory nullifiers = new uint256[](2);
        bool[] memory nullifiersValidities = new bool[](2);
        groupIds[0] = validProof.scope;
        nullifiers[0] = validProof.nullifier;
        nullifiers[1] = invalidProof.nullifier;
        nullifiersValidities[0] = true;
        nullifiersValidities[1] = false;

        semaphoreMock = new SemaphoreMock(groupIds, nullifiers, nullifiersValidities);

        vm.recordLogs();
        checkerFactory.deploy(address(semaphoreMock), validGroupId);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        address checkerClone = address(uint160(uint256(entries[0].topics[1])));
        checker = SemaphoreChecker(checkerClone);

        vm.recordLogs();
        policyFactory.deploy(address(checker));
        entries = vm.getRecordedLogs();
        address policyClone = address(uint160(uint256(entries[0].topics[1])));
        policy = SemaphorePolicy(policyClone);
        
        // Deploy paymaster
        paymaster = new ExcubiaeSemaphorePaymaster(entryPoint, address(policy));

        // Set policy's target - paymaster has policy, i.e., policy must be called from paymaster
        policy.setTarget(address(paymaster));

        // Create group and fund it
        assertEq(semaphoreMock.createGroup(), 0);
        paymaster.depositForGroup{value: 10 ether}(validGroupId);
        paymaster.addStake{value: 1 ether}(1);
        
        vm.stopPrank();
    }

    function test_PolicyDeployedAndInitialized() public view {
        assertEq(address(paymaster.POLICY()), address(policy));
        assertEq(policy.initialized(), true);
    }

    function test_DepositForGroup() public {
        uint256 initialDeposit = paymaster.groupDeposits(validGroupId);
        uint256 depositAmount = 5 ether;

        paymaster.depositForGroup{value: depositAmount}(validGroupId);

        assertEq(
            paymaster.groupDeposits(validGroupId),
            initialDeposit + depositAmount,
            "Deposit amount should be added to group balance"
        );
    }

    function test_RevertZeroDeposit() public {
        vm.expectRevert("Must deposit non-zero amount");
        paymaster.depositForGroup{value: 0}(validGroupId);
    }

    function test_ValidatePaymasterUserOp() public {
        // Encode paymaster data
        bytes memory paymasterData = abi.encode(
            ExcubiaePaymaster.PaymasterData({groupId: validGroupId, proof: abi.encode(validProof)})
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
        vm.prank(entryPoint);
        _mockAndExpect(
            address(semaphoreMock),
            abi.encodeWithSelector(semaphoreMock.verifyProof.selector, validProof.scope, validProof),
            abi.encode(true)
        );
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(userOp, bytes32(0), 1 ether);
        vm.stopPrank();

        assertEq(validationData, 0, "Validation should succeed");
        assertGt(context.length, 0, "Context should not be empty");
    }

    function test_RevertInsufficientGroupBalance() public {
        bytes memory paymasterData = abi.encode(
            ExcubiaePaymaster.PaymasterData({
                groupId: invalidGroupId,
                proof: abi.encode(validProof)
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

        vm.prank(entryPoint);
        (, uint256 validationData) = paymaster.validatePaymasterUserOp(userOp, bytes32(0), 1 ether);
        vm.stopPrank();

        assertTrue(validationData > 0, "Validation should fail for insufficient balance");
    }

    function test_PostOp() public {
        uint256 initialDeposit = paymaster.groupDeposits(validGroupId);
        uint256 gasCost = 0.1 ether;

        bytes memory context = abi.encode(validGroupId);

        // Execute postOp
        vm.prank(entryPoint);
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, gasCost, 0);
        vm.stopPrank();

        assertEq(
            paymaster.groupDeposits(validGroupId),
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
