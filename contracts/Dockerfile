# Use an official Node.js runtime as a parent image
FROM node:18

# Set the working directory in the container
WORKDIR /usr/src/app

# Copy the package.json and yarn.lock files to the container
COPY package.json yarn.lock package-lock.json ./

# Install project dependencies
RUN yarn install

# Copy the relevant files and directories to the container
COPY contracts ./contracts
COPY scripts ./scripts
COPY hardhat.config.ts ./
COPY tsconfig.json ./
COPY tasks ./tasks

# make folder for deployed addresses
RUN mkdir -p deployedAddresses

ENV NODE_URL=http://localhost:8545

# Generate typechains and compile the contracts
RUN npx hardhat typechain && npx hardhat compile