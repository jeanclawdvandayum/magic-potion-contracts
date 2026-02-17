// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAlchemistV3} from "../../src/interfaces/IAlchemistV3.sol";
import {MockERC20} from "./MockERC20.sol";

/// @title MockAlchemistV3 — Test mock for Alchemix V3 Alchemist
/// @notice Simulates deposit/mint/debt tracking. Mints real alUSD tokens on mint().
contract MockAlchemistV3 is IAlchemistV3 {
    uint256 public constant LTV_BPS = 9000; // 90% LTV
    uint256 public constant BPS = 10_000;

    MockERC20 public alUSD;
    MockERC20 public underlyingToken; // USDC

    mapping(address => uint256) public deposited;  // in underlying decimals
    mapping(address => uint256) public mintedDebt;  // in 18 decimals

    constructor(address _alUSD, address _underlying) {
        alUSD = MockERC20(_alUSD);
        underlyingToken = MockERC20(_underlying);
    }

    function deposit(
        address /* yieldToken */,
        uint256 amount,
        address recipient
    ) external override returns (uint256 shares) {
        // Transfer underlying from caller
        underlyingToken.transferFrom(msg.sender, address(this), amount);
        deposited[recipient] += amount;
        return amount; // 1:1 shares
    }

    function mint(uint256 amount, address recipient) external override {
        uint256 allowance = _getMintAllowance(msg.sender);
        require(amount <= allowance, "MockAlchemist: insufficient mint allowance");
        mintedDebt[msg.sender] += amount;
        // Mint real alUSD to recipient
        alUSD.mint(recipient, amount);
    }

    function getMintAllowance(address account) public view override returns (uint256 maxMintable) {
        return _getMintAllowance(account);
    }

    function _getMintAllowance(address account) internal view returns (uint256) {
        // Scale deposited (6 dec) to 18 dec, then apply 90% LTV
        uint256 depositedValue18 = deposited[account] * 1e12;
        uint256 maxDebt = (depositedValue18 * LTV_BPS) / BPS;
        if (maxDebt <= mintedDebt[account]) return 0;
        return maxDebt - mintedDebt[account];
    }

    function totalValue(address account) external view override returns (uint256 value) {
        return deposited[account];
    }

    function debt(address account) external view override returns (int256) {
        return int256(mintedDebt[account]);
    }
}
