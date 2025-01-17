import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@nomicfoundation/hardhat-ethers";
import * as dotenv from "dotenv";
dotenv.config();

const { NODE_URL } = process.env;
const config: HardhatUserConfig = {
  solidity: "0.8.27",
  networks: {
    dev: {
      chainId: 1337.,
      url: NODE_URL,
    },
  },
  paths: {
    sources: "./src",
    artifacts: "./hardhat_artifacts"
  }
};

export default config;
