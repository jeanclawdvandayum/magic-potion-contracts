// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {CanvasHash} from "../../src/libraries/CanvasHash.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {Errors} from "../../src/libraries/Errors.sol";

/// @dev Wrapper to expose library as external calls (needed for vm.expectRevert)
contract CanvasHashWrapper {
    function computeCanvasHash(bytes calldata canvasData) external pure returns (uint16) {
        return CanvasHash.computeCanvasHash(canvasData);
    }
}

/// @title CanvasHash Tests
/// @notice Verifies deterministic hashing, output bounds, and revert conditions
contract CanvasHashTest is Test {
    CanvasHashWrapper wrapper;

    function setUp() public {
        wrapper = new CanvasHashWrapper();
    }
    /// @notice Same input always produces same output
    function test_deterministic() public pure {
        bytes memory canvas = new bytes(1024);
        // Fill with a known pattern
        for (uint256 i = 0; i < 1024; i++) {
            canvas[i] = bytes1(uint8(i % 256));
        }
        uint16 hash1 = CanvasHash.computeCanvasHash(canvas);
        uint16 hash2 = CanvasHash.computeCanvasHash(canvas);
        assertEq(hash1, hash2, "Hash must be deterministic");
    }

    /// @notice All-zeros canvas produces a known, stable hash
    function test_allZeros_knownValue() public pure {
        bytes memory canvas = new bytes(1024);
        uint16 result = CanvasHash.computeCanvasHash(canvas);
        // keccak256 of 1024 zero bytes is deterministic
        uint16 expected = uint16(uint256(keccak256(canvas)) & 0xFFFF);
        assertEq(result, expected, "All-zeros hash mismatch");
    }

    /// @notice All-0xFF canvas produces a known, stable hash
    function test_allOnes_knownValue() public pure {
        bytes memory canvas = new bytes(1024);
        for (uint256 i = 0; i < 1024; i++) {
            canvas[i] = 0xFF;
        }
        uint16 result = CanvasHash.computeCanvasHash(canvas);
        uint16 expected = uint16(uint256(keccak256(canvas)) & 0xFFFF);
        assertEq(result, expected, "All-ones hash mismatch");
    }

    /// @notice Output is always within the 16-bit range
    function test_outputBound() public pure {
        bytes memory canvas = new bytes(1024);
        canvas[0] = 0xAB;
        canvas[512] = 0xCD;
        uint16 result = CanvasHash.computeCanvasHash(canvas);
        assertTrue(result < 65536, "Hash must be < 65536");
    }

    /// @notice Different canvases produce different hashes (probabilistic, but 2 specific inputs)
    function test_differentInputs_differentOutputs() public pure {
        bytes memory canvas1 = new bytes(1024);
        bytes memory canvas2 = new bytes(1024);
        canvas2[0] = 0x01;
        uint16 hash1 = CanvasHash.computeCanvasHash(canvas1);
        uint16 hash2 = CanvasHash.computeCanvasHash(canvas2);
        // These specific inputs should differ (extremely unlikely to collide)
        assertTrue(hash1 != hash2, "Different canvases should produce different hashes");
    }

    /// @notice Canvas data shorter than 1024 bytes reverts
    function test_tooShort_reverts() public {
        bytes memory canvas = new bytes(1023);
        vm.expectRevert(Errors.InvalidCanvasData.selector);
        wrapper.computeCanvasHash(canvas);
    }

    /// @notice Canvas data longer than 1024 bytes reverts
    function test_tooLong_reverts() public {
        bytes memory canvas = new bytes(1025);
        vm.expectRevert(Errors.InvalidCanvasData.selector);
        wrapper.computeCanvasHash(canvas);
    }

    /// @notice Empty canvas data reverts
    function test_empty_reverts() public {
        bytes memory canvas = new bytes(0);
        vm.expectRevert(Errors.InvalidCanvasData.selector);
        wrapper.computeCanvasHash(canvas);
    }

    /// @notice Fuzz: any valid-length input produces output < HASH_SPACE
    function testFuzz_outputAlwaysValid(bytes calldata seed) public pure {
        // Build a 1024-byte canvas from arbitrary seed
        bytes memory canvas = new bytes(1024);
        for (uint256 i = 0; i < 1024; i++) {
            if (i < seed.length) {
                canvas[i] = seed[i];
            }
        }
        uint16 result = CanvasHash.computeCanvasHash(canvas);
        assertTrue(result < Constants.HASH_SPACE, "Hash must be within HASH_SPACE");
    }

    /// @notice Fuzz: hash is deterministic for any input
    function testFuzz_deterministic(bytes calldata seed) public pure {
        bytes memory canvas = new bytes(1024);
        for (uint256 i = 0; i < 1024; i++) {
            if (i < seed.length) {
                canvas[i] = seed[i];
            }
        }
        uint16 hash1 = CanvasHash.computeCanvasHash(canvas);
        uint16 hash2 = CanvasHash.computeCanvasHash(canvas);
        assertEq(hash1, hash2, "Must be deterministic");
    }
}
