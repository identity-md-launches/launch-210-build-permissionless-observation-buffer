// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ObservationBuffer} from "../src/ObservationBuffer.sol";

/// @title DeployObservationBuffer
/// @notice Deploys {ObservationBuffer} (no constructor arguments) to the chain the RPC points at.
/// @dev `run()` reads the environment and broadcasts; `deploy()` contains the actual logic and is
///      what the unit tests call directly, so tests never touch the process environment.
///
///      Environment read by `run()`:
///        DEPLOY_CHAIN_ID  optional, defaults to 11155111 (Sepolia). The script refuses to run
///                         on any other chain and always refuses chain id 1 (Ethereum mainnet).
///
///      The signing key is never read by this script. Supply it on the command line
///      (`--private-key`, `--account`, `--ledger`, ...). See README "Deployment".
contract DeployObservationBuffer is Script {
    uint256 public constant SEPOLIA_CHAIN_ID = 11_155_111;
    uint256 public constant MAINNET_CHAIN_ID = 1;

    error MainnetForbidden();
    error UnexpectedChain(uint256 actual, uint256 expected);

    function run() external returns (ObservationBuffer buffer) {
        uint256 expectedChainId = vm.envOr("DEPLOY_CHAIN_ID", SEPOLIA_CHAIN_ID);
        vm.startBroadcast();
        buffer = deploy(expectedChainId);
        vm.stopBroadcast();
        console2.log("ObservationBuffer deployed at", address(buffer));
        console2.log("chain id", block.chainid);
    }

    /// @notice Deploy after checking the chain. Pure deployment logic, callable from tests.
    /// @param expectedChainId Chain the caller intends to deploy to; must equal `block.chainid`.
    function deploy(uint256 expectedChainId) public returns (ObservationBuffer buffer) {
        if (block.chainid == MAINNET_CHAIN_ID || expectedChainId == MAINNET_CHAIN_ID) revert MainnetForbidden();
        if (block.chainid != expectedChainId) revert UnexpectedChain(block.chainid, expectedChainId);
        buffer = new ObservationBuffer();
    }
}
