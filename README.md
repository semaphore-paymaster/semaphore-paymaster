# ERC4337 Semaphore Paymaster

A privacy-preserving paymaster implementation using Semaphore Protocol for ERC4337 Account Abstraction. This paymaster allows users to pay for gas using zero-knowledge proofs of membership in a Semaphore group.

## 🔒 Features

- Privacy-preserving gas sponsorship using zero-knowledge proofs
- Group-based access control for gas payments
- Integration with Semaphore Protocol for membership verification
- Compatible with ERC4337 Account Abstraction standard

## 🚀 Quick Start

### Prerequisites

- [Docker](https://www.docker.com/) installed and running
- [Node.js](https://nodejs.org/) and npm (or [Yarn](https://yarnpkg.com/))

### Setup

1. Setup environment variables:

   ```bash
   cp .env.example .env
   ```

   Edit `.env` with your desired settings.

2. Start the local blockchain node and bundler:

   > Note: This step is not required if you only want to run unit tests. See testing instructions below.

   ```bash
   docker compose up --build
   ```

3. Open a new terminal and install contract dependencies:

   ```bash
   cd contracts && yarn && cp .env.example .env
   ```

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
