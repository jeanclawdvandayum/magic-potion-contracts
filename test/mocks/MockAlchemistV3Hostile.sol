// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MockAlchemistV3} from "./MockAlchemistV3.sol";

/// @title MockAlchemistV3Hostile — Adversarial V3 for exploit testing
/// @notice Same interface as MockAlchemistV3 but with failure switches that
///         emulate real-world V3 conditions the coordinator may hit:
///           - revertOnMint: debt ceiling reached / global mint paused
///           - minMintAmount: V3 refuses dust mints below a protocol minimum
///           - borrowableBump: yield accrual between getMaxBorrowable and mint
contract MockAlchemistV3Hostile is MockAlchemistV3 {
    bool public revertOnMint;
    uint256 public minMintAmount = 1;
    // When nonzero, mint() demands this exact amount instead (simulates a
    // borrowable value that MOVED between the coordinator's view call and mint).
    uint256 public forceMintAmount;

    constructor(
        address _alUSD,
        address _underlying,
        address _mytVault,
        address _positionNFT
    ) MockAlchemistV3(_alUSD, _underlying, _mytVault, _positionNFT) {}

    function setRevertOnMint(bool v) external { revertOnMint = v; }
    function setMinMintAmount(uint256 v) external { minMintAmount = v; }
    function setForceMintAmount(uint256 v) external { forceMintAmount = v; }

    function mint(uint256 tokenId, uint256 amount, address recipient) public override {
        if (revertOnMint) revert("HostileAlchemist: mint disabled");
        uint256 required = forceMintAmount != 0 ? forceMintAmount : amount;
        if (required < minMintAmount) revert("HostileAlchemist: below min mint");
        super.mint(tokenId, required, recipient);
    }
}
