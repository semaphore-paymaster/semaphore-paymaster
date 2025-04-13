import { ethers } from "hardhat";
import { Signer } from "ethers";
import {
  SimpleAccount,
  ExcubiaeSemaphorePaymaster,
} from "../../typechain";
import { expect } from "chai";
import { Identity, Group } from "@semaphore-protocol/core"
import { setupProviders, setupSimpleAccount, prepareTransferCallData, prepareUserOp, TestContext, setupExcubiaeSemaphorePaymasterContracts, generateExcubiaePaymasterData } from "../utils/testUtils";
import sendUserOpAndWait from "../utils/userOpUtils";

const ENABLE_LOGS = false; // Toggle this to enable/disable logging
const log = (...args: any[]) => ENABLE_LOGS && console.log(...args);

describe("ExcubiaePaymasterTest", () => {
  let context: TestContext;
  let owner: Signer;
  let recipientAddress: string;
  let simpleAccount: SimpleAccount;
  let excubiaeSemaphorePaymaster: ExcubiaeSemaphorePaymaster;
  let group: Group;
  let validGroupId: number;
  let invalidGroupId: number;
  let validEvidence: string;
  let invalidEvidence: string;
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
    validGroupId = 0;
    invalidGroupId = 1;

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
    const userOp = await prepareUserOp(context, callData, await simpleAccount.getAddress(), await excubiaeSemaphorePaymaster.getAddress(), paymasterData);

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
    log("\n🚀 Initializing Simple Account Test Suite...");
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
    const simpleAccountAddress = await simpleAccount.getAddress()

    // Fund the account
    const fundingAmount = ethers.parseEther("1000");
    log("\n💰 Funding Account:");
    log("  └─ Sending", ethers.formatEther(fundingAmount), "ETH to Simple Account");
    await owner.sendTransaction({
      to: simpleAccountAddress,
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

    // Deploy Semaphore contracts
    log("\n🔧 Deploying Semaphore Contracts:");
    const { policy, paymaster, validEvidence: _validEvidence, invalidEvidence: _invalidEvidence } = await setupExcubiaeSemaphorePaymasterContracts(entryPointAddress, simpleAccountAddress, owner);
    excubiaeSemaphorePaymaster = paymaster as unknown as ExcubiaeSemaphorePaymaster;
    validEvidence = _validEvidence;
    invalidEvidence = _invalidEvidence;

    // Set policy's target - paymaster has policy, i.e., policy must be called from paymaster
    await policy.connect(owner).setTarget(await excubiaeSemaphorePaymaster.getAddress());
    log("  └─ Policy set target to paymaster");

    // Setup deposits
    await excubiaeSemaphorePaymaster.depositForGroup(validGroupId, { value: ethers.parseEther("10") });
    const deposit = await excubiaeSemaphorePaymaster.getDeposit();
    log("  └─ Deposited", ethers.formatEther(deposit), "ETH to the paymaster for the group");

    await excubiaeSemaphorePaymaster.addStake(1, { value: ethers.parseEther("1") });
    log("  └─ Staked ETH to the paymaster");

    log("\n✅ Setup Complete!\n");
  });

  it("should execute a simple ETH transfer", async () => {
    const paymasterData = await generateExcubiaePaymasterData(validGroupId, validEvidence)
    log("  └─ Paymaster Data:", paymasterData)
    await assertSendEth(transferAmount, paymasterData);
  });

  it("should send 2 more eth", async () => {
    const paymasterData = await generateExcubiaePaymasterData(validGroupId, validEvidence)
    log("  └─ Paymaster Data:", paymasterData)
    await assertSendEth(ethers.parseEther("2"), paymasterData);
  });

  it("should allow proof reuse", async () => {
    const paymasterData = await generateExcubiaePaymasterData(validGroupId, validEvidence)
    await assertSendEth(ethers.parseEther("2"), paymasterData, true); // first time should succeed
    await assertSendEth(ethers.parseEther("2"), paymasterData, true); // second time should succeed
  });

  it("should allow deposits for a group", async () => {
    const depositAmount = ethers.parseEther("5");
    const initialDeposit = await excubiaeSemaphorePaymaster.groupDeposits(validGroupId);

    await excubiaeSemaphorePaymaster.depositForGroup(validGroupId, { value: depositAmount });

    const finalDeposit = await excubiaeSemaphorePaymaster.groupDeposits(validGroupId);
    expect(finalDeposit).to.equal(initialDeposit + depositAmount);
  });

  it("should reject deposits of zero amount", async () => {
    await expect(
      excubiaeSemaphorePaymaster.depositForGroup(validGroupId, { value: 0 })
    ).to.be.revertedWith("Must deposit non-zero amount");
  });

  it("should fail when group has insufficient balance", async () => {
    const paymasterData = await generateExcubiaePaymasterData(invalidGroupId, validEvidence)

    await assertSendEth(transferAmount, paymasterData, false);
  });
  
  it("should fail with invalid proof", async () => {
    const paymasterData = await generateExcubiaePaymasterData(validGroupId, invalidEvidence)

    await assertSendEth(transferAmount, paymasterData, false);
  });

  it("should fail with invalid group id", async () => {
    const paymasterData = await generateExcubiaePaymasterData(invalidGroupId, validEvidence)

    await assertSendEth(transferAmount, paymasterData, false);
  });

  it("should track group deposits correctly after transactions", async () => {
    const initialDeposit = await excubiaeSemaphorePaymaster.groupDeposits(validGroupId);

    const paymasterData = await generateExcubiaePaymasterData(validGroupId, validEvidence);

    // Send transaction and track gas usage
    const userOp = await prepareUserOp(
      context,
      prepareTransferCallData(recipientAddress, transferAmount),
      await simpleAccount.getAddress(),
      await excubiaeSemaphorePaymaster.getAddress(),
      paymasterData
    );
    const receipt = await sendUserOpAndWait(
      userOp,
      context.entryPointAddress,
      context.bundlerProvider
    );

    const finalDeposit = await excubiaeSemaphorePaymaster.groupDeposits(validGroupId);
    expect(finalDeposit).to.be.lessThan(initialDeposit);
  });
});
