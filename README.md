# VECTRON Foundry tests

Foundry test suite for the VECTRON (VCT) contract on BNB Smart Chain.

- Deployed contract: 0x21b2Fd27294912555b57028CC8cf69C60851D1e4 (source verified on BscScan)
- Contract source: src/Vectron.sol, SHA-256 dbe9eea02406f3bff8c14286790d8180a4cbfafed985a9d667dfe7ead25c7d94, identical to the verified on-chain source. Check with `sha256sum src/Vectron.sol`.
- Main project repo: https://github.com/wami2212-lab/VECTRON

## Results

Tag `v3-tested` (commit 294ecfa), forge 1.8.4:

- 46 tests across 6 suites (Admin, Audit, Fork, Invariant, Reentrancy, Vesting): 46 passed, 0 failed
- Invariant suite: 2000 runs, depth 500, 1,000,000 calls, 0 reverts, 10 invariants
- Full run takes about 11 minutes, mostly the invariant suite

Later commits only remove a stale reference file and add documentation. src/ and the test suites are unchanged from the tagged commit.

## Run it

    git clone --recurse-submodules https://github.com/wami2212-lab/VECTRON-foundry-tests.git
    cd VECTRON-foundry-tests
    forge test

For a quick run without the long invariant suite: `forge test --no-match-contract VectronInvariant`

The fork tests read the BSC RPC from the `BSC_RPC_URL` environment variable and fall back to the public endpoint https://bsc-dataseed.binance.org if it is not set.

## Configuration

Solidity 0.8.19, optimizer on with 200 runs, EVM version paris, matching the deployed contract.

## Limits

These tests and the static analysis run on the contract are not a substitute for an independent audit, and no third-party audit has been completed. Smart contract risk applies regardless of testing.
