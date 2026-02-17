// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721Enumerable, ERC721} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Constants} from "./libraries/Constants.sol";
import {Errors} from "./libraries/Errors.sol";
import {Events} from "./libraries/Events.sol";
import {SVGRenderer} from "./libraries/SVGRenderer.sol";

/// @title TicketNFT — ERC-721 lottery ticket with on-chain pixel art
/// @notice Each ticket stores its 64×64 canvas data on-chain and renders SVG in tokenURI.
/// @dev Canvas data is 1024 bytes per ticket. Gas-intensive but acceptable on Arbitrum.
contract TicketNFT is ERC721Enumerable {
    using Strings for uint256;
    using Strings for uint16;

    // ──── State ────
    address public coordinator;
    uint256 private _nextTokenId = 1;

    struct TicketData {
        uint256 drawingId;
        uint16 canvasHash;
        uint64 purchaseTime;
        bool burned;
        bytes canvasData;
    }

    mapping(uint256 => TicketData) private _tickets;

    // ──── Constructor ────

    /// @param _coordinator LuckyPotion coordinator address
    constructor(address _coordinator) ERC721("Magic Potion Ticket", "MPTICKET") {
        if (_coordinator == address(0)) revert Errors.ZeroAddress();
        coordinator = _coordinator;
    }

    // ──── Modifiers ────

    modifier onlyCoordinator() {
        if (msg.sender != coordinator) revert Errors.OnlyCoordinator();
        _;
    }

    // ──── Core Functions ────

    /// @notice Mint a new ticket NFT with canvas data stored on-chain
    /// @param to Ticket recipient
    /// @param drawingId Current drawing ID
    /// @param canvasHash Pre-computed 16-bit hash
    /// @param canvasData 1024 bytes of packed pixel data
    /// @return tokenId The minted token ID
    function mint(
        address to,
        uint256 drawingId,
        uint16 canvasHash,
        bytes calldata canvasData
    ) external onlyCoordinator returns (uint256 tokenId) {
        if (canvasData.length != Constants.CANVAS_DATA_LENGTH) {
            revert Errors.InvalidCanvasData();
        }

        tokenId = _nextTokenId++;
        _safeMint(to, tokenId);

        _tickets[tokenId] = TicketData({
            drawingId: drawingId,
            canvasHash: canvasHash,
            purchaseTime: uint64(block.timestamp),
            burned: false,
            canvasData: canvasData
        });

        emit Events.TicketMinted(tokenId, to, drawingId, canvasHash);
    }

    /// @notice Burn a ticket (marks as burned, removes from circulation)
    /// @param tokenId Token to burn
    function burn(uint256 tokenId) external onlyCoordinator {
        if (_tickets[tokenId].burned) revert Errors.TicketAlreadyBurned();

        _tickets[tokenId].burned = true;
        _burn(tokenId);
    }

    // ──── View Functions ────

    /// @notice Get ticket metadata
    /// @param tokenId Token ID to query
    /// @return data The ticket's stored data
    function getTicket(uint256 tokenId) external view returns (TicketData memory data) {
        data = _tickets[tokenId];
    }

    /// @notice On-chain JSON + SVG metadata
    /// @param tokenId Token ID
    /// @return URI as data:application/json;base64,...
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);

        TicketData storage ticket = _tickets[tokenId];
        string memory svgDataURI = SVGRenderer.renderDataURI(ticket.canvasData);

        string memory json = string(abi.encodePacked(
            '{"name":"Magic Potion Ticket #', tokenId.toString(),
            '","description":"A 64x64 pixel art lottery ticket for Magic Potion Drawing #',
            ticket.drawingId.toString(),
            '","image":"', svgDataURI,
            '","attributes":[{"trait_type":"Drawing","value":', ticket.drawingId.toString(),
            '},{"trait_type":"Canvas Hash","value":', uint256(ticket.canvasHash).toString(),
            '},{"trait_type":"Purchase Time","display_type":"date","value":', uint256(ticket.purchaseTime).toString(),
            '}]}'
        ));

        return string(abi.encodePacked(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        ));
    }

    /// @notice Get the next token ID that will be minted
    function nextTokenId() external view returns (uint256) {
        return _nextTokenId;
    }
}
