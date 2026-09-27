# ObservationBuffer

A permissionless on-chain ring buffer that keeps the latest **16** `(timestamp, value)`
observations. Anyone can write. Timestamps must be strictly increasing relative to the newest
stored observation. Reads are by logical index and always enumerate oldest to newest, before
and after wraparound.

Standalone Foundry project, Solidity **0.8.24**, no fetched test dependencies (`forge-std` is
vendored as ordinary files under `lib/forge-std`). Builds and tests run fully offline.

## Layout

| Path | Purpose |
| --- | --- |
| `src/ObservationBuffer.sol` | The contract (no constructor arguments, no owner). |
| `test/ObservationBuffer.t.sol` | Differential tests against an append-only array model, rejection tests, overwrite tests, out-of-range reads, fuzz tests, gas bounds. |
| `test/DeployObservationBuffer.t.sol` | Tests of the deployment logic and the launch-floor opcode/size scan. |
| `script/DeployObservationBuffer.s.sol` | Deployment script. `run()` reads the environment; `deploy(chainId)` is the pure logic the tests call. |
| `deployments/sepolia.json` | Deployment record (currently `NOT_DEPLOYED`, see "Deployment"). |
| `lib/forge-std` | Vendored forge-std v1.9.6 (plain files, no git metadata, no submodule). |
| `foundry.toml`, `remappings.txt` | Build configuration. |

## Exact behaviour

Storage is a fixed array of 16 physical slots plus one counter `_written` (total accepted
writes). Slot `s` holds the write whose global sequence number is congruent to `s` modulo 16.

### `write(uint256 timestamp, uint256 value) → uint256 sequence`

* Callable by anyone. No access control, no pause, no upgrade path, no ETH handling.
* **Accepted** if the buffer is empty, or `timestamp > latest().timestamp`.
* **Rejected** with `TimestampNotIncreasing(timestamp, latestTimestamp)` if
  `timestamp <= latest().timestamp`. A rejected write changes nothing.
* The first write accepts any timestamp, including `0`.
* The comparison is only against the *newest* stored observation, never against evicted ones.
* `value` is an arbitrary `uint256` (0 and `type(uint256).max` are both fine).
* The observation is written to physical slot `totalWritten() % 16`. From the 17th write onward
  this overwrites the oldest stored observation. Overwritten data is not recoverable through
  the ordered read API.
* Returns the zero-based global sequence number and emits
  `ObservationWritten(writer, sequence, slot, timestamp, value)`.
* Timestamps are caller supplied. The contract **never reads `block.timestamp`** and imposes
  no upper bound. Writing `type(uint256).max` as a timestamp freezes the buffer forever (no
  later write can be strictly greater). See "Assumptions and limitations".

### Reads

| Function | Behaviour |
| --- | --- |
| `length()` | `min(totalWritten(), 16)`. |
| `totalWritten()` | Total accepted writes since deployment, including overwritten ones. |
| `oldestSequence()` | Global sequence number of logical index 0, i.e. `totalWritten() - length()`. |
| `get(uint256 index)` | Observation at logical index. Index `0` is the oldest still stored, `length() - 1` is the newest. Reverts `IndexOutOfRange(index, length)` when `index >= length()`. |
| `latest()` / `oldest()` | Newest / oldest stored observation. Revert `EmptyBuffer()` when empty. |
| `observations()` | All stored observations, oldest first, as a memory array of length `length()`. |
| `rawSlot(uint256 slot)` | Raw physical slot content (may be stale or all-zero). Auditing aid only. Reverts `SlotOutOfRange(slot, 16)` when `slot >= 16`. |
| `CAPACITY` | Constant `16`. |

Logical index `i` maps to physical slot `(totalWritten() - length() + i) % 16`. Because
`length()` and `totalWritten()` are the only state consulted, enumeration order is the same
before, at and after any number of wraparounds.

### Storage layout

| Slot | Variable |
| --- | --- |
| 0..31 | `_slots` (`Observation[16]`, two words per entry: timestamp then value) |
| 32 | `_written` |

### Bytecode (solc 0.8.24, optimizer 200 runs, cancun, `bytecode_hash = "none"`, no CBOR metadata)

| Item | Value |
| --- | --- |
| Runtime size | 1614 bytes (EIP-170 limit 24576) |
| Init code size | 1643 bytes |
| keccak256(init code) | `0x2f6253f39497b4959d8a838fdfd004c70b4e018ad21103b57a95a6bc6f559325` |
| keccak256(runtime) | `0x8980040e208b6597b48af5712fe6d7fc605b03cbb27dc5bd7466b3e0d20695fc` |
| Forbidden opcodes | none: no `DELEGATECALL`, `CALLCODE`, `SELFDESTRUCT` (scanned in `test_runtimeHasNoForbiddenOpcodesAndFitsEip170`) |

Metadata is disabled so the init code above is reproducible byte for byte from this checkout.

## Gas behaviour

