// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Errors} from "./libraries/Errors.sol";

/// @title LuckToken — ERC-20 governance/reward token for Magic Potion
/// @notice Minted 1:1 per ticket purchase, 0.1 per ticket burn. Stakeable for alUSD rewards.
/// @dev Restricted minting: only the designated minter (LuckyPotion coordinator) can mint.
contract LuckToken is ERC20 {
    /// @notice Address authorized to mint LUCK tokens
    address public minter;

    /// @param _minter Initial minter address (typically the deployer, later transferred to coordinator)
    constructor(address _minter) ERC20("Lucky Potion", "LUCK") {
        if (_minter == address(0)) revert Errors.ZeroAddress();
        minter = _minter;
    }

    /// @notice Mint LUCK tokens to a recipient
    /// @param to Recipient address
    /// @param amount Amount to mint (18 decimals)
    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert Errors.OnlyMinter();
        _mint(to, amount);
    }

    /// @notice Transfer minter role to a new address
    /// @dev Only callable by current minter. Used to hand off to LuckyPotion coordinator.
    /// @param newMinter New minter address
    function setMinter(address newMinter) external {
        if (msg.sender != minter) revert Errors.OnlyMinter();
        if (newMinter == address(0)) revert Errors.ZeroAddress();
        minter = newMinter;
    }
}
