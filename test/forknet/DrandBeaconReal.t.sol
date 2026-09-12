// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {DrandBeacon} from "../../src/DrandBeacon.sol";

/// @title DrandBeaconRealDataTest — verifies our beacon port against REAL drand data
/// @notice Data pinned from api.drand.sh evmnet on 2026-08-14 (test/forknet/drand-fixture.json).
///         This is a LOCAL test: BN254 precompiles exist on every EVM chain, so no fork needed.
///         Purpose: (1) prove the ported BLS.verifySingle + hashToPoint reproduce drand's
///         evmnet verification exactly; (2) settle the public-key word order assumption.
contract DrandBeaconRealDataTest is Test {
    // ── pinned real data (evmnet, chain 04f1e90...) ──
    uint256 internal constant GENESIS = 1727521075;
    uint256 internal constant PERIOD = 3;
    uint256 internal constant ROUND = 19_732_510;
    uint256 internal constant ROUND_TIME = 1_786_718_602;

    // public key words, library layout [x.c0, x.c1, y.c0, y.c1].
    // drand's API hex is x.c1||x.c0||y.c1||y.c0 (kyber marshaling) — the API order
    // itself is NOT a valid G2 point in the precompile layout, which the negative
    // test below proves.
    uint256 internal constant PK_W0 = 0x0557ec32c2ad488e4d4f6008f89a346f18492092ccc0d594610de2732c8b808f;
    uint256 internal constant PK_W1 = 0x07e1d1d335df83fa98462005690372c643340060d205306a9aa8106b6bd0b382;
    uint256 internal constant PK_W2 = 0x297d3a4f9749b33eb2d904c9d9ebf17224150ddd7abd7567a9bec6c74480ee0b;
    uint256 internal constant PK_W3 = 0x0095685ae3a85ba243747b1b2f426049010f6b73a0cf1d389351d5aaaa1047f6;

    // real signature for ROUND, big-endian split of the 64-byte API hex
    uint256 internal constant SIG_X = 0x180a58cd3c3299b4eac3c7730cba7d00e084edba93da88d4513f4bdabb209e92;
    uint256 internal constant SIG_Y = 0x183a6779d3ce0f92744930f77ef5407fab5f0dd80a395c7f1da23856f23ecbd2;

    function test_realRoundVerifies_naturalOrder() public {
        DrandBeacon beacon = new DrandBeacon([PK_W0, PK_W1, PK_W2, PK_W3], GENESIS, PERIOD);
        // must not revert
        beacon.verifyBeaconRound(ROUND, [SIG_X, SIG_Y]);
    }

    function test_realRoundRejects_wrongRound() public {
        DrandBeacon beacon = new DrandBeacon([PK_W0, PK_W1, PK_W2, PK_W3], GENESIS, PERIOD);
        // same real signature, different round -> must fail verification
        vm.expectRevert(DrandBeacon.InvalidSignature.selector);
        beacon.verifyBeaconRound(ROUND + 1, [SIG_X, SIG_Y]);
    }

    function test_realRoundRejects_mangledSignature() public {
        DrandBeacon beacon = new DrandBeacon([PK_W0, PK_W1, PK_W2, PK_W3], GENESIS, PERIOD);
        vm.expectRevert(DrandBeacon.InvalidSignature.selector);
        beacon.verifyBeaconRound(ROUND, [SIG_X ^ 1, SIG_Y]);
    }

    function test_genesisAndPeriodExposed() public {
        DrandBeacon beacon = new DrandBeacon([PK_W0, PK_W1, PK_W2, PK_W3], GENESIS, PERIOD);
        assertEq(beacon.genesisTimestamp(), GENESIS);
        assertEq(beacon.period(), PERIOD);
        assertEq(beacon.publicKeyHash(), bytes32(uint256(keccak256(abi.encodePacked(PK_W0, PK_W1, PK_W2, PK_W3)))));
    }

    function test_apiHexOrderIsNotAValidKey() public {
        // The raw drand API byte order (x.c1||x.c0||y.c1||y.c0) is a different —
        // invalid — G2 point in the library's layout. Guards the reorder we do.
        vm.expectRevert(DrandBeacon.InvalidPublicKey.selector);
        new DrandBeacon([PK_W1, PK_W0, PK_W3, PK_W2], GENESIS, PERIOD);
    }
}
