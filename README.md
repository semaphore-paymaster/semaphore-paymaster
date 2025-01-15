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
forge clean
```

```bash
npx hardhat test --network dev
```

### Troubleshooting

If you encounter unexpected errors, try restarting the Docker containers
