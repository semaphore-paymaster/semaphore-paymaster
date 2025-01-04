import { ethers } from "hardhat";
import { JsonRpcProvider, Signer } from "ethers";
import {
  SimpleAccount,
} from "../typechain";
import { generateUnsignedUserOp } from "../scripts/utils/userOpUtils";
import sendUserOpAndWait, {
  getUserOpHash,
} from "../scripts/utils/userOpUtils";
import { expect } from "chai";

describe("EmailAccountTest", () => {
  let context: {
    bundlerProvider: JsonRpcProvider;
    provider: JsonRpcProvider;
    admin: Signer;
    owner: Signer;
    entryPointAddress: string;
  };

  let owner: Signer;
  let recipient: Signer;
  let recipientAddress: string;
  let simpleAccount: SimpleAccount;

  const transferAmount = ethers.parseEther("1");

  async function setupTests() {
    const [admin, owner] = await ethers.getSigners();
    const provider = new ethers.JsonRpcProvider("http://localhost:8545");

    const bundlerProvider = new ethers.JsonRpcProvider(
      process.env.BUNDLER === "unsafe" ? "http://localhost:3002/rpc" : "http://localhost:3000/rpc"
    );

    // get list of supported entrypoints
    const entrypoints = await bundlerProvider.send(
      "eth_supportedEntryPoints",
      []
    );

    if (entrypoints.length === 0) {
      throw new Error("No entrypoints found");
    }

    return {
      bundlerProvider,
      provider,
      admin,
      owner,
      recipient,
      entryPointAddress: entrypoints[0],
    };
  }

  before(async () => {
    console.log("\n🚀 Initializing Simple Account Test Suite...");

    const bundlerMode = process.env.BUNDLER === 'unsafe' ? '⚠️  UNSAFE' : '🔒 SAFE';
    const bundlerPort = process.env.BUNDLER === 'unsafe' ? '3002' : '3000';

    console.log("\n🔧 Environment Configuration:");
    console.log(`  ├─ BUNDLER: ${bundlerMode} (port ${bundlerPort})`);
    console.log(`  └─ STAKE_ACCOUNT: ${process.env.STAKE_ACCOUNT || 'false'}`);

    context = await setupTests();
    [owner, recipient] = await ethers.getSigners();

    console.log("\n📋 Test Configuration:");
    console.log("  ├─ Owner Address:", await owner.getAddress());
    console.log("  ├─ Owner Balance:", ethers.formatEther(await context.provider.getBalance(await owner.getAddress())), "ETH");
    console.log("  ├─ EntryPoint:", context.entryPointAddress);
    console.log(`  └─ Bundler URL: http://localhost:${bundlerPort}/rpc (${bundlerMode})`);

    recipientAddress = "0x742d35Cc6634C0532925a3b844Bc454e4438f44e";
    console.log("\n🔧 Deploying Contracts:");

    const factory = await ethers.getContractFactory("SimpleAccountFactory");
    const simpleAccountFactory = await factory.deploy(context.entryPointAddress);
    await simpleAccountFactory.waitForDeployment();
    console.log("  └─ Simple Account Factory deployed to:", await simpleAccountFactory.getAddress());

    // deploy the email account using the factory
    console.log("\n📬 Creating Simple Account:");
    const salt = ethers.randomBytes(32);
    await simpleAccountFactory.createSimpleAccount(salt);
    simpleAccount = await ethers.getContractAt("SimpleAccount", await simpleAccountFactory.computeAddress(salt));
    console.log("  └─ Simple Account created at:", await simpleAccount.getAddress());

    // fund the account from owner's account
    const fundingAmount = ethers.parseEther("1000");
    console.log("\n💰 Funding Account:");
    console.log("  └─ Sending", ethers.formatEther(fundingAmount), "ETH to Email Account");
    await owner.sendTransaction({
      to: await simpleAccount.getAddress(),
      value: fundingAmount
    });

    // Only add stake if STAKE_ACCOUNT environment variable is set to true
    if (process.env.STAKE_ACCOUNT === 'true') {
      console.log("\n🔒 Adding Stake:");
      console.log("  └─ Staking 1 ETH to account");
      await simpleAccount.addStake(1, { value: ethers.parseEther("1") });
    } else {
      console.log("\nℹ️  Stake Status:");
      console.log("  └─ Skipping account staking (STAKE_ACCOUNT not set)");
    }

    console.log("\n✅ Setup Complete!\n");
  });

  it("should execute a simple ETH transfer", async () => {
    await assertSendEth(transferAmount);
  });

  it("should send 2 more eth twice", async () => {
    await assertSendEth(ethers.parseEther("2"));
    await assertSendEth(ethers.parseEther("2"));
  });

  async function prepareUserOp(callData: string) {
    const unsignedUserOperation = await generateUnsignedUserOp(
      context.entryPointAddress,
      context.provider,
      context.bundlerProvider,
      await simpleAccount.getAddress(),
      callData
    );
    return await signUserOp(unsignedUserOperation);
  }

  async function signUserOp(unsignedUserOperation: any) {
    const chainId = await context.provider
      .getNetwork()
      .then((network) => network.chainId);
    const userOpHash = getUserOpHash(
      unsignedUserOperation,
      context.entryPointAddress,
      Number(chainId)
    );

    unsignedUserOperation.signature = "0x"; // everything is valid so far.

    return unsignedUserOperation;
  }

  async function assertSendEth(amount: bigint) {
    const recipientBalanceBefore = await context.provider.getBalance(
      recipientAddress
    );

    const executeFunctionSelector = "0x" + ethers.id("execute(address,uint256,bytes)").slice(2, 10);
    const callData = executeFunctionSelector + ethers.AbiCoder.defaultAbiCoder().encode(
      ["address", "uint256", "bytes"],
      [recipientAddress, amount, "0x"]
    ).slice(2);

    const userOp = await prepareUserOp(callData);
    await sendUserOpAndWait(
      userOp,
      context.entryPointAddress,
      context.bundlerProvider
    );
    const recipientBalanceAfter = await context.provider.getBalance(
      recipientAddress
    );
    const expectedRecipientBalance = recipientBalanceBefore + amount;
    expect(recipientBalanceAfter).to.equal(expectedRecipientBalance);
  }
});
