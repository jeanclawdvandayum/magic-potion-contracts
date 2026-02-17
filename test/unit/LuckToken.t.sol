// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {LuckToken} from "../../src/LuckToken.sol";
import {Errors} from "../../src/libraries/Errors.sol";

contract LuckTokenTest is Test {
    LuckToken token;
    address minter = address(0xBEEF);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        token = new LuckToken(minter);
    }

    function test_name_symbol_decimals() public view {
        assertEq(token.name(), "Lucky Potion");
        assertEq(token.symbol(), "LUCK");
        assertEq(token.decimals(), 18);
    }

    function test_minterSetCorrectly() public view {
        assertEq(token.minter(), minter);
    }

    function test_constructorZeroAddress_reverts() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new LuckToken(address(0));
    }

    function test_mint_onlyMinter() public {
        vm.prank(minter);
        token.mint(alice, 1e18);
        assertEq(token.balanceOf(alice), 1e18);
        assertEq(token.totalSupply(), 1e18);
    }

    function test_mint_nonMinter_reverts() public {
        vm.prank(alice);
        vm.expectRevert(Errors.OnlyMinter.selector);
        token.mint(alice, 1e18);
    }

    function test_mint_updatesBalanceAndSupply() public {
        vm.startPrank(minter);
        token.mint(alice, 5e18);
        token.mint(bob, 3e18);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), 5e18);
        assertEq(token.balanceOf(bob), 3e18);
        assertEq(token.totalSupply(), 8e18);
    }

    function test_transfer_standard() public {
        vm.prank(minter);
        token.mint(alice, 10e18);

        vm.prank(alice);
        token.transfer(bob, 3e18);

        assertEq(token.balanceOf(alice), 7e18);
        assertEq(token.balanceOf(bob), 3e18);
    }

    function test_setMinter_onlyCurrentMinter() public {
        vm.prank(minter);
        token.setMinter(alice);
        assertEq(token.minter(), alice);
    }

    function test_setMinter_nonMinter_reverts() public {
        vm.prank(alice);
        vm.expectRevert(Errors.OnlyMinter.selector);
        token.setMinter(bob);
    }

    function test_setMinter_zeroAddress_reverts() public {
        vm.prank(minter);
        vm.expectRevert(Errors.ZeroAddress.selector);
        token.setMinter(address(0));
    }

    function test_setMinter_newMinterCanMint() public {
        vm.prank(minter);
        token.setMinter(alice);

        // Old minter can't mint
        vm.prank(minter);
        vm.expectRevert(Errors.OnlyMinter.selector);
        token.mint(bob, 1e18);

        // New minter can mint
        vm.prank(alice);
        token.mint(bob, 1e18);
        assertEq(token.balanceOf(bob), 1e18);
    }
}
