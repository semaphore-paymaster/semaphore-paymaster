import { ethers } from "hardhat";
import { JsonRpcProvider, Signer } from "ethers";
import {
  SimpleAccount,
  SimpleSemaphorePaymaster,
} from "../typechain";
import { generateUnsignedUserOp } from "../scripts/utils/userOpUtils";
import sendUserOpAndWait, {
  getUserOpHash,
} from "../scripts/utils/userOpUtils";
import { expect } from "chai";
import { Identity, Group, generateProof } from "@semaphore-protocol/core"

describe("SimplePaymasterTest", () => {
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
  let simpleSemaphorePaymaster: SimpleSemaphorePaymaster;
  let group: Group;
  let groupId: number;
  let id1: Identity;
  let id2: Identity;
  let id3: Identity;
  const transferAmount = ethers.parseEther("1");

  async function setupTests() {
    const [admin, owner, id1Pk, id2Pk, id3Pk] = await ethers.getSigners();

    id1 = new Identity(id1Pk);
    id2 = new Identity(id2Pk);
    id3 = new Identity(id3Pk);
    group = new Group([id1.commitment, id2.commitment, id3.commitment])
    groupId = 0;

    const provider = new ethers.JsonRpcProvider("http://localhost:8545");
    const bundlerProvider = new ethers.JsonRpcProvider("http://localhost:3000/rpc");

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

  beforeEach(async () => {
    console.log("\n🚀 Initializing Simple Account Test Suite...");

    console.log("\n🔧 Environment Configuration:");
    console.log("  ├─ BUNDLER: 🔒 SAFE (port 3000)");
    console.log(`  └─ STAKE_ACCOUNT: ${process.env.STAKE_ACCOUNT || 'false'}`);

    context = await setupTests();
    [owner, recipient] = await ethers.getSigners();

    console.log("\n📋 Test Configuration:");
    console.log("  ├─ Owner Address:", await owner.getAddress());
    console.log("  ├─ Owner Balance:", ethers.formatEther(await context.provider.getBalance(await owner.getAddress())), "ETH");
    console.log("  ├─ EntryPoint:", context.entryPointAddress);
    console.log("  └─ Bundler URL: http://localhost:3000/rpc (🔒 SAFE)");

    recipientAddress = "0x742d35Cc6634C0532925a3b844Bc454e4438f44e";
    console.log("\n🔧 Deploying Contracts:");

    const factory = await ethers.getContractFactory("SimpleAccountFactory");
    const simpleAccountFactory = await factory.deploy(context.entryPointAddress);
    await simpleAccountFactory.waitForDeployment();
    console.log("  └─ Simple Account Factory deployed to:", await simpleAccountFactory.getAddress());

    console.log("\n📬 Creating Simple Account:");
    const salt = ethers.randomBytes(32);
    await simpleAccountFactory.createSimpleAccount(salt);
    simpleAccount = await ethers.getContractAt("SimpleAccount", await simpleAccountFactory.computeAddress(salt));
    console.log("  └─ Simple Account created at:", await simpleAccount.getAddress());

    // fund the account from owner's account
    const fundingAmount = ethers.parseEther("1000");
    console.log("\n💰 Funding Account:");
    console.log("  └─ Sending", ethers.formatEther(fundingAmount), "ETH to Simple Account");
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


    console.log("\n🔧 Deploying Semaphore Contracts:");

    const poseidonT3Factory = await ethers.getContractFactory("PoseidonT3");
    const poseidonT3 = await poseidonT3Factory.deploy();
    await poseidonT3.waitForDeployment();
    console.log("  └─ PoseidonT3 deployed to:", await poseidonT3.getAddress());

    const verifierFactory = await ethers.getContractFactory("AlwaysValidVerifier");
    const verifierContract = await verifierFactory.deploy();
    await verifierContract.waitForDeployment();
    console.log("  └─ Semaphore Verifier deployed to:", await verifierContract.getAddress());
    const simpleSemaphorePaymasterFactory = await ethers.getContractFactory("SimpleSemaphorePaymaster", {
      libraries: {
        PoseidonT3: await poseidonT3.getAddress()
      }
    });
    simpleSemaphorePaymaster = await simpleSemaphorePaymasterFactory.deploy(context.entryPointAddress, await verifierContract.getAddress());
    await simpleSemaphorePaymaster.waitForDeployment();
    console.log("  └─ Simple Semaphore Paymaster deployed to:", await simpleSemaphorePaymaster.getAddress());

    // create a group
    await simpleSemaphorePaymaster["createGroup()"]()
    await simpleSemaphorePaymaster.addMembers(groupId, group.members)
    console.log("  └─ Group created with commitments:", group.members)

    // deposit 0.01 ETH to the paymaster for the group
    await simpleSemaphorePaymaster.depositForGroup(groupId, { value: ethers.parseEther("10") })
    const deposit = await simpleSemaphorePaymaster.getDeposit()
    console.log("  └─ Deposited", ethers.formatEther(deposit), "ETH to the paymaster for the group")


    // add stake for the paymaster
    await simpleSemaphorePaymaster.addStake(1, { value: ethers.parseEther("1") })
    console.log("  └─ Staked ETH to the paymaster")

    console.log("\n✅ Setup Complete!\n");
  });

  it("should execute a simple ETH transfer", async () => {
    const message = await generateMessage(simpleAccount)
    const paymasterData = await generatePaymasterData(id1, group, message, groupId)
    console.log("  └─ Paymaster Data:", paymasterData)
    await assertSendEth(transferAmount, paymasterData);
  });

  it("should send 2 more eth", async () => {
    const message = await generateMessage(simpleAccount)
    const paymasterData = await generatePaymasterData(id1, group, message, groupId)
    console.log("  └─ Paymaster Data:", paymasterData)
    await assertSendEth(ethers.parseEther("2"), paymasterData);
  });

  it("should not allow proof reuse", async () => {
    const message = await generateMessage(simpleAccount)
    const paymasterData = await generatePaymasterData(id1, group, message, groupId)
    await assertSendEth(ethers.parseEther("2"), paymasterData, true); // first time should succeed
    await assertSendEth(ethers.parseEther("2"), paymasterData, false); // second time should fail
  });

  async function generateMessage(account: SimpleAccount) {
    // the message is keccak256(abi.encode(sender, nonce))
    const nonce = await simpleAccount.getNonce();
    console.log("  └─ Nonce:", nonce)
    const sender = await account.getAddress();
    const encoded = ethers.AbiCoder.defaultAbiCoder().encode(["address", "uint256"], [sender, nonce]);
    const hash = ethers.keccak256(encoded);
    return BigInt(hash);
  }

  async function generatePaymasterData(id: Identity, group: Group, message: bigint, groupId: number) {
    const proof = await generateProof(id, group, message, groupId)
    return ethers.AbiCoder.defaultAbiCoder().encode(
      ["tuple(uint256 groupId, tuple(uint256 merkleTreeDepth, uint256 merkleTreeRoot, uint256 nullifier, uint256 message, uint256 scope, uint256[8] points) proof)"],
      [{ groupId: groupId, proof }]
    );
  }

  async function prepareUserOp(callData: string, paymasterData: string) {

    const unsignedUserOperation = await generateUnsignedUserOp(
      context.entryPointAddress,
      context.provider,
      context.bundlerProvider,
      await simpleAccount.getAddress(),
      callData,
      await simpleSemaphorePaymaster.getAddress(),
      100000,
      paymasterData
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

    unsignedUserOperation.signature = "0x"; // everything is valid in our test account.

    return unsignedUserOperation;
  }

  async function assertSendEth(
    amount: bigint,
    paymasterData: string = "0x",
    shouldSucceed: boolean = true
  ) {
    // Get initial balance
    const recipientBalanceBefore = await context.provider.getBalance(recipientAddress);
    console.log("  └─ Recipient Balance Before:", ethers.formatEther(recipientBalanceBefore), "ETH");

    // Prepare call data for ETH transfer
    const callData = prepareTransferCallData(recipientAddress, amount);

    // Create and send user operation
    const userOp = await prepareUserOp(callData, paymasterData);

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

  function prepareTransferCallData(to: string, amount: bigint): string {
    const executeFunctionSelector = "0x" + ethers.id("execute(address,uint256,bytes)").slice(2, 10);
    return executeFunctionSelector + ethers.AbiCoder.defaultAbiCoder().encode(
      ["address", "uint256", "bytes"],
      [to, amount, "0x"]
    ).slice(2);
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
    console.log("  └─ Recipient Balance After:", ethers.formatEther(balanceAfter), "ETH");

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
});
