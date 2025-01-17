import { ethers } from "hardhat";
import { Signer } from "ethers";
import {
  SimpleAccount,
  CachedSemaphorePaymaster,
} from "../../typechain";
import { expect } from "chai";
import { Identity, Group } from "@semaphore-protocol/core"
import { setupProviders, setupSimpleAccount, setupSemaphoreContracts, generateMessage, generatePaymasterData, prepareTransferCallData, prepareUserOp, TestContext, generateCachedPaymasterData } from "../utils/testUtils";
import sendUserOpAndWait from "../utils/userOpUtils";

const ENABLE_LOGS = false; // Toggle this to enable/disable logging
const log = (...args: any[]) => ENABLE_LOGS && console.log(...args);

describe("CachedSemaphorePaymasterTest", () => {
  let context: TestContext;
  let owner: Signer;
  let recipientAddress: string;
  let simpleAccount: SimpleAccount;
  let cachedSemaphorePaymaster: CachedSemaphorePaymaster;
  let group: Group;
  let groupId: number;
  let id1: Identity;
  let id2: Identity;
  let id3: Identity;
  const transferAmount = ethers.parseEther("1");

  async function setupIdentities() {
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
    const userOp = await prepareUserOp(context, callData, await simpleAccount.getAddress(), await cachedSemaphorePaymaster.getAddress(), paymasterData);

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
    log("\n🚀 Initializing Cached Semaphore Paymaster Test Suite...");
    log("\n🔧 Environment Configuration:");
    log("  ├─ BUNDLER: 🔒 SAFE (port 3000)");
    log(`  └─ STAKE_ACCOUNT: ${process.env.STAKE_ACCOUNT || 'false'}`);

    // Setup providers and get entrypoint
    const { provider, bundlerProvider, entryPointAddress } = await setupProviders();

    // Setup identities and signers
    const { admin, owner: setupOwner } = await setupIdentities();
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

    // Deploy Semaphore contracts with cached version
    log("\n🔧 Deploying Cached Semaphore Contracts:");
    cachedSemaphorePaymaster = (await setupSemaphoreContracts(entryPointAddress, true)) as CachedSemaphorePaymaster;

    // Setup group and deposits
    await cachedSemaphorePaymaster["createGroup()"]();
    await cachedSemaphorePaymaster.addMembers(groupId, group.members);
    log("  └─ Group created with commitments:", group.members);

    await cachedSemaphorePaymaster.depositForGroup(groupId, { value: ethers.parseEther("10") });
    const deposit = await cachedSemaphorePaymaster.getDeposit();
    log("  └─ Deposited", ethers.formatEther(deposit), "ETH to the paymaster for the group");

    await cachedSemaphorePaymaster.addStake(1, { value: ethers.parseEther("1") });
    log("  └─ Staked ETH to the paymaster");

    log("\n✅ Setup Complete!\n");
  });

  it("should execute a simple ETH transfer with new proof", async () => {
    const message = await generateMessage(simpleAccount)
    const paymasterData = await generateCachedPaymasterData(id1, group, message, groupId, false)
    log("  └─ Paymaster Data:", paymasterData)
    await assertSendEth(transferAmount, paymasterData);
  });

  it("should use cached proof for subsequent transfers", async () => {
    // First transfer with new proof
    const message = await generateMessage(simpleAccount)
    const initialPaymasterData = await generateCachedPaymasterData(id1, group, message, groupId, false)
    await assertSendEth(transferAmount, initialPaymasterData);

    // Second transfer using cached proof
    const cachedPaymasterData = await generateCachedPaymasterData(id1, group, message, groupId, true)
    await assertSendEth(transferAmount, cachedPaymasterData);
  });

  it("should allow multiple users to cache and use their proofs", async () => {
    // First user (id1)
    const message1 = await generateMessage(simpleAccount);
    const paymasterData1 = await generateCachedPaymasterData(id1, group, message1, groupId, false);
    await assertSendEth(transferAmount, paymasterData1, true);

    // Second user (id2)
    const message2 = await generateMessage(simpleAccount);
    const paymasterData2 = await generateCachedPaymasterData(id2, group, message2, groupId, false);
    await assertSendEth(transferAmount, paymasterData2, true);

    // Both users use cached proofs
    const cachedData1 = await generateCachedPaymasterData(id1, group, message1, groupId, true);
    const cachedData2 = await generateCachedPaymasterData(id2, group, message2, groupId, true);
    await assertSendEth(transferAmount, cachedData1, true);
    await assertSendEth(transferAmount, cachedData2, true);
  });

  it("should track group deposits correctly after cached transactions", async () => {
    const initialDeposit = await cachedSemaphorePaymaster.groupDeposits(groupId);

    // First transfer with new proof
    const message = await generateMessage(simpleAccount);
    const initialPaymasterData = await generateCachedPaymasterData(id1, group, message, groupId, false);
    await assertSendEth(transferAmount, initialPaymasterData);

    const midDeposit = await cachedSemaphorePaymaster.groupDeposits(groupId);
    expect(midDeposit).to.be.lessThan(initialDeposit);

    // Second transfer using cached proof
    const cachedPaymasterData = await generateCachedPaymasterData(id1, group, message, groupId, true);
    await assertSendEth(transferAmount, cachedPaymasterData);

    const finalDeposit = await cachedSemaphorePaymaster.groupDeposits(groupId);
    expect(finalDeposit).to.be.lessThan(midDeposit);
  });

  it("should fail when using cache before proof is validated", async () => {
    const message = await generateMessage(simpleAccount);
    // Try to use cache immediately without submitting proof first
    const cachedPaymasterData = await generateCachedPaymasterData(id1, group, message, groupId, true);
    await assertSendEth(transferAmount, cachedPaymasterData, false);
  });

  it("should fail when group has insufficient balance", async () => {
    // Create a new group with no deposits
    const newGroupId = 1;
    await cachedSemaphorePaymaster["createGroup()"]();
    await cachedSemaphorePaymaster.addMembers(newGroupId, group.members);

    const message = await generateMessage(simpleAccount);
    const paymasterData = await generateCachedPaymasterData(id1, group, message, newGroupId, false);
    await assertSendEth(transferAmount, paymasterData, false);
  });

  it("should fail with invalid message", async () => {
    const invalidMessage = 12345n; // Wrong message format
    const paymasterData = await generateCachedPaymasterData(id1, group, invalidMessage, groupId, false);
    await assertSendEth(transferAmount, paymasterData, false);
  });
});