Every `write` touches at most three storage slots (the observation's two words and the
counter) and reads one (the newest timestamp). There are no loops on the write path, so cost is
bounded and independent of how many wraparounds have occurred. Measured inside
`test_gasIsBoundedAsBufferFills` (gas metered around the external call from the test, so the
numbers include call overhead; run `forge test --match-test test_gas -vv` to reproduce):

| Write | Gas | Why |
| --- | --- | --- |
| #1 (empty buffer) | ~96,100 | three zero → non-zero `SSTORE`s |
| #2 … #16 (filling) | ~76,800 | two zero → non-zero `SSTORE`s, counter already non-zero |
| #17 … #100 (overwriting) | ~42,600 | all three slots already non-zero |
| `get(i)`, any `i` | ~12,000 | constant, index-independent (jitter < 30 gas) |
| `observations()` when full | ~85,000 | 32 `SLOAD`s, bounded by `CAPACITY` |

The test asserts: every write `< 150,000` gas; the most expensive overwrite costs no more than
the most expensive first-fill write; overwrite cost drifts by at most 500 gas across writes
17…100; `get` cost varies by at most 300 gas across all 16 indices. `forge test --gas-report`
prints the compiler-level report for the same calls.

## Tests

31 tests, all passing offline (`forge test`). Fuzz runs are seeded in `foundry.toml` so the
run is reproducible.

Model-based checks (`test/ObservationBuffer.t.sol`): the test keeps an append-only array of
every accepted write and, after **every** write, checks `length`, `totalWritten`,
`oldestSequence`, `get(i)` for every `i`, `observations()`, `latest`, `oldest`, strict
monotonicity of the enumerated timestamps, and that `get(length)`, `get(16)` and
`get(2^256-1)` revert with the exact error.

* Fill levels: `test_zeroWrites`, `test_oneWrite`, `test_fifteenWrites_bufferNotYetFull`,
  `test_sixteenWrites_bufferExactlyFull`, `test_seventeenWrites_firstWraparound`,
  `test_hundredWrites_manyWraparounds`, plus `testFuzz_matchesModel` (0…100 random writes,
  random start timestamp, random steps, full-width values).
* Rejected timestamps: equal, older, zero-after-first, rejection compared against the
  *latest* (not evicted) observation, rejected write leaves state untouched, fuzzed
  `testFuzz_rejectsNonIncreasingTimestamp` / `testFuzz_acceptsStrictlyGreaterTimestamp`.
* Value domain: `0`, `2^255`, `2^256-1`; large timestamp jumps; the `type(uint256).max`
  timestamp freeze.
* Overwritten data: after the 17th write the first observation appears at no logical index
  and physical slot 0 holds sequence 16; after 100 writes every slot holds exactly the last
  sequence congruent to it mod 16.
* Out-of-range reads: at the boundary, at 16, at `2^256-1`, and fuzzed for every fill level;
  `rawSlot` bounds.
* Permissionless writes from several accounts, event emission, returned sequence numbers.
* Deployment logic (`test/DeployObservationBuffer.t.sol`): deploys on Sepolia chain id,
  refuses chain id 1 and mismatched chains, runtime opcode/size scan.

## Reproduction

Prerequisites: Foundry (developed with forge 1.8.3) and solc **0.8.24** present in the local
svm cache (`~/.local/share/svm/0.8.24` or `~/.svm/0.8.24`). `offline = true` in `foundry.toml`
forbids compiler downloads; `auto_detect_solc` picks 0.8.24 because every file in `src/`,
`test/` and `script/` carries the exact pragma `0.8.24`. No compiler path is configured.

```sh
forge build
forge test                       # 31 tests
forge test -vv --match-test gas  # prints the gas table above
forge test --gas-report
forge fmt --check
```

No network access, no `ffi`, no `fs_permissions`, and no environment variables are required
for any of the above.

## Deployment

**Status: deployment ON, but the Sepolia broadcast has not been executed.** The script was
simulated against Sepolia and succeeds (see `deployments/sepolia.json`), but this contributor
environment has no funded Sepolia account and this task does not read or manage a wallet key.
The publicly documented Anvil/Hardhat test accounts (`test test … junk`, indices 0–9) were
checked on Sepolia on 2026-09-27 and all have a zero balance, so they cannot pay for the
transaction either. The address, transaction hash and explorer link fields in
`deployments/sepolia.json` are therefore `null` and must be filled in by whoever runs the
broadcast below.

### Parameters

| Parameter | Value |
| --- | --- |
| Target network | Sepolia, chain id `11155111` |
| Contract | `src/ObservationBuffer.sol:ObservationBuffer` |
| Constructor arguments | **none** (ABI-encoded: `0x`) |
| Constructor `msg.value` | 0 (constructor is nonpayable; the contract never holds ETH) |
| Privileged roles | none |
| Estimated gas | ~523,000 (dry-run, 2026-09-27) |
| Mainnet | forbidden; the script reverts with `MainnetForbidden` on chain id 1 |
| Environment read by `run()` | `DEPLOY_CHAIN_ID` (optional, default `11155111`) |
| Signer | supplied on the command line only (`--private-key`, `--account` keystore, or hardware wallet); never read from the environment by the script |

