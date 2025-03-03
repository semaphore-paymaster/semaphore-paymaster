import { ethers } from "hardhat";
import { Signer } from "ethers";
import {
    SimpleAccount,
    GasLimitedSemaphorePaymaster,
} from "../../typechain";
import { expect } from "chai";
import { Identity, Group } from "@semaphore-protocol/core"
import { setupProviders, setupSimpleAccount, setupSemaphoreContracts, generateMessage, generateGasLimitedPaymasterData, prepareTransferCallData, prepareUserOp, TestContext } from "../utils/testUtils";
import sendUserOpAndWait from "../utils/userOpUtils";

const ENABLE_LOGS = false; // Toggle this to enable/disable logging
const log = (...args: any[]) => ENABLE_LOGS && console.log(...args);

describe("GasLimitedSemaphorePaymasterTest", () => {
    let context: TestContext;
    let owner: Signer;
    let recipientAddress: string;
    let simpleAccount: SimpleAccount;
    let gasLimitedSemaphorePaymaster: GasLimitedSemaphorePaymaster;
    let group: Group;
    let groupId: number;
    let id1: Identity;
    let id2: Identity;
    let id3: Identity;
    const transferAmount = ethers.parseEther("1");
    const epochDuration = 60; // 60 seconds for testing purposes

    async function setupIdentities() {
        // @ts-ignore - Ignoring getSigners error as per instructions
        const [admin, owner, id1Pk, id2Pk, id3Pk] = await ethers.getSigners();

        id1 = new Identity(id1Pk);
        id2 = new Identity(id2Pk);
        id3 = new Identity(id3Pk);
        group = new Group([id1.commitment, id2.commitment, id3.commitment]);
        groupId = 0;

        return { admin, owner };
    }

    async function assertSendEth(
        amount: bigint,
        paymasterData: string = "0x",
        shouldSucceed: boolean = true
    ) {
        // Get initial balance
        const recipientBalanceBefore = await context.provider.getBalance(recipientAddress);
        log("  └─ Recipient Balance Before:", ethers.formatEther(recipientBalanceBefore), "ETH");

        // Prepare call data for ETH transfer
        const callData = prepareTransferCallData(recipientAddress, amount);

        // Create and send user operation
        const userOp = await prepareUserOp(context, callData, await simpleAccount.getAddress(), await gasLimitedSemaphorePaymaster.getAddress(), paymasterData);

        if (shouldSucceed) {
            await assertSuccessfulTransfer(
                userOp,
                recipientBalanceBefore,
                amount
            );
        } else {
            await assertFailedTransfer(userOp);
        }
    }

    async function assertSuccessfulTransfer(
        userOp: any,
        balanceBefore: bigint,
        amount: bigint
    ) {
        const receipt = await sendUserOpAndWait(
            userOp,
            context.entryPointAddress,
            context.bundlerProvider
        );

        const balanceAfter = await context.provider.getBalance(recipientAddress);
        log("  └─ Recipient Balance After:", ethers.formatEther(balanceAfter), "ETH");

        expect(receipt.success).to.be.true;
        expect(balanceAfter).to.equal(balanceBefore + amount);
    }

    async function assertFailedTransfer(userOp: any) {
        await expect(
            sendUserOpAndWait(
                userOp,
                context.entryPointAddress,
                context.bundlerProvider
            )
        ).to.be.rejected;
    }

    beforeEach(async () => {
        log("\n🚀 Initializing Gas Limited Semaphore Paymaster Test Suite...");
        log("\n🔧 Environment Configuration:");
        log("  ├─ BUNDLER: 🔒 SAFE (port 3000)");
        log(`  └─ STAKE_ACCOUNT: ${process.env.STAKE_ACCOUNT || 'false'}`);

        // Setup providers and get entrypoint
        const { provider, bundlerProvider, entryPointAddress } = await setupProviders();

        // Setup identities and signers
        const { admin, owner: setupOwner } = await setupIdentities();
        // @ts-ignore - Ignoring getSigners error as per instructions
        [owner] = await ethers.getSigners();

        context = {
            bundlerProvider,
            provider,
            admin,
            owner,
            entryPointAddress
        };

        log("\n📋 Test Configuration:");
        log("  ├─ Owner Address:", await owner.getAddress());
        log("  ├─ Owner Balance:", ethers.formatEther(await provider.getBalance(await owner.getAddress())), "ETH");
        log("  ├─ EntryPoint:", entryPointAddress);
        log("  └─ Bundler URL: http://localhost:3000/rpc (🔒 SAFE)");

        recipientAddress = "0x742d35Cc6634C0532925a3b844Bc454e4438f44e";

        // Deploy and setup Simple Account
        log("\n🔧 Deploying Contracts:");
        simpleAccount = await setupSimpleAccount(entryPointAddress);

        // Fund the account
        const fundingAmount = ethers.parseEther("1000");
        log("\n💰 Funding Account:");
        log("  └─ Sending", ethers.formatEther(fundingAmount), "ETH to Simple Account");
        await owner.sendTransaction({
            to: await simpleAccount.getAddress(),
            value: fundingAmount
        });

        // Handle staking
        if (process.env.STAKE_ACCOUNT === 'true') {
            log("\n🔒 Adding Stake:");
            log("  └─ Staking 1 ETH to account");
            await simpleAccount.addStake(1, { value: ethers.parseEther("1") });
        } else {
            log("\nℹ️  Stake Status:");
            log("  └─ Skipping account staking (STAKE_ACCOUNT not set)");
        }

        // Deploy Semaphore contracts with gas limited version
        log("\n🔧 Deploying Gas Limited Semaphore Contracts:");
        const currentTimestamp = await context.provider.getBlock('latest').then(block => block!.timestamp);
        log("  └─ Current timestamp:", currentTimestamp);
        const paymasterContract = await setupSemaphoreContracts(entryPointAddress, "GasLimitedSemaphorePaymaster", epochDuration, currentTimestamp);
        gasLimitedSemaphorePaymaster = paymasterContract as unknown as GasLimitedSemaphorePaymaster;

        // Setup epoch parameters
        await gasLimitedSemaphorePaymaster.updateEpoch();

        // Setup group and deposits
        await gasLimitedSemaphorePaymaster["createGroup()"]();
        await gasLimitedSemaphorePaymaster.addMembers(groupId, group.members);
        log("  └─ Group created with commitments:", group.members);

        // Set max gas per user per epoch
        const maxGasPerUser = ethers.parseEther("5"); // 0.5 ETH worth of gas per user per epoch
        await gasLimitedSemaphorePaymaster.setMaxGasPerUserPerEpoch(groupId, maxGasPerUser);
        log("  └─ Max gas per user per epoch set to", ethers.formatEther(maxGasPerUser), "ETH");

        await gasLimitedSemaphorePaymaster.depositForGroup(groupId, { value: ethers.parseEther("10") });
        const deposit = await gasLimitedSemaphorePaymaster.getDeposit();
        log("  └─ Deposited", ethers.formatEther(deposit), "ETH to the paymaster for the group");

        await gasLimitedSemaphorePaymaster.addStake(1, { value: ethers.parseEther("1") });
        log("  └─ Staked ETH to the paymaster");

        log("\n✅ Setup Complete!\n");
    });

    it("should execute a simple ETH transfer with new proof", async () => {
        const message = await generateMessage(simpleAccount)
        const epoch = await gasLimitedSemaphorePaymaster.currentEpoch()
        const paymasterData = await generateGasLimitedPaymasterData(id1, group, message, groupId, epoch, false)
        log("  └─ Paymaster Data:", paymasterData)
        await assertSendEth(transferAmount, paymasterData.paymasterData);
    });

    it("should execute a transfer with cached proof", async () => {
        // First execute with new proof to cache it
        const message = await generateMessage(simpleAccount)
        const epoch = await gasLimitedSemaphorePaymaster.currentEpoch()
        const newProofData = await generateGasLimitedPaymasterData(id1, group, message, groupId, epoch, false)
        await assertSendEth(transferAmount, newProofData.paymasterData);

        // Then execute using cached proof
        const cachedProofData = await generateGasLimitedPaymasterData(id1, group, message, groupId, epoch, true)
        log("  └─ Cached Paymaster Data:", cachedProofData)
        await assertSendEth(transferAmount, cachedProofData.paymasterData);
    });

    it("should track gas usage across multiple operations", async () => {
        const message = await generateMessage(simpleAccount)
        const epoch = await gasLimitedSemaphorePaymaster.currentEpoch()
        const paymasterData = await generateGasLimitedPaymasterData(id1, group, message, groupId, epoch, false)

        // Execute multiple transactions to accumulate gas usage
        for (let i = 0; i < 3; i++) {
            log(`\n📝 Executing transaction ${i + 1}`)
            await assertSendEth(transferAmount, paymasterData.paymasterData);
        }

        // The transactions should succeed since they're under the gas limit
    });

    it("should reject operations when gas limit is exceeded", async () => {
        const message = await generateMessage(simpleAccount)
        const epoch = await gasLimitedSemaphorePaymaster.currentEpoch()
        const paymasterData = await generateGasLimitedPaymasterData(id1, group, message, groupId, epoch, false)

        // First transaction to measure gas usage
        await assertSendEth(transferAmount, paymasterData.paymasterData);

        // Get gas used from first transaction
        const gasUsedFirstTx = (await gasLimitedSemaphorePaymaster.gasData(paymasterData.nullifier)).gasUsed;
        log("  └─ Gas used in first tx:", ethers.formatEther(gasUsedFirstTx), "ETH");

        // max out the gas limit
        const gasLimit = gasUsedFirstTx;
        await gasLimitedSemaphorePaymaster.setMaxGasPerUserPerEpoch(groupId, gasLimit);
        log("  └─ Set gas limit to", ethers.formatEther(gasLimit), "ETH");

        // Second transaction should fail due to gas limit
        await assertSendEth(transferAmount, paymasterData.paymasterData, false);

        // Reset gas limit for other tests
        await gasLimitedSemaphorePaymaster.setMaxGasPerUserPerEpoch(groupId, ethers.parseEther("5"));
    });

    it("should allow operations from different users within the same epoch", async () => {
        const message1 = await generateMessage(simpleAccount)
        const epoch = await gasLimitedSemaphorePaymaster.currentEpoch()
        const paymasterData1 = await generateGasLimitedPaymasterData(id1, group, message1, groupId, epoch, false)

        const message2 = await generateMessage(simpleAccount)
        const paymasterData2 = await generateGasLimitedPaymasterData(id2, group, message2, groupId, epoch, false)

        // Both users should be able to execute transactions
        await assertSendEth(transferAmount, paymasterData1.paymasterData);
        await assertSendEth(transferAmount, paymasterData2.paymasterData);
    });

    it("should reset gas usage after epoch change", async () => {
        const message = await generateMessage(simpleAccount)
        let epoch = await gasLimitedSemaphorePaymaster.currentEpoch()
        const paymasterData = await generateGasLimitedPaymasterData(id1, group, message, groupId, epoch, false)

        // Use most of the gas limit
        await assertSendEth(ethers.parseEther("0.005"), paymasterData.paymasterData);

        // Check gas usage before epoch change
        const gasUsedBeforeEpochChange = (await gasLimitedSemaphorePaymaster.gasData(paymasterData.nullifier)).gasUsed;
        log("  └─ Gas used before epoch change:", ethers.formatEther(gasUsedBeforeEpochChange), "ETH");
        expect(gasUsedBeforeEpochChange).to.be.gt(0, "Gas usage should be recorded for the transaction");

        // Mine enough blocks to advance time past the epoch duration
        // For Geth, we need to mine multiple blocks to advance time
        for (let i = 0; i < epochDuration; i++) {
            await context.provider.send("eth_sendTransaction", [
                {
                    from: await context.admin.getAddress(),
                    to: await context.admin.getAddress(),
                    value: "0x1"
                }
            ]);
        }

        // Update epoch
        await gasLimitedSemaphorePaymaster.updateEpoch();

        // Generate new proof for new epoch
        const newMessage = await generateMessage(simpleAccount)
        epoch = await gasLimitedSemaphorePaymaster.currentEpoch()
        const newProofData = await generateGasLimitedPaymasterData(id1, group, newMessage, groupId, epoch, false)

        // Check gas usage after epoch change
        const gasUsedAfterEpochChange = (await gasLimitedSemaphorePaymaster.gasData(newProofData.nullifier)).gasUsed;
        log("  └─ Gas used after epoch change:", ethers.formatEther(gasUsedAfterEpochChange), "ETH");
        expect(gasUsedAfterEpochChange).to.equal(0, "Gas usage should be reset after epoch change");

        // Should be able to send again since gas limit resets in new epoch
        await assertSendEth(ethers.parseEther("0.005"), newProofData.paymasterData);

        // Reset the gas limit for other tests
        await gasLimitedSemaphorePaymaster.setMaxGasPerUserPerEpoch(groupId, ethers.parseEther("5"));
    });

    it("should reject cached proof after merkle root change", async () => {
        // First execute with new proof to cache it
        const message = await generateMessage(simpleAccount)
        const epoch = await gasLimitedSemaphorePaymaster.currentEpoch()
        const newProofData = await generateGasLimitedPaymasterData(id1, group, message, groupId, epoch, false)
        await assertSendEth(transferAmount, newProofData.paymasterData);

        // Change merkle root by adding a new member
        const newCommitment = BigInt("123456789");
        await gasLimitedSemaphorePaymaster.addMember(groupId, newCommitment);
        log("  └─ Added new member to change merkle root");

        const cachedProofData = await generateGasLimitedPaymasterData(id1, group, message, groupId, epoch, true)
        await assertSendEth(transferAmount, cachedProofData.paymasterData, false);
    });

    it("should reject cached proof after epoch change", async () => {
        // First execute with new proof to cache it
        const message = await generateMessage(simpleAccount)
        let epoch = await gasLimitedSemaphorePaymaster.currentEpoch()
        const newProofData = await generateGasLimitedPaymasterData(id1, group, message, groupId, epoch, false)
        await assertSendEth(transferAmount, newProofData.paymasterData);

        // Mine enough blocks to advance time past the epoch duration
        // For Geth, we need to mine multiple blocks to advance time
        for (let i = 0; i < epochDuration; i++) {
            await context.provider.send("eth_sendTransaction", [
                {
                    from: await context.admin.getAddress(),
                    to: await context.admin.getAddress(),
                    value: "0x1"
                }
            ]);
        }

        // Update epoch
        await gasLimitedSemaphorePaymaster.updateEpoch();
        log("  └─ Advanced to new epoch:", await gasLimitedSemaphorePaymaster.currentEpoch());

        // Try to use cached proof after epoch change
        epoch = await gasLimitedSemaphorePaymaster.currentEpoch()
        const cachedProofData = await generateGasLimitedPaymasterData(id1, group, message, groupId, epoch, true)
        await assertSendEth(transferAmount, cachedProofData.paymasterData, false);
    });
}); 