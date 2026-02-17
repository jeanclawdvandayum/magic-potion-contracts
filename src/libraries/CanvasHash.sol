// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Constants} from "./Constants.sol";
import {Errors} from "./Errors.sol";

/// @title CanvasHash — Deterministic 16-bit hash from 64×64 pixel art
/// @notice Maps a 1024-byte canvas (64×64, 4 colors, 2 bits/pixel) to a 16-bit lottery number
/// @dev keccak256 → truncate to uint16. Uniform distribution since 65536 is 2^16
///      and keccak256 is cryptographically uniform. No modulo bias.
library CanvasHash {
    /// @notice Compute the 16-bit lottery hash from canvas pixel data
    /// @param canvasData Exactly 1024 bytes of packed pixel data
    ///        Encoding: 2 bits per pixel, row-major, 4 pixels per byte
    ///        Pixel (x,y) at bit position (y * 64 + x) * 2
    /// @return hash16 The 16-bit hash value (0 to 65535)
    function computeCanvasHash(bytes memory canvasData) internal pure returns (uint16 hash16) {
        if (canvasData.length != Constants.CANVAS_DATA_LENGTH) {
            revert Errors.InvalidCanvasData();
        }
        hash16 = uint16(uint256(keccak256(canvasData)) & 0xFFFF);
    }
}