### Commands

Dry run (no key needed, any sender address):

```sh
forge script script/DeployObservationBuffer.s.sol:DeployObservationBuffer \
  --rpc-url https://ethereum-sepolia-rpc.publicnode.com \
  --sender 0x000000000000000000000000000000000000dEaD
```

Broadcast from a funded Sepolia test account (replace the key or use `--account <keystore>`):

```sh
forge script script/DeployObservationBuffer.s.sol:DeployObservationBuffer \
  --rpc-url https://ethereum-sepolia-rpc.publicnode.com \
  --private-key 0x<SEPOLIA_TEST_ACCOUNT_KEY> \
  --broadcast
```

Then record the outcome:

```sh
cat broadcast/DeployObservationBuffer.s.sol/11155111/run-latest.json   # contractAddress, hash
```

and fill `deployments/sepolia.json` with `address`, `deploymentTransactionHash`, `deployer`,
`blockNumber` and the explorer links `https://sepolia.etherscan.io/address/<address>` and
`https://sepolia.etherscan.io/tx/<txHash>`. Optional source verification (needs an API key):

```sh
forge verify-contract <address> src/ObservationBuffer.sol:ObservationBuffer \
  --chain sepolia --compiler-version 0.8.24 --num-of-optimizations 200 \
  --etherscan-api-key <KEY>
```

Because there are no constructor arguments and metadata is disabled, anyone can confirm a
deployment by comparing `cast code <address> --rpc-url <sepolia>` with
`forge inspect ObservationBuffer deployedBytecode` from this checkout.

### Launch-factory compatibility

If the contract is deployed through the project factory instead of the script: nonpayable
constructor, zero constructor arguments (empty `constructorArgs`), no `$owner` needed, no
`DELEGATECALL`/`CALLCODE`/`SELFDESTRUCT`, runtime 1614 bytes. It does not depend on any other
contract. No token is created by this project.

## Assumptions and limitations

* **Caller-supplied timestamps.** The specification asks for timestamps strictly increasing
  relative to the latest observation and says nothing about `block.timestamp`, so the
  contract does not consult it. Consequently timestamps are just monotone labels; they carry
  no guarantee of matching wall-clock time.
* **Griefing by timestamp jump.** Since writes are permissionless and unbounded, any account
  can submit a very large timestamp and make every honest later write revert; submitting
  `type(uint256).max` freezes the buffer permanently. This is inherent to the requested
  design (permissionless + strictly increasing + no upper bound). Operators who need
  resistance must either deploy a fresh buffer per producer, front the buffer with an
  access-controlled writer, or add an upper bound such as `timestamp <= block.timestamp`.
  This was deliberately **not** added because it was not requested and would change the
  tested behaviour.
* **No deduplication of values.** Only timestamps are constrained; the same value may be
  stored repeatedly.
* **Overwritten data is gone** from the ordered API. It remains readable on-chain only until
  the physical slot is reused, and only through `rawSlot`, which is not part of the ordered
  contract.
* **`_written` overflow** is theoretically possible after 2^256 writes and is not guarded;
  unreachable in practice.
* **Capacity is fixed** at compile time (`CAPACITY = 16`). Changing it requires redeploying.
* **Gas numbers** in this README were measured with forge 1.8.3 / solc 0.8.24 and include
  the test's call overhead. Other tooling versions may differ by a few hundred gas; the test
  bounds are deliberately loose enough to absorb that.

## Operational responsibilities

* Whoever broadcasts the deployment holds the signing key, pays gas, records the address and
  transaction hash in `deployments/sepolia.json`, and (optionally) verifies source on
  Etherscan. The contract has no admin: after deployment nobody can change, pause or drain it,
  and there is nothing to drain because it never holds ETH or tokens.
* Consumers must treat the buffer as untrusted input: any account can write any value and
  any increasing timestamp. Filter by `ObservationWritten.writer` if only specific producers
  should be trusted.
* Monitor for the freeze condition (a write with an absurd timestamp) and redeploy if it
  happens.

## Incomplete checks and non-goals

* The Sepolia broadcast itself (address, tx hash, explorer link) is **not done**; see
  "Deployment".
* The suite is a functional test suite, not a security audit. A separate adversarial review
  is expected before anything depends on this contract.
* No invariant-testing campaign (`forge test --match-contract Invariant`) was written; the
  fuzz tests cover sequences up to 100 writes only.
* Source verification on Etherscan was not performed (no deployment, no API key).
* The protected launch-floor tests shipped with the task target solc 0.8.26 and require
  factory environment variables; they were compiled locally against this project (auto-detect
  picks 0.8.26 for them) to confirm they coexist with the 0.8.24 sources, but they can only
  be run by the verifier that supplies those variables.
