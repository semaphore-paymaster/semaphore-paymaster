# Use an official Node.js runtime as a parent image
FROM node:18

# Set the working directory in the container
WORKDIR /app/node

# Install Foundry
RUN curl -L https://foundry.paradigm.xyz | bash
RUN /root/.foundry/bin/foundryup

# Add Foundry binaries to PATH
ENV PATH="/root/.foundry/bin:${PATH}"