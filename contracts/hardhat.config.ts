import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@nomicfoundation/hardhat-ethers";
import * as dotenv from "dotenv";
import fs from "fs";
dotenv.config();

// load tasks from tasks folder
const tasks = fs.readdirSync("./tasks").filter((file) => file.endsWith(".ts"));
tasks.forEach((task) => {
  require(`./tasks/${task}`);
});

const { NODE_URL } = process.env;

const config: HardhatUserConfig = {
  solidity: "0.8.27",
  networks: {
    dev: {
      chainId: 1337.,
      url: NODE_URL,
    },
  },
};

export default config;
