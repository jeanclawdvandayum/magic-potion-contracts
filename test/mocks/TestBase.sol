// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockAlchemistV3, MockMYTVault} from "./MockAlchemistV3.sol";

/// @title TestBase — Shared setup for all Magic Potion tests
/// @notice Deploys all mocks and wires up the LuckyPotion coordinator.
///         Individual test contracts inherit from this and get a fully
///         initialized protocol ready for testing.
contract TestBase is Test {
    MockERC20 public usdc;
    MockERC20 public alUSD;
    MockERC20 public mytShare;
    MockAlchemistV3 public alchemist;
    MockMYTVault public mytVault;

    // Sub-contracts deployed by the coordinator are accessed via coordinator

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public treasury = makeAddr("treasury");

    function _setupTokens() internal {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        alUSD = new MockERC20("Alchemix USD", "alUSD", 18);
        mytShare = new MockERC20("Mix Yield Token USDC", "mytUSDC", 18);
        mytVault = new MockMYTVault(address(usdc), address(mytShare));
        alchemist = new MockAlchemistV3(
            address(alUSD),
            address(usdc),
            address(mytVault),
            address(0) // position NFT (not needed for mock)
        );
    }

    /// @dev Mint USDC to an address and approve the spender
    function _giveUsdc(address to, uint256 amount, address spender) internal {
        usdc.mint(to, amount);
        vm.prank(to);
        usdc.approve(spender, type(uint256).max);
    }
}
