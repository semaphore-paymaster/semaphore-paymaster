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
        const paymasterContract = await setupSemaphoreContracts(entryPointAddress, "GasLimitedSemaphorePaymaster", epochDuration);
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
        const paymasterData = await generateGasLimitedPaymasterData(id1, group, message, groupId, false)
        log("  └─ Paymaster Data:", paymasterData)
        await assertSendEth(transferAmount, paymasterData);
    });

}); 