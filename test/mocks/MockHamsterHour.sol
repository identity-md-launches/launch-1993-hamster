// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHamsterHour} from "../../src/interfaces/IHamsterHour.sol";

/// @dev Test-only state provider. This is not an oracle or a production betting game.
contract MockHamsterHour is IHamsterHour {
    address public override IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint256 public override currentWindow;
    uint64 public genesis;
    bool public readsRevert;
    mapping(uint256 => Window) private windows;
    mapping(uint256 => mapping(address => Position)) private positions;

    constructor(uint64 genesis_) {
        genesis = genesis_;
    }

    function setIMD(address imd_) external {
        IMD = imd_;
    }

    function setCurrentWindow(uint256 windowId) external {
        currentWindow = windowId;
    }

    function setReadsRevert(bool value) external {
        readsRevert = value;
    }

    function windowTimes(uint256 windowId) external view returns (uint64 startsAt, uint64 endsAt) {
        startsAt = genesis + uint64(windowId * 1 hours);
        endsAt = startsAt + 1 hours;
    }

    function window(uint256 windowId) external view returns (Window memory) {
        require(!readsRevert, "game unavailable");
        return windows[windowId];
    }

    function position(uint256 windowId, address account) external view returns (Position memory) {
        require(!readsRevert, "game unavailable");
        return positions[windowId][account];
    }

    function setWindow(uint256 windowId, Window calldata value) external {
        windows[windowId] = value;
    }

    function setPosition(uint256 windowId, address account, Position calldata value) external {
        positions[windowId][account] = value;
    }
}
