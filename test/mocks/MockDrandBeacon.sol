// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IDrandBeacon} from "../../src/interfaces/IDrandBeacon.sol";

/// @title MockDrandBeacon — For testing drand integration without real BLS verification
contract MockDrandBeacon is IDrandBeacon {
    bytes32 private _pubKeyHash = keccak256("mock_drand_pubkey");
    // Default 0 so rounds are computable at foundry's default block.timestamp=1.
    // The real quicknet genesis (1727521075) is only meaningful on live chains,
    // where block.timestamp is always past it. Tests wanting realism use setGenesis.
    uint256 private _genesis = 0;
    uint256 private _period = 3;

    // round => signature, set by tests
    mapping(uint256 => uint256[2]) private _signatures;
    mapping(uint256 => bool) private _hasSignature;

    function setGenesis(uint256 g) external { _genesis = g; }

    function setSignature(uint256 round, uint256[2] memory sig) external {
        _signatures[round] = sig;
        _hasSignature[round] = true;
    }

    function publicKeyHash() external view returns (bytes32) { return _pubKeyHash; }
    function genesisTimestamp() external view returns (uint256) { return _genesis; }
    function period() external view returns (uint256) { return _period; }

    /// @dev In mock mode, just check that a signature was set for this round.
    ///      Real BLS verification happens on-chain with the deployed DrandBeacon.
    function verifyBeaconRound(uint256 round, uint256[2] calldata signature) external view {
        require(_hasSignature[round], "No signature set for round");
        require(
            _signatures[round][0] == signature[0] && _signatures[round][1] == signature[1],
            "Signature mismatch"
        );
    }
}
