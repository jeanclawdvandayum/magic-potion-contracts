// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

/// @title SVGRenderer — On-chain SVG from 64×64 Game Boy pixel art
/// @notice Renders canvas data (1024 bytes, 2 bits/pixel) to an SVG data URI
/// @dev Game Boy 4-color palette. Row-major scan with run-length encoding for gas savings.
library SVGRenderer {
    // Game Boy palette (darkest to lightest)
    string private constant C0 = "#0f380f"; // 00
    string private constant C1 = "#306230"; // 01
    string private constant C2 = "#8bac0f"; // 10
    string private constant C3 = "#9bbc0f"; // 11

    /// @notice Render canvas data to an SVG string
    /// @param canvasData 1024 bytes of packed pixel data
    /// @return svg The complete SVG markup (not base64 encoded)
    function renderSVG(bytes memory canvasData) internal pure returns (string memory svg) {
        // Build the SVG content with rect elements
        // Each pixel is 4x4 in the output SVG (256x256 viewport)
        bytes memory rects = "";

        for (uint256 y = 0; y < 64; y++) {
            uint256 x = 0;
            while (x < 64) {
                uint8 color = _getPixel(canvasData, x, y);
                // Run-length: count consecutive same-color pixels in this row
                uint256 runLen = 1;
                while (x + runLen < 64 && _getPixel(canvasData, x + runLen, y) == color) {
                    runLen++;
                }
                // Only emit rects for non-background pixels, or all if we want full coverage
                rects = abi.encodePacked(
                    rects,
                    '<rect x="', _uint2str(x * 4),
                    '" y="', _uint2str(y * 4),
                    '" width="', _uint2str(runLen * 4),
                    '" height="4" fill="', _colorHex(color), '"/>'
                );
                x += runLen;
            }
        }

        svg = string(abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" shape-rendering="crispEdges">',
            '<rect width="256" height="256" fill="', C0, '"/>',
            rects,
            '</svg>'
        ));
    }

    /// @notice Render canvas data to a base64-encoded SVG data URI
    /// @param canvasData 1024 bytes of packed pixel data
    /// @return dataURI The data:image/svg+xml;base64,... URI
    function renderDataURI(bytes memory canvasData) internal pure returns (string memory dataURI) {
        string memory svg = renderSVG(canvasData);
        dataURI = string(abi.encodePacked(
            "data:image/svg+xml;base64,",
            Base64.encode(bytes(svg))
        ));
    }

    /// @notice Extract a 2-bit pixel value from packed canvas data
    /// @param canvasData The packed pixel data
    /// @param x X coordinate (0-63)
    /// @param y Y coordinate (0-63)
    /// @return color 2-bit color index (0-3)
    function _getPixel(bytes memory canvasData, uint256 x, uint256 y) private pure returns (uint8 color) {
        uint256 bitIndex = (y * 64 + x) * 2;
        uint256 byteIndex = bitIndex / 8;
        uint256 bitOffset = 6 - (bitIndex % 8); // MSB-first within byte
        color = uint8((uint8(canvasData[byteIndex]) >> bitOffset) & 0x03);
    }

    function _colorHex(uint8 color) private pure returns (string memory) {
        if (color == 0) return C0;
        if (color == 1) return C1;
        if (color == 2) return C2;
        return C3;
    }

    function _uint2str(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
