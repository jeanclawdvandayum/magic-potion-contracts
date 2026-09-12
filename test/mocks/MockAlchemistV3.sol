// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IAlchemistV3, IVaultV2} from "../../src/interfaces/IAlchemistV3.sol";
import {MockERC20} from "./MockERC20.sol";

/// @title MockAlchemistV3 — Test mock for Alchemix V3 Alchemist
/// @notice Simulates V3 NFT-based positions with deposit/mint/CDP tracking.
///         Mirrors the real V3 interface with tokenId-based positions.
contract MockAlchemistV3 is IAlchemistV3 {
    uint256 public constant LTV_BPS = 9000;
    uint256 public constant BPS = 10_000;

    MockERC20 public alUSDToken;
    MockERC20 public usdcToken; // USDC underlying
    address public mytVaultAddress;
    address public positionNFTAddress;

    uint256 private nextTokenId = 1;

    struct Position {
        uint256 collateral; // in MYT shares (18 dec)
        uint256 debt;       // in alUSD (18 dec)
        uint256 earmarked;
    }

    mapping(uint256 => Position) public positions;

    constructor(address _alUSD, address _underlying, address _mytVault, address _positionNFT) {
        alUSDToken = MockERC20(_alUSD);
        usdcToken = MockERC20(_underlying);
        mytVaultAddress = _mytVault;
        positionNFTAddress = _positionNFT;
    }

    function deposit(
        uint256 amount,
        address recipient,
        uint256 recipientId
    ) external override returns (uint256 tokenId, uint256 debtValue) {
        // Accept MYT shares (already approved by caller)
        // In tests, MYT shares are a mock ERC20 at mytVaultAddress
        MockERC20(mytVaultAddress).transferFrom(msg.sender, address(this), amount);

        if (recipientId == 0) {
            // Create new position
            tokenId = nextTokenId++;
        } else {
            tokenId = recipientId;
        }

        positions[tokenId].collateral += amount;
        debtValue = amount; // 1:1 for simplicity

        return (tokenId, debtValue);
    }

    function mint(uint256 tokenId, uint256 amount, address recipient) external virtual override {
        uint256 maxBorrow = getMaxBorrowable(tokenId);
        require(amount <= maxBorrow, "MockAlchemist: insufficient borrowable");

        positions[tokenId].debt += amount;
        alUSDToken.mint(recipient, amount);
    }

    function getCDP(uint256 tokenId) external view override returns (
        uint256 collateral,
        uint256 debt,
        uint256 earmarked
    ) {
        Position storage pos = positions[tokenId];
        return (pos.collateral, pos.debt, pos.earmarked);
    }

    function totalValue(uint256 tokenId) external view override returns (uint256) {
        return positions[tokenId].collateral;
    }

    function getMaxBorrowable(uint256 tokenId) public view override returns (uint256) {
        Position storage pos = positions[tokenId];
        // Collateral is stored in MYT-share units (numerically == USDC, 6 dec);
        // real V3 reports borrowable value in debt-token terms (18 dec).
        uint256 maxDebt = (pos.collateral * LTV_BPS) / BPS * 1e12;
        if (maxDebt <= pos.debt) return 0;
        return maxDebt - pos.debt;
    }

    function myt() external view override returns (address) {
        return mytVaultAddress;
    }

    function underlyingToken() external view override returns (address) {
        return address(usdcToken);
    }

    function alchemistPositionNFT() external view override returns (address) {
        return positionNFTAddress;
    }

    function normalizeUnderlyingTokensToDebt(uint256 amount) external pure override returns (uint256) {
        return amount * 1e12; // 6 dec -> 18 dec
    }
}

/// @title MockMYTVault — Test mock for the MYT ERC-4626 vault
/// @notice Wraps USDC into MYT shares at 1:1 ratio for testing.
///         Inherits ERC20 so it can be approved/transferred like the real MYT vault.
contract MockMYTVault is IVaultV2, MockERC20 {
    MockERC20 public asset; // USDC

    constructor(address _asset, address _share) MockERC20("Mix Yield Token", "mytUSDC", 18) {
        asset = MockERC20(_asset);
        // _share is ignored since we ARE the share token
    }

    function deposit(uint256 assets, address receiver) external override returns (uint256 shares) {
        asset.transferFrom(msg.sender, address(this), assets);
        shares = assets; // 1:1
        _mint(receiver, shares);
        return shares;
    }

    function redeem(uint256 shares, address receiver, address /* owner */) external override returns (uint256 assets) {
        _burn(msg.sender, shares);
        assets = shares;
        asset.transfer(receiver, assets);
        return assets;
    }

    function convertToShares(uint256 assets) external pure override returns (uint256) {
        return assets;
    }

    function convertToAssets(uint256 shares) external pure override returns (uint256) {
        return shares;
    }

    function totalAssets() external view override returns (uint256) {
        return asset.balanceOf(address(this));
    }
}
