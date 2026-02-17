// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Constants} from "../../src/libraries/Constants.sol";

/// @title Constants Tests
/// @notice Verify protocol constants are internally consistent
contract ConstantsTest is Test {
    /// @notice BPS allocations must sum to exactly 10000
    function test_bpsSum() public pure {
        assertEq(
            Constants.OPS_BPS + Constants.STAKING_BPS + Constants.PRIZE_BPS,
            Constants.BPS_DENOMINATOR,
            "BPS must sum to 10000"
        );
    }

    /// @notice Canvas data length matches 64x64 grid at 2 bits per pixel
    function test_canvasDataLength() public pure {
        // 64 * 64 pixels * 2 bits / 8 bits per byte = 1024
        uint256 expected = (64 * 64 * 2) / 8;
        assertEq(Constants.CANVAS_DATA_LENGTH, expected, "Canvas data length mismatch");
    }

    /// @notice Hash space is 2^16
    function test_hashSpace() public pure {
        assertEq(Constants.HASH_SPACE, 2 ** 16, "Hash space must be 2^16");
    }

    /// @notice Ticket cutoff is less than drawing duration
    function test_cutoffLessThanDuration() public pure {
        assertTrue(
            Constants.TICKET_CUTOFF < Constants.DRAWING_DURATION,
            "Cutoff must be less than drawing duration"
        );
    }

    /// @notice Burn reward is less than mint reward
    function test_burnRewardLessThanMint() public pure {
        assertTrue(
            Constants.BURN_LUCK_REWARD < Constants.LUCK_PER_TICKET,
            "Burn reward must be less than mint reward"
        );
    }

    /// @notice TICKET_PRICE is $5 in 6 decimals
    function test_ticketPrice() public pure {
        assertEq(Constants.TICKET_PRICE, 5 * 10 ** 6, "Ticket price must be $5 USDC");
    }
}
