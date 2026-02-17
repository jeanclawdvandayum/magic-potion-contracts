// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {TicketNFT} from "../../src/TicketNFT.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {Errors} from "../../src/libraries/Errors.sol";

contract TicketNFTTest is Test {
    TicketNFT nft;
    address coordinator = address(0xC00D);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        nft = new TicketNFT(coordinator);
    }

    function _makeCanvas(uint8 fill) internal pure returns (bytes memory) {
        bytes memory canvas = new bytes(1024);
        for (uint256 i = 0; i < 1024; i++) {
            canvas[i] = bytes1(fill);
        }
        return canvas;
    }

    // ──── Constructor ────

    function test_constructorZeroAddress_reverts() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new TicketNFT(address(0));
    }

    function test_nameAndSymbol() public view {
        assertEq(nft.name(), "Magic Potion Ticket");
        assertEq(nft.symbol(), "MPTICKET");
    }

    // ──── Minting ────

    function test_mint_onlyCoordinator() public {
        bytes memory canvas = _makeCanvas(0x00);
        vm.prank(coordinator);
        uint256 tokenId = nft.mint(alice, 1, 0x1234, canvas);
        assertEq(tokenId, 1);
        assertEq(nft.ownerOf(1), alice);
    }

    function test_mint_nonCoordinator_reverts() public {
        bytes memory canvas = _makeCanvas(0x00);
        vm.prank(alice);
        vm.expectRevert(Errors.OnlyCoordinator.selector);
        nft.mint(alice, 1, 0x1234, canvas);
    }

    function test_mint_storesCanvasData() public {
        bytes memory canvas = _makeCanvas(0xAB);
        vm.prank(coordinator);
        nft.mint(alice, 42, 0x5678, canvas);

        TicketNFT.TicketData memory data = nft.getTicket(1);
        assertEq(data.drawingId, 42);
        assertEq(data.canvasHash, 0x5678);
        assertEq(data.purchaseTime, block.timestamp);
        assertEq(data.burned, false);
        assertEq(data.canvasData.length, 1024);
        assertEq(uint8(data.canvasData[0]), 0xAB);
    }

    function test_mint_incrementsTokenId() public {
        bytes memory canvas = _makeCanvas(0x00);
        vm.startPrank(coordinator);
        uint256 id1 = nft.mint(alice, 1, 0x01, canvas);
        uint256 id2 = nft.mint(bob, 1, 0x02, canvas);
        uint256 id3 = nft.mint(alice, 1, 0x03, canvas);
        vm.stopPrank();

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(id3, 3);
        assertEq(nft.nextTokenId(), 4);
    }

    function test_mint_invalidCanvasData_reverts() public {
        bytes memory tooShort = new bytes(1023);
        vm.prank(coordinator);
        vm.expectRevert(Errors.InvalidCanvasData.selector);
        nft.mint(alice, 1, 0x01, tooShort);

        bytes memory tooLong = new bytes(1025);
        vm.prank(coordinator);
        vm.expectRevert(Errors.InvalidCanvasData.selector);
        nft.mint(alice, 1, 0x01, tooLong);
    }

    // ──── Burning ────

    function test_burn_onlyCoordinator() public {
        bytes memory canvas = _makeCanvas(0x00);
        vm.prank(coordinator);
        nft.mint(alice, 1, 0x01, canvas);

        vm.prank(coordinator);
        nft.burn(1);

        // Token should no longer exist
        vm.expectRevert();
        nft.ownerOf(1);
    }

    function test_burn_nonCoordinator_reverts() public {
        bytes memory canvas = _makeCanvas(0x00);
        vm.prank(coordinator);
        nft.mint(alice, 1, 0x01, canvas);

        vm.prank(alice);
        vm.expectRevert(Errors.OnlyCoordinator.selector);
        nft.burn(1);
    }

    function test_burn_preventDoubleBurn() public {
        bytes memory canvas = _makeCanvas(0x00);
        vm.prank(coordinator);
        nft.mint(alice, 1, 0x01, canvas);

        vm.prank(coordinator);
        nft.burn(1);

        vm.prank(coordinator);
        vm.expectRevert(Errors.TicketAlreadyBurned.selector);
        nft.burn(1);
    }

    function test_burn_markedAsBurned() public {
        bytes memory canvas = _makeCanvas(0x00);
        vm.prank(coordinator);
        nft.mint(alice, 1, 0x01, canvas);

        vm.prank(coordinator);
        nft.burn(1);

        TicketNFT.TicketData memory data = nft.getTicket(1);
        assertTrue(data.burned);
    }

    // ──── Transfers ────

    function test_transfer_works() public {
        bytes memory canvas = _makeCanvas(0x00);
        vm.prank(coordinator);
        nft.mint(alice, 1, 0x01, canvas);

        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);
        assertEq(nft.ownerOf(1), bob);
    }

    // ──── Token URI ────

    function test_tokenURI_returnsValidJSON() public {
        bytes memory canvas = _makeCanvas(0x00);
        vm.prank(coordinator);
        nft.mint(alice, 1, 0x1234, canvas);

        string memory uri = nft.tokenURI(1);
        // Should start with data:application/json;base64,
        bytes memory uriBytes = bytes(uri);
        // Check prefix
        bytes memory prefix = bytes("data:application/json;base64,");
        for (uint i = 0; i < prefix.length; i++) {
            assertEq(uriBytes[i], prefix[i]);
        }
        // URI should be non-empty beyond the prefix
        assertTrue(uriBytes.length > prefix.length + 10);
    }

    function test_tokenURI_nonexistent_reverts() public {
        vm.expectRevert();
        nft.tokenURI(999);
    }

    // ──── Enumerable ────

    function test_enumerable_totalSupply() public {
        bytes memory canvas = _makeCanvas(0x00);
        vm.startPrank(coordinator);
        nft.mint(alice, 1, 0x01, canvas);
        nft.mint(bob, 1, 0x02, canvas);
        vm.stopPrank();

        assertEq(nft.totalSupply(), 2);

        vm.prank(coordinator);
        nft.burn(1);
        assertEq(nft.totalSupply(), 1);
    }
}
