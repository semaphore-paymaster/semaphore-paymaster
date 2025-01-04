# Use an official Node.js runtime as a parent image
FROM node:18

# Set the working directory in the container
WORKDIR /app/bundler

# Clone the bundler repository
RUN git clone https://github.com/eth-infinitism/bundler.git .

# Install dependencies
RUN yarn && yarn preprocess
