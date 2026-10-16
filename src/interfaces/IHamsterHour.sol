// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Read interface for the existing Hamster Hour game linked in the brief.
/// @dev Tuple order/types match docs/reference/HamsterHour.reads.abi.json. Do not reorder fields.
interface IHamsterHour {
    struct Position {
        uint256[2] over;
        uint256[2] sleep;
        uint256 exactAmount;
        uint256 guess;
        bool imdClaimed;
        bool jackpotClaimed;
    }

    struct Window {
        uint8 status;
        uint64 startsAt;
        uint64 endsAt;
        uint256 line;
        string source;
        uint256 result;
        uint256[3] pools;
        uint256[2] over;
        uint256[2] sleep;
        uint256[3] rewards;
        bool[3] marketVoided;
        uint256[3] paid;
        uint256[3] claimedWeight;
        uint256[3] distances;
        uint256[3] ties;
        uint256[3] rankRewards;
        uint256[3] rankClaimed;
        uint256[3] rankPaid;
        uint8 rankCount;
        address settler;
        uint256 teamCredit;
        uint256 reimbursement;
        bool reimbursed;
        address jackpotAsset;
        uint256 jackpot;
        uint256 jackpotPaid;
        uint256 jackpotClaimed;
        bytes32 requestId;
    }

    function IMD() external view returns (address);
    function currentWindow() external view returns (uint256);
    function windowTimes(uint256 windowId) external view returns (uint64 startsAt, uint64 endsAt);
    function window(uint256 windowId) external view returns (Window memory);
    function position(uint256 windowId, address account) external view returns (Position memory);
}
