// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ObservationBuffer} from "../src/ObservationBuffer.sol";
import {DeployObservationBuffer} from "../script/DeployObservationBuffer.s.sol";

/// @notice Exercises the deployment logic directly (never `run()`, which reads the environment).
contract DeployObservationBufferTest is Test {
    DeployObservationBuffer internal deployer;

    function setUp() public {
        deployer = new DeployObservationBuffer();
    }

    function test_deploysOnSepolia() public {
        vm.chainId(deployer.SEPOLIA_CHAIN_ID());
        ObservationBuffer buffer = deployer.deploy(deployer.SEPOLIA_CHAIN_ID());
        assertGt(address(buffer).code.length, 0);
        assertEq(buffer.length(), 0);
        assertEq(buffer.CAPACITY(), 16);
        // The freshly deployed buffer is immediately usable by anyone.
        vm.prank(address(0xBEEF));
        buffer.write(1, 2);
        (uint256 ts, uint256 value) = buffer.latest();
        assertEq(ts, 1);
        assertEq(value, 2);
    }

    function test_refusesMainnet() public {
        vm.chainId(1);
        vm.expectRevert(DeployObservationBuffer.MainnetForbidden.selector);
        deployer.deploy(1);
        vm.expectRevert(DeployObservationBuffer.MainnetForbidden.selector);
        deployer.deploy(11_155_111);
    }

    function test_refusesUnexpectedChain() public {
        vm.chainId(11_155_111);
        vm.expectRevert(abi.encodeWithSelector(DeployObservationBuffer.UnexpectedChain.selector, 11_155_111, 31_337));
        deployer.deploy(31_337);
    }

    /// @dev The launch floor forbids DELEGATECALL, CALLCODE and SELFDESTRUCT in runtime code and
    ///      caps runtime at EIP-170. Same scan as the protected floor, stepping over PUSH data.
    function test_runtimeHasNoForbiddenOpcodesAndFitsEip170() public {
        vm.chainId(11_155_111);
        ObservationBuffer buffer = deployer.deploy(11_155_111);
        bytes memory code = address(buffer).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 j; j < code.length; ++j) {
            uint8 op = uint8(code[j]);
            if (op >= 0x60 && op <= 0x7f) {
                j += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
