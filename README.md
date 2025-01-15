# ERC4337 Smart Account Development Template

This Porject provides a template for developing ERC4337 Smart Accounts. With an integrated bundler for testing.

## 🚀 Quick Start

### Prerequisites

- [Docker](https://www.docker.com/) installed and running
- [Node.js](https://nodejs.org/) and npm (or [Yarn](https://yarnpkg.com/))

### Setup

0. Setup environment variables:

   ```bash
   cp .env.example .env
   ```

   Edit `.env` with your desired settings.

1. Start the local blockchain node and bundler:

   > Note: This step is not required if you only want to run unit tests. See testing instructions below.


   ```bash
   docker compose up --build
   ```

2. Open a new terminal and install contract dependencies and setup environment variables (the default values should work for most users):

   ```bash
   cd contracts && yarn && cp .env.example .env
   ```

## 🧪 Testing (Optional)

### unit tests

```bash
forge test
```

### integration tests
```bash
npx hardhat test --network dev
```

### Controlling test environment

You can control the test environment by setting the `BUNDLER` environment variable to either `unsafe` or `safe`. The default is `safe`.

- `unsafe` will use the unsafe bundler which does not enforce limitations like storage access.
- `safe` will use the safe bundler which enforces limitations like storage access.

Also the `STAKE_ACCOUNT` environment variable can be set to `true` to automatically stake ETH to the email account.
This is useful for when working with the safe bundler that only works with stakes.
