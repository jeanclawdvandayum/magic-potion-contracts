// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IDrandBeacon} from "./interfaces/IDrandBeacon.sol";
import {BLS} from "./libraries/BLS.sol";

/// @title DrandBeacon — Real on-chain verification of drand evmnet beacon rounds
/// @notice Immutable beacon descriptor for drand's evmnet network (BN254 curve).
///         Verifies BLS threshold signatures entirely on-chain via the EIP-197
///         pairing precompile. Anyone may submit a round signature; validity is
///         mathematical, not permissioned.
/// @dev Non-upgradeable fork of frogworksio/anyrand DrandBeacon (MIT).
///      Differences from upstream:
///        - Public key stored as 4 immutable words instead of SSTORE2 blob
///          (removes the solady dependency; identical verification logic).
///        - Pinned to solc 0.8.24 to match the rest of the protocol.
///      evmnet chain hash: 04f1e9062b8a81f848fded9c12306733282b2727ecced50032187751166ec8c3
///      genesis 1727521075, period 3s, scheme bls-bn254-unchained-on-g1.
contract DrandBeacon is IDrandBeacon {
    /// @notice Domain separation tag required by the bls-bn254-unchained-on-g1 suite
    bytes public constant DST = bytes("BLS_SIG_BN254G1_XMD:KECCAK-256_SVDW_RO_NUL_");

    /// @dev G2 public key words: [x.c0, x.c1, y.c0, y.c1]
    uint256 internal immutable pk0;
    uint256 internal immutable pk1;
    uint256 internal immutable pk2;
    uint256 internal immutable pk3;

    uint256 internal immutable genesis;
    uint256 internal immutable beaconPeriod;

    uint256 internal immutable pkHash; // keccak256 of the 128-byte raw public key

    error InvalidPublicKey();
    error InvalidBeaconConfiguration();
    error InvalidSignature();

    /// @param publicKey_ G2 public key as [x.c0, x.c1, y.c0, y.c1]
    /// @param genesisTimestamp_ drand chain genesis (unix seconds)
    /// @param period_ round period in seconds (3 for evmnet)
    constructor(
        uint256[4] memory publicKey_,
        uint256 genesisTimestamp_,
        uint256 period_
    ) {
        if (!BLS.isValidPublicKey(publicKey_)) revert InvalidPublicKey();
        if (genesisTimestamp_ == 0 || period_ == 0) revert InvalidBeaconConfiguration();

        pk0 = publicKey_[0];
        pk1 = publicKey_[1];
        pk2 = publicKey_[2];
        pk3 = publicKey_[3];
        genesis = genesisTimestamp_;
        beaconPeriod = period_;
        pkHash = uint256(keccak256(abi.encodePacked(publicKey_[0], publicKey_[1], publicKey_[2], publicKey_[3])));
    }

    // ──── IDrandBeacon ────

    function publicKeyHash() external view returns (bytes32) {
        return bytes32(pkHash);
    }

    function genesisTimestamp() external view returns (uint256) {
        return genesis;
    }

    function period() external view returns (uint256) {
        return beaconPeriod;
    }

    function publicKey() external view returns (uint256[4] memory) {
        return [pk0, pk1, pk2, pk3];
    }

    // ──── Verification ────

    /// @notice Verify a drand beacon round signature against the known public key.
    /// @param round The beacon round number
    /// @param signature The round signature as a G1 point [x, y]
    function verifyBeaconRound(uint256 round, uint256[2] calldata signature) external view {
        // Unchained scheme: the signed message is the round number itself,
        // 8 bytes big-endian, hashed with keccak256 before hash-to-curve.
        bytes32 hashedRound = keccak256(abi.encodePacked(uint64(round)));

        uint256[2] memory message = BLS.hashToPoint(DST, abi.encodePacked(hashedRound));

        if (!BLS.isValidSignature(signature)) revert InvalidSignature();

        uint256[4] memory pubKey = [pk0, pk1, pk2, pk3];

        (bool pairingSuccess, bool callSuccess) = BLS.verifySingle(signature, pubKey, message);
        // EIP-197: malformed inputs make the precompile call itself fail.
        // That would mean a bug in our encoding — fail loudly.
        assert(callSuccess);
        if (!pairingSuccess) revert InvalidSignature();
    }
}
