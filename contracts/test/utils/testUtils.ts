import { ethers } from "hardhat";
import { JsonRpcProvider, Signer } from "ethers";
import { SimpleAccount, SimpleSemaphorePaymaster } from "../../typechain";
import { Identity, Group, generateProof } from "@semaphore-protocol/core";
import { generateUnsignedUserOp, getUserOpHash } from "../../scripts/utils/userOpUtils";
import sendUserOpAndWait from "../../scripts/utils/userOpUtils";

export interface TestContext {
    bundlerProvider: JsonRpcProvider;
    provider: JsonRpcProvider;
    admin: Signer;
    owner: Signer;
    entryPointAddress: string;
}

export async function setupProviders() {
    const provider = new ethers.JsonRpcProvider("http://localhost:8545");
    const bundlerProvider = new ethers.JsonRpcProvider("http://localhost:3000/rpc");

    const entrypoints = await bundlerProvider.send("eth_supportedEntryPoints", []);

    if (entrypoints.length === 0) {
        throw new Error("No entrypoints found");
    }

    return {
        provider,
        bundlerProvider,
        entryPointAddress: entrypoints[0]
    };
}

export async function setupSimpleAccount(entryPointAddress: string) {
    const factory = await ethers.getContractFactory("SimpleAccountFactory");
    const simpleAccountFactory = await factory.deploy(entryPointAddress);
    await simpleAccountFactory.waitForDeployment();

    const salt = ethers.randomBytes(32);
    await simpleAccountFactory.createSimpleAccount(salt);
    return await ethers.getContractAt(
        "SimpleAccount",
        await simpleAccountFactory.computeAddress(salt)
    );
}

export async function setupSemaphoreContracts(entryPointAddress: string) {
    const poseidonT3Factory = await ethers.getContractFactory("PoseidonT3");
    const poseidonT3 = await poseidonT3Factory.deploy();
    await poseidonT3.waitForDeployment();

    const verifierFactory = await ethers.getContractFactory("AlwaysValidVerifier");
    const verifierContract = await verifierFactory.deploy();
    await verifierContract.waitForDeployment();

    const simpleSemaphorePaymasterFactory = await ethers.getContractFactory(
        "SimpleSemaphorePaymaster",
        {
            libraries: {
                PoseidonT3: await poseidonT3.getAddress()
            }
        }
    );
    return await simpleSemaphorePaymasterFactory.deploy(
        entryPointAddress,
        await verifierContract.getAddress()
    );
}

export async function generateMessage(account: SimpleAccount) {
    const nonce = await account.getNonce();
    const sender = await account.getAddress();
    const encoded = ethers.AbiCoder.defaultAbiCoder().encode(
        ["address", "uint256"],
        [sender, nonce]
    );
    return BigInt(ethers.keccak256(encoded));
}

export async function generatePaymasterData(
    id: Identity,
    group: Group,
    message: bigint,
    groupId: number
) {
    const proof = await generateProof(id, group, message, groupId);
    return ethers.AbiCoder.defaultAbiCoder().encode(
        ["tuple(uint256 groupId, tuple(uint256 merkleTreeDepth, uint256 merkleTreeRoot, uint256 nullifier, uint256 message, uint256 scope, uint256[8] points) proof)"],
        [{ groupId: groupId, proof }]
    );
}

export function prepareTransferCallData(to: string, amount: bigint): string {
    const executeFunctionSelector = "0x" + ethers.id("execute(address,uint256,bytes)").slice(2, 10);
    return executeFunctionSelector + ethers.AbiCoder.defaultAbiCoder().encode(
        ["address", "uint256", "bytes"],
        [to, amount, "0x"]
    ).slice(2);
}

export async function prepareUserOp(
    context: TestContext,
    callData: string,
    accountAddress: string,
    paymasterAddress: string,
    paymasterData: string,
) {
    const unsignedUserOperation = await generateUnsignedUserOp(
        context.entryPointAddress,
        context.provider,
        context.bundlerProvider,
        accountAddress,
        callData,
        paymasterAddress,
        100000,
        paymasterData
    );
    return await signUserOp(context, unsignedUserOperation);
}

async function signUserOp(context: TestContext, unsignedUserOperation: any) {
    const chainId = await context.provider.getNetwork().then((network) => network.chainId);
    getUserOpHash(unsignedUserOperation, context.entryPointAddress, Number(chainId));
    unsignedUserOperation.signature = "0x";
    return unsignedUserOperation;
} 