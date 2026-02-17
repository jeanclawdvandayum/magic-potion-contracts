// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVRFCoordinatorV2Plus} from "../../src/interfaces/chainlink/IVRFCoordinatorV2Plus.sol";
import {DrawingManager} from "../../src/DrawingManager.sol";

/// @title MockVRFCoordinator — Minimal mock for testing Chainlink VRF V2.5
/// @notice Stores requests and allows manual fulfillment in tests
contract MockVRFCoordinator is IVRFCoordinatorV2Plus {
    uint256 private _nextRequestId = 1;

    struct Request {
        address consumer;
        bool fulfilled;
    }

    mapping(uint256 => Request) public requests;

    function requestRandomWords(
        RandomWordsRequest calldata /* req */
    ) external override returns (uint256 requestId) {
        requestId = _nextRequestId++;
        requests[requestId] = Request({
            consumer: msg.sender,
            fulfilled: false
        });
    }

    /// @notice Manually fulfill a request with specific random words (for testing)
    function fulfillRandomWordsWithOverride(
        uint256 requestId,
        uint256[] calldata randomWords
    ) external {
        Request storage req = requests[requestId];
        require(req.consumer != address(0), "Request not found");
        require(!req.fulfilled, "Already fulfilled");
        req.fulfilled = true;

        DrawingManager(req.consumer).rawFulfillRandomWords(requestId, randomWords);
    }
}
