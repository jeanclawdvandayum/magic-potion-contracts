// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {SVGRenderer} from "../../src/libraries/SVGRenderer.sol";

/// @dev Wrapper to expose internal library function
contract SVGRendererWrapper {
    function renderSVG(bytes memory canvasData) external pure returns (string memory) {
        return SVGRenderer.renderSVG(canvasData);
    }

    function renderDataURI(bytes memory canvasData) external pure returns (string memory) {
        return SVGRenderer.renderDataURI(canvasData);
    }
}

contract SVGRendererTest is Test {
    SVGRendererWrapper renderer;

    function setUp() public {
        renderer = new SVGRendererWrapper();
    }

    function _makeCanvas(uint8 fill) internal pure returns (bytes memory) {
        bytes memory canvas = new bytes(1024);
        for (uint256 i = 0; i < 1024; i++) {
            canvas[i] = bytes1(fill);
        }
        return canvas;
    }

    function test_render_allZeros() public view {
        bytes memory canvas = _makeCanvas(0x00);
        string memory svg = renderer.renderSVG(canvas);
        // All-zeros = all color 0 (#0f380f)
        // Should contain SVG tags
        assertTrue(bytes(svg).length > 0);
        // Check it starts with <svg
        bytes memory svgBytes = bytes(svg);
        assertEq(svgBytes[0], bytes1("<"));
        assertEq(svgBytes[1], bytes1("s"));
        assertEq(svgBytes[2], bytes1("v"));
        assertEq(svgBytes[3], bytes1("g"));
    }

    function test_render_allOnes() public view {
        // All 0xFF = color 11 for every pixel (#9bbc0f)
        bytes memory canvas = _makeCanvas(0xFF);
        string memory svg = renderer.renderSVG(canvas);
        assertTrue(bytes(svg).length > 0);
        // Should contain the lightest color
        assertTrue(_containsSubstring(svg, "#9bbc0f"));
    }

    function test_render_outputIsSVG() public view {
        bytes memory canvas = _makeCanvas(0xAA);
        string memory svg = renderer.renderSVG(canvas);
        assertTrue(_startsWith(svg, "<svg"));
        assertTrue(_endsWith(svg, "</svg>"));
    }

    function test_render_dataURI() public view {
        bytes memory canvas = _makeCanvas(0x00);
        string memory uri = renderer.renderDataURI(canvas);
        assertTrue(_startsWith(uri, "data:image/svg+xml;base64,"));
    }

    function test_render_knownPattern() public view {
        // Set first pixel to color 01, rest to color 00
        bytes memory canvas = _makeCanvas(0x00);
        // First byte: bits 7-6 = pixel(0,0) = set to 01 → byte = 0x40
        canvas[0] = 0x40;
        string memory svg = renderer.renderSVG(canvas);
        // Should contain the second color
        assertTrue(_containsSubstring(svg, "#306230"));
    }

    // ──── Helpers ────

    function _startsWith(string memory str, string memory prefix) internal pure returns (bool) {
        bytes memory strBytes = bytes(str);
        bytes memory prefixBytes = bytes(prefix);
        if (strBytes.length < prefixBytes.length) return false;
        for (uint i = 0; i < prefixBytes.length; i++) {
            if (strBytes[i] != prefixBytes[i]) return false;
        }
        return true;
    }

    function _endsWith(string memory str, string memory suffix) internal pure returns (bool) {
        bytes memory strBytes = bytes(str);
        bytes memory suffixBytes = bytes(suffix);
        if (strBytes.length < suffixBytes.length) return false;
        uint offset = strBytes.length - suffixBytes.length;
        for (uint i = 0; i < suffixBytes.length; i++) {
            if (strBytes[offset + i] != suffixBytes[i]) return false;
        }
        return true;
    }

    function _containsSubstring(string memory str, string memory sub) internal pure returns (bool) {
        bytes memory strBytes = bytes(str);
        bytes memory subBytes = bytes(sub);
        if (subBytes.length > strBytes.length) return false;
        for (uint i = 0; i <= strBytes.length - subBytes.length; i++) {
            bool found = true;
            for (uint j = 0; j < subBytes.length; j++) {
                if (strBytes[i + j] != subBytes[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return true;
        }
        return false;
    }
}
