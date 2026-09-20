import { defineConfig } from "hardhat/config";
import hardhatEthersPlugin from "@nomicfoundation/hardhat-ethers";

// The node under test is the etherlang dev release: header-only sync, no
// mining/deploy. Tests therefore drive raw `eth_call` with a code override
// into the node's own EVM from the test bodies (see scripts/run-node-tests.ts).

export default defineConfig({
  plugins: [hardhatEthersPlugin],
  solidity: {
    version: "0.8.25",
    settings: {
      evmVersion: "paris",
      optimizer: { enabled: true, runs: 200 },
    },
  },
});