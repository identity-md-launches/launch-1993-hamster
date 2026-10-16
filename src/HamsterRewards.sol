// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IHamsterHour} from "./interfaces/IHamsterHour.sol";

/// @notice Pays existing HAMSTER for losing stakes in the configured Hamster Hour game.
/// @dev No minting, wagering, randomness, or custody of IMD. Configuration is one-time and claims
///      depend on the game's finalized, persistent position records. Funding is an irrevocable donation.
contract HamsterRewards is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    // Both assets have 18 decimals: one HAMSTER base unit per lost IMD base unit.
    uint256 public constant REWARD_PER_IMD = 1;
    uint8 private constant SETTLED = 2;
    uint8 private constant VOIDED = 3;

    IERC20 public immutable hamster;
    IHamsterHour public game;
    uint256 public firstEligibleWindow;
    uint256 public totalPaid;
    mapping(uint256 windowId => mapping(address account => bool)) public claimed;

    error InvalidAddress();
    error NotConfigured();
    error AlreadyConfigured();
    error InvalidGame();
    error InvalidFirstWindow();
    error WindowNotEligible();
    error WindowNotSettled();
    error InvalidGameState();
    error ZeroAmount();
    error AlreadyClaimed();
    error NothingToClaim();
    error InsufficientRewards(uint256 available, uint256 required);
    error UnexpectedReceivedAmount();

    event GameConfigured(address indexed game, uint256 indexed firstEligibleWindow);
    event Funded(address indexed donor, uint256 amount);
    event RewardClaimed(address indexed account, uint256 indexed windowId, uint256 lostIMD, uint256 reward);

    /// @param hamster_ The token deployed in this launch, supplied as $token by the launch process.
    /// @param owner_ The requester's launch owner, never the factory or tx.origin.
    /// @dev No external calls or code checks: the launch constructs contracts on an empty chain too.
    constructor(address hamster_, address owner_) Ownable(owner_) {
        if (hamster_ == address(0) || hamster_ == address(this)) revert InvalidAddress();
        hamster = IERC20(hamster_);
    }

    /// @notice Permanently select the existing game and a future first eligible window.
    /// @dev Validate the reviewed game address before calling. Interface checks cannot prove honesty.
    function configureGame(address game_, uint256 firstWindow_) external onlyOwner {
        if (address(game) != address(0)) revert AlreadyConfigured();
        if (game_.code.length == 0 || game_ == address(this) || game_ == address(hamster)) revert InvalidGame();
        IHamsterHour candidate = IHamsterHour(game_);
        if (candidate.IMD() != IMD) revert InvalidGame();
        if (firstWindow_ <= candidate.currentWindow()) revert InvalidFirstWindow();
        (uint64 startsAt, uint64 endsAt) = candidate.windowTimes(firstWindow_);
        if (startsAt <= block.timestamp || endsAt <= startsAt) revert InvalidFirstWindow();
        game = candidate;
        firstEligibleWindow = firstWindow_;
        emit GameConfigured(game_, firstWindow_);
    }

    /// @notice Donate HAMSTER from an exact allowance. There is no administrative withdrawal.
    function fund(uint256 amount) external nonReentrant {
        _requireConfigured();
        if (amount == 0) revert ZeroAmount();
        uint256 beforeBalance = hamster.balanceOf(address(this));
        hamster.safeTransferFrom(msg.sender, address(this), amount);
        if (hamster.balanceOf(address(this)) != beforeBalance + amount) revert UnexpectedReceivedAmount();
        emit Funded(msg.sender, amount);
    }

    /// @notice Unclaimed reward entitlement; may exceed current inventory. Pending windows revert.
    function rewardFor(uint256 windowId, address account) external view returns (uint256) {
        _requireConfigured();
        if (claimed[windowId][account]) return 0;
        return eligibleLoss(windowId, account) * REWARD_PER_IMD;
    }

    /// @notice Losing stakes, irrespective of whether the separate game's IMD/jackpot was claimed.
    /// @dev Winning tickets and refunds earn zero. A wallet can have winners and losers in one window;
    ///      only losing stakes count. Exact winners are the nearest three distinct distance ranks.
    function eligibleLoss(uint256 windowId, address account) public view returns (uint256 loss) {
        _requireConfigured();
        if (windowId < firstEligibleWindow) revert WindowNotEligible();
        IHamsterHour.Window memory w = game.window(windowId);
        if (w.status == VOIDED) return 0;
        if (w.status != SETTLED || block.timestamp < w.endsAt) revert WindowNotSettled();
        if (w.rankCount > 3) revert InvalidGameState();
        IHamsterHour.Position memory p = game.position(windowId, account);

        if (!w.marketVoided[0] && w.result != w.line && w.over[0] != 0 && w.over[1] != 0) {
            // over[0] = UNDER, over[1] = OVER.
            loss += p.over[w.result > w.line ? 0 : 1];
        }
        if (!w.marketVoided[2] && w.sleep[0] != 0 && w.sleep[1] != 0) {
            // sleep[0] = RUNNING, sleep[1] = SLEEPING.
            loss += p.sleep[w.result == 0 ? 0 : 1];
        }
        if (!w.marketVoided[1] && p.exactAmount != 0) {
            if (w.rankCount == 0) revert InvalidGameState();
            uint256 distance = p.guess > w.result ? p.guess - w.result : w.result - p.guess;
            bool ranked = false;
            for (uint256 i; i < w.rankCount; ++i) {
                if (w.ties[i] == 0) revert InvalidGameState();
                if (w.distances[i] == distance) ranked = true;
            }
            if (!ranked) loss += p.exactAmount;
        }
    }

    function claim(uint256 windowId) external nonReentrant returns (uint256 reward) {
        return _claim(windowId, msg.sender);
    }

    /// @notice Anyone may pay gas to claim for a bettor; tokens always go to that bettor.
    function claimFor(uint256 windowId, address account) external nonReentrant returns (uint256 reward) {
        if (account == address(0)) revert InvalidAddress();
        return _claim(windowId, account);
    }

    /// @notice Prevent accidentally abandoning setup. Once configured, the owner has no reward powers.
    function renounceOwnership() public override onlyOwner {
        _requireConfigured();
        super.renounceOwnership();
    }

    function _claim(uint256 windowId, address account) private returns (uint256 reward) {
        _requireConfigured();
        if (claimed[windowId][account]) revert AlreadyClaimed();
        uint256 loss = eligibleLoss(windowId, account);
        reward = loss * REWARD_PER_IMD;
        if (reward == 0) revert NothingToClaim();
        uint256 available = hamster.balanceOf(address(this));
        if (available < reward) revert InsufficientRewards(available, reward);

        claimed[windowId][account] = true;
        totalPaid += reward;
        hamster.safeTransfer(account, reward);
        emit RewardClaimed(account, windowId, loss, reward);
    }

    function _requireConfigured() private view {
        if (address(game) == address(0)) revert NotConfigured();
    }
}
