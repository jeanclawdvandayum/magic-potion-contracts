// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IAlchemistV3 — Minimal interface for Alchemix V3 integration
/// @notice Verified against github.com/alchemix-finance/v3 actual source.
interface IAlchemistV3 {
    /// @notice Deposit yield tokens (MYT shares) into a position.
    /// @param amount Amount of yield tokens to deposit
    /// @param recipient Owner of the account receiving the shares
    /// @param recipientId The tokenId of the account (0 to create new position)
    /// @return tokenId The id of the position NFT
    /// @return debtValue Value of deposited tokens normalized to debt token
    function deposit(
        uint256 amount,
        address recipient,
        uint256 recipientId
    ) external returns (uint256 tokenId, uint256 debtValue);

    /// @notice Mint debt tokens against a position.
    /// @param tokenId The position NFT id
    /// @param amount Amount of debt to mint (18 decimals)
    /// @param recipient Receives the minted tokens
    function mint(uint256 tokenId, uint256 amount, address recipient) external;

    /// @notice Get CDP info for a position.
    function getCDP(uint256 tokenId) external view returns (
        uint256 collateral,
        uint256 debt,
        uint256 earmarked
    );

    /// @notice Get total value of a position in underlying tokens.
    function totalValue(uint256 tokenId) external view returns (uint256);

    /// @notice Get maximum borrowable debt for a position.
    function getMaxBorrowable(uint256 tokenId) external view returns (uint256);

    /// @notice The MYT vault address (yield token).
    function myt() external view returns (address);

    /// @notice The underlying token (USDC).
    function underlyingToken() external view returns (address);

    /// @notice The position NFT contract.
    function alchemistPositionNFT() external view returns (address);

    /// @notice Convert underlying tokens to debt tokens (handles decimals).
    function normalizeUnderlyingTokensToDebt(uint256 amount) external view returns (uint256);
}

/// @title IVaultV2 — Minimal ERC-4626 vault interface for MYT
/// @notice The MYT vault wraps USDC into yield-bearing shares.
interface IVaultV2 {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function totalAssets() external view returns (uint256);
}
