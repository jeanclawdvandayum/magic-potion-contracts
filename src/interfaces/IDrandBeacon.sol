// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IDrandBeacon
/// @notice Minimal interface for verifying drand beacon signatures on-chain.
///         Works with any DrandBeacon contract that stores the evmnet public key
///         and verifies BLS signatures via the BN254 pairing precompile.
interface IDrandBeacon {
    function publicKeyHash() external view returns (bytes32);
    function genesisTimestamp() external view returns (uint256);
    function period() external view returns (uint256);

    /// @notice Verify a drand beacon round signature against the known public key.
    ///         Reverts if the signature is invalid.
    /// @param round The beacon round number
    /// @param signature The BLS signature on G1 (2x uint256 = 64 bytes)
    function verifyBeaconRound(uint256 round, uint256[2] calldata signature) external view;
}
