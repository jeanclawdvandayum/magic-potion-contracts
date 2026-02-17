// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAlchemistV3 — Minimal interface for Alchemix V3 integration
/// @notice Only the functions Magic Potion needs to interact with
interface IAlchemistV3 {
    /// @notice Deposit underlying token as collateral
    /// @param yieldToken The yield-bearing vault token registered in Alchemist
    /// @param amount Amount of underlying token (e.g., USDC, 6 decimals)
    /// @param recipient Position owner
    /// @return shares Shares received
    function deposit(
        address yieldToken,
        uint256 amount,
        address recipient
    ) external returns (uint256 shares);

    /// @notice Mint alUSD against deposited collateral
    /// @param amount alUSD amount to mint (18 decimals)
    /// @param recipient Receives the alUSD
    function mint(uint256 amount, address recipient) external;

    /// @notice Query max additional alUSD mintable for an account
    /// @param account The position holder
    /// @return maxMintable Additional alUSD that can be minted
    function getMintAllowance(address account) external view returns (uint256 maxMintable);

    /// @notice Query total deposited value for an account (in underlying terms)
    /// @param account The position holder
    /// @return value Total value in underlying token decimals
    function totalValue(address account) external view returns (uint256 value);

    /// @notice Query total debt for an account
    /// @param account The position holder
    /// @return debt Total debt (can be negative if overpaid)
    function debt(address account) external view returns (int256 debt);
}
