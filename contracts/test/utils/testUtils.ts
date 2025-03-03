import { ethers } from "hardhat";
import { JsonRpcProvider, Signer } from "ethers";
import { SimpleAccount, SimpleSemaphorePaymaster } from "../../typechain";
import { Identity, Group, generateProof } from "@semaphore-protocol/core";
import { generateUnsignedUserOp, getUserOpHash } from "./userOpUtils";
import sendUserOpAndWait from "./userOpUtils";

export interface TestContext {
    bundlerProvider: JsonRpcProvider;
    provider: JsonRpcProvider;
    admin: Signer;
    owner: Signer;
    entryPointAddress: string;
}

export async function setupProviders() {
    const provider = new ethers.JsonRpcProvider(process.env.NODE_URL);
    const bundlerProvider = new ethers.JsonRpcProvider(process.env.BUNDLER_URL);

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

export async function setupSemaphoreContracts(entryPointAddress: string, contractName: string, epochDuration: number | undefined = undefined) {
    if (contractName === "GasLimitedSemaphorePaymaster" && !epochDuration) {
        throw new Error("Epoch duration is required for GasLimitedSemaphorePaymaster");
    }

    const poseidonT3Factory = await ethers.getContractFactory("PoseidonT3");
    const poseidonT3 = await poseidonT3Factory.deploy();
    await poseidonT3.waitForDeployment();

    const verifierFactory = await ethers.getContractFactory("AlwaysValidVerifier");
    const verifierContract = await verifierFactory.deploy();
    await verifierContract.waitForDeployment();

    const paymasterFactory = await ethers.getContractFactory(
        contractName,
        {
            libraries: {
                PoseidonT3: await poseidonT3.getAddress()
            }
        }
    );

    if (contractName === "GasLimitedSemaphorePaymaster") {
        return await paymasterFactory.deploy(
            entryPointAddress,
            await verifierContract.getAddress(),
            epochDuration
        );
    }

    return await paymasterFactory.deploy(
        entryPointAddress,
        await verifierContract.getAddress()
    );
}

export async function generateMessage(account: SimpleAccount) {
    const sender = await account.getAddress();
    return BigInt(sender);
}

export async function generatePaymasterData(
    id: Identity,
    group: Group,
    message: bigint,
    groupId: number
) {
    const proof = await generateProof(id, group, message, groupId);
    const abiCoder = ethers.AbiCoder.defaultAbiCoder();

    return abiCoder.encode(
        ["tuple(uint256 groupId, tuple(uint256 merkleTreeDepth, uint256 merkleTreeRoot, uint256 nullifier, uint256 message, uint256 scope, uint256[8] points) proof)"],
        [{ groupId: groupId, proof }]
    );
}

export async function generateCachedPaymasterData(
    id: Identity,
    group: Group,
    message: bigint,
    groupId: number,
    useCache: boolean = false
) {
    const abiCoder = ethers.AbiCoder.defaultAbiCoder();

    if (useCache) {
        // Return cached format with flag
        return ethers.concat([
            "0x01", // Using cache flag
            abiCoder.encode(["uint256"], [groupId])
        ]);
    }

    // Generate new proof format
    const proof = await generateProof(id, group, message, groupId);
    return ethers.concat([
        "0x00", // Not using cache flag
        abiCoder.encode(["uint256"], [groupId]),
        abiCoder.encode(
            ["tuple(uint256 merkleTreeDepth, uint256 merkleTreeRoot, uint256 nullifier, uint256 message, uint256 scope, uint256[8] points)"],
            [proof]
        )
    ]);
}

export async function generateGasLimitedPaymasterData(
    id: Identity,
    group: Group,
    message: bigint,
    groupId: number,
    epoch: number,
    useCache: boolean = false
): Promise<{ paymasterData: string, nullifier: string }> {
    const abiCoder = ethers.AbiCoder.defaultAbiCoder();
    let scope = ethers.keccak256(abiCoder.encode(["uint256", "uint256"], [groupId, epoch]));

    if (useCache) {
        // For gas-limited paymaster, we need to include the nullifier in the cached format
        // First generate a proof to get the nullifier
        const proof = await generateProof(id, group, message, scope);

        // Return cached format with flag and nullifier
        return {
            paymasterData: ethers.concat([
                "0x01", // Using cache flag
                abiCoder.encode(["uint256"], [groupId]),
                abiCoder.encode(["uint256"], [proof.nullifier])
            ]),
            nullifier: proof.nullifier
        };
    }

    // Generate new proof format
    const proof = await generateProof(id, group, message, scope);
    return {
        paymasterData: ethers.concat([
            "0x00", // Not using cache flag
            abiCoder.encode(["uint256"], [groupId]),
            abiCoder.encode(
                ["tuple(uint256 merkleTreeDepth, uint256 merkleTreeRoot, uint256 nullifier, uint256 message, uint256 scope, uint256[8] points)"],
                [proof]
            )
        ]),
        nullifier: proof.nullifier
    };
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
    const userOpHash = getUserOpHash(unsignedUserOperation, context.entryPointAddress, Number(chainId));

    // For testing purposes, we're using a dummy signature
    // In a real application, this would be signed by the user's private key
    // The SimpleAccount contract in test mode accepts any signature
    unsignedUserOperation.signature = "0xfffffffffffffffffffffffffffffff0000000000000000000000000000000007aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1c";

    return unsignedUserOperation;
} 