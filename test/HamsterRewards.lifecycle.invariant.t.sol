// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {HamsterToken} from "../src/HamsterToken.sol";
import {HamsterRewards} from "../src/HamsterRewards.sol";
import {IHamsterHour} from "../src/interfaces/IHamsterHour.sol";
import {MockHamsterHour} from "./mocks/MockHamsterHour.sol";

/// @dev Drives the reward contract through a whole game lifecycle rather than against frozen records:
///      windows open, settle with different results and refund flags, or get voided; time passes so
///      the end-of-window guard is exercised; several donors fund; ownership moves around. Stakes are
///      fixed per bettor and window at construction, as the real game keeps them after settlement.
///      Every claim's outcome is predicted from the README's eligibility table (an independent model)
///      before the call, so an unexpected success, failure, or amount fails the run at that call.
contract LifecycleHandler is Test {
    uint256 public constant FIRST_WINDOW = 1;
    uint256 public constant LAST_WINDOW = 6;
    uint256 public constant LINE = 100;

    HamsterToken public immutable token;
    HamsterRewards public immutable rewards;
    MockHamsterHour public immutable game;
    address[3] public bettors;
    address[2] public donors;
    address[3] public owners;

    uint256 public funded;
    uint256 public paid;
    uint256 public successfulClaims;
    uint256 public rejectedClaims;
    uint256 public settled;
    uint256 public voided;
    uint256 public ownershipMoves;
    mapping(uint256 => mapping(address => uint256)) public paidTo;
    mapping(uint256 => mapping(address => bool)) public paidOnce;
    mapping(uint256 => mapping(address => uint256)) public wagered;
    mapping(uint256 => bool) public settledAt;

    constructor(
        HamsterToken token_,
        HamsterRewards rewards_,
        MockHamsterHour game_,
        address[3] memory bettors_,
        address[2] memory donors_,
        address[3] memory owners_
    ) {
        token = token_;
        rewards = rewards_;
        game = game_;
        bettors = bettors_;
        donors = donors_;
        owners = owners_;
        for (uint256 id = FIRST_WINDOW; id <= LAST_WINDOW; ++id) {
            for (uint256 b; b < bettors.length; ++b) {
                IHamsterHour.Position memory p = _stake(id, b);
                game.setPosition(id, bettors[b], p);
                wagered[id][bettors[b]] = p.over[0] + p.over[1] + p.sleep[0] + p.sleep[1] + p.exactAmount;
            }
        }
    }

    /// @dev Deterministic, varied stakes: some sides empty, some exact guesses on and off the result.
    function _stake(uint256 id, uint256 b) private pure returns (IHamsterHour.Position memory p) {
        uint256 h = uint256(keccak256(abi.encode("stake", id, b)));
        p.over[0] = (h % 3 == 0) ? 0 : ((h >> 8) % 10) * 1 ether;
        p.over[1] = ((h >> 16) % 4 == 0) ? 0 : ((h >> 24) % 10) * 1 ether;
        p.sleep[0] = ((h >> 32) % 3 == 0) ? 0 : ((h >> 40) % 10) * 1 ether;
        p.sleep[1] = ((h >> 48) % 4 == 0) ? 0 : ((h >> 56) % 10) * 1 ether;
        p.exactAmount = ((h >> 64) % 2 == 0) ? 0 : ((h >> 72) % 10) * 1 ether + 1;
        p.guess = LINE + ((h >> 80) % 7) - 3;
    }

    function warp(uint256 rawDelta) external {
        vm.warp(block.timestamp + bound(rawDelta, 0, 90 minutes));
    }

    function fund(uint256 donorSeed, uint256 rawAmount, bool direct) external {
        address donor = donors[donorSeed % donors.length];
        uint256 available = token.balanceOf(donor);
        if (available == 0) return;
        uint256 amount = bound(rawAmount, 1, available);
        vm.startPrank(donor);
        if (direct) {
            token.transfer(address(rewards), amount);
        } else {
            token.approve(address(rewards), amount);
            rewards.fund(amount);
        }
        vm.stopPrank();
        funded += amount;
    }

    /// @dev Settle an open window with one of a few results and an arbitrary set of refund flags.
    function settle(uint256 rawWindow, uint256 resultSeed, uint8 voidBits) external {
        uint256 id = bound(rawWindow, FIRST_WINDOW, LAST_WINDOW);
        IHamsterHour.Window memory w = game.window(id);
        if (w.status != 0) return;
        uint256[5] memory results = [uint256(0), 50, LINE, LINE + 1, 150];
        w.status = 2;
        w.startsAt = uint64(game.genesis() + id * 1 hours);
        w.endsAt = w.startsAt + 1 hours;
        w.line = LINE;
        w.result = results[resultSeed % results.length];
        w.marketVoided = [voidBits & 1 != 0, voidBits & 2 != 0, voidBits & 4 != 0];
        for (uint256 b; b < bettors.length; ++b) {
            IHamsterHour.Position memory p = game.position(id, bettors[b]);
            w.over[0] += p.over[0];
            w.over[1] += p.over[1];
            w.sleep[0] += p.sleep[0];
            w.sleep[1] += p.sleep[1];
        }
        (w.distances, w.ties, w.rankCount) = _rank(id, w.result);
        game.setWindow(id, w);
        settledAt[id] = true;
        ++settled;
    }

    function voidWindow(uint256 rawWindow) external {
        uint256 id = bound(rawWindow, FIRST_WINDOW, LAST_WINDOW);
        IHamsterHour.Window memory w = game.window(id);
        if (w.status != 0) return;
        w.status = 3;
        w.endsAt = uint64(block.timestamp + 10 hours); // voided early; must still pay nothing
        game.setWindow(id, w);
        ++voided;
    }

    /// @dev Nearest distinct distances among the exact bettors, at most three, with their tie counts.
    function _rank(uint256 id, uint256 result)
        private
        view
        returns (uint256[3] memory distances, uint256[3] memory ties, uint8 rankCount)
    {
        uint256[3] memory ds;
        uint256 n;
        for (uint256 b; b < bettors.length; ++b) {
            IHamsterHour.Position memory p = game.position(id, bettors[b]);
            if (p.exactAmount == 0) continue;
            ds[n++] = p.guess > result ? p.guess - result : result - p.guess;
        }
        for (uint256 i; i < n; ++i) {
            for (uint256 j = i + 1; j < n; ++j) {
                if (ds[j] < ds[i]) (ds[i], ds[j]) = (ds[j], ds[i]);
            }
        }
        for (uint256 i; i < n; ++i) {
            if (rankCount > 0 && distances[rankCount - 1] == ds[i]) {
                ++ties[rankCount - 1];
            } else {
                distances[rankCount] = ds[i];
                ties[rankCount] = 1;
                ++rankCount;
            }
        }
    }

    /// @dev The README's eligibility table, written as a model independent of the contract's code.
    function expectedLoss(uint256 id, address bettor) public view returns (uint256 loss) {
        IHamsterHour.Window memory w = game.window(id);
        IHamsterHour.Position memory p = game.position(id, bettor);
        if (w.status == 3) return 0;
        bool contested = w.over[0] > 0 && w.over[1] > 0;
        if (!w.marketVoided[0] && contested && w.result != w.line) {
            loss += w.result > w.line ? p.over[0] : p.over[1];
        }
        bool sleepContested = w.sleep[0] > 0 && w.sleep[1] > 0;
        if (!w.marketVoided[2] && sleepContested) {
            loss += w.result == 0 ? p.sleep[0] : p.sleep[1];
        }
        if (!w.marketVoided[1] && p.exactAmount > 0) {
            uint256 d = p.guess > w.result ? p.guess - w.result : w.result - p.guess;
            bool winner;
            for (uint256 i; i < w.rankCount; ++i) {
                if (w.distances[i] == d) winner = true;
            }
            if (!winner) loss += p.exactAmount;
        }
    }

    function claim(uint256 rawWindow, uint256 bettorSeed, bool viaRelayer) external {
        // Window 0 is below the first eligible one; LAST_WINDOW + 1 has no record at all.
        uint256 id = bound(rawWindow, 0, LAST_WINDOW + 1);
        address bettor = bettors[bettorSeed % bettors.length];
        IHamsterHour.Window memory w = game.window(id);
        bytes memory expected;
        uint256 reward;
        if (paidOnce[id][bettor]) {
            expected = abi.encodeWithSelector(HamsterRewards.AlreadyClaimed.selector);
        } else if (id < FIRST_WINDOW) {
            expected = abi.encodeWithSelector(HamsterRewards.WindowNotEligible.selector);
        } else if (w.status == 3) {
            expected = abi.encodeWithSelector(HamsterRewards.NothingToClaim.selector);
        } else if (w.status != 2 || block.timestamp < w.endsAt) {
            expected = abi.encodeWithSelector(HamsterRewards.WindowNotSettled.selector);
        } else {
            reward = expectedLoss(id, bettor);
            uint256 inventory = token.balanceOf(address(rewards));
            if (reward == 0) {
                expected = abi.encodeWithSelector(HamsterRewards.NothingToClaim.selector);
            } else if (inventory < reward) {
                expected = abi.encodeWithSelector(HamsterRewards.InsufficientRewards.selector, inventory, reward);
            }
        }

        uint256 bettorBefore = token.balanceOf(bettor);
        bytes memory callData =
            viaRelayer ? abi.encodeCall(rewards.claimFor, (id, bettor)) : abi.encodeCall(rewards.claim, (id));
        if (!viaRelayer) vm.prank(bettor);
        (bool ok, bytes memory result) = address(rewards).call(callData);
        if (expected.length != 0) {
            assertFalse(ok, "claim should have failed");
            assertEq(result, expected, "wrong failure reason");
            assertEq(token.balanceOf(bettor), bettorBefore, "failed claim moved tokens");
            ++rejectedClaims;
            return;
        }
        assertTrue(ok, "eligible claim failed");
        assertEq(abi.decode(result, (uint256)), reward, "claim returned a different amount");
        assertEq(token.balanceOf(bettor) - bettorBefore, reward, "bettor received a different amount");
        paidOnce[id][bettor] = true;
        paidTo[id][bettor] = reward;
        paid += reward;
        ++successfulClaims;
    }

    /// @dev Ownership shuffles never touch rewards: transfer, accept, or renounce once configured.
    function ownership(uint256 action, uint256 targetSeed) external {
        address current = rewards.owner();
        address target = owners[targetSeed % owners.length];
        if (current == address(0)) return;
        vm.startPrank(current);
        if (action % 11 == 0) {
            rewards.renounceOwnership();
        } else if (action % 2 == 0) {
            rewards.transferOwnership(target);
        } else {
            address pending = rewards.pendingOwner();
            vm.stopPrank();
            if (pending == address(0)) return;
            vm.startPrank(pending);
            rewards.acceptOwnership();
        }
        vm.stopPrank();
        ++ownershipMoves;
    }

    /// @dev Whoever owns the contract now, reconfiguration is refused.
    function reconfigure(uint256 rawWindow) external {
        address current = rewards.owner();
        if (current == address(0)) {
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
            rewards.configureGame(address(game), rawWindow);
            return;
        }
        vm.prank(current);
        vm.expectRevert(HamsterRewards.AlreadyConfigured.selector);
        rewards.configureGame(address(game), rawWindow);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
contract HamsterRewardsLifecycleInvariantTest is StdInvariant, Test {
    uint256 private constant SUPPLY = 1_000_000_000 ether;
    uint256 private constant DONOR_ENDOWMENT = 300 ether;
    HamsterToken private token;
    HamsterRewards private rewards;
    MockHamsterHour private game;
    LifecycleHandler private handler;
    address[3] private bettors;
    address[2] private donors;
    address[3] private owners;

    function setUp() public {
        vm.warp(1 hours);
        token = new HamsterToken();
        game = new MockHamsterHour(uint64(block.timestamp));
        for (uint256 i; i < bettors.length; ++i) {
            bettors[i] = makeAddr(string.concat("bettor ", vm.toString(i)));
            owners[i] = makeAddr(string.concat("owner ", vm.toString(i)));
        }
        for (uint256 i; i < donors.length; ++i) {
            donors[i] = makeAddr(string.concat("donor ", vm.toString(i)));
            token.transfer(donors[i], DONOR_ENDOWMENT);
        }
        rewards = new HamsterRewards(address(token), owners[0]);
        vm.prank(owners[0]);
        rewards.configureGame(address(game), 1);
        handler = new LifecycleHandler(token, rewards, game, bettors, donors, owners);
        assertEq(handler.FIRST_WINDOW(), 1);
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = LifecycleHandler.warp.selector;
        selectors[1] = LifecycleHandler.fund.selector;
        selectors[2] = LifecycleHandler.settle.selector;
        selectors[3] = LifecycleHandler.voidWindow.selector;
        selectors[4] = LifecycleHandler.claim.selector;
        selectors[5] = LifecycleHandler.ownership.selector;
        selectors[6] = LifecycleHandler.reconfigure.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_InventoryEqualsDonationsMinusPayouts() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(rewards.totalPaid(), handler.paid());
        assertEq(token.balanceOf(address(rewards)) + rewards.totalPaid(), handler.funded());
        uint256 donorHeld;
        for (uint256 i; i < donors.length; ++i) {
            donorHeld += token.balanceOf(donors[i]);
        }
        assertEq(donorHeld + handler.funded(), donors.length * DONOR_ENDOWMENT);
        uint256 bettorHeld;
        for (uint256 i; i < bettors.length; ++i) {
            bettorHeld += token.balanceOf(bettors[i]);
        }
        assertEq(bettorHeld, rewards.totalPaid());
        for (uint256 i; i < owners.length; ++i) {
            assertEq(token.balanceOf(owners[i]), 0, "an owner received tokens");
        }
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(game)), 0);
    }

    function invariant_NobodyIsPaidMoreThanTheyWageredOrTwice() public view {
        uint256 total;
        for (uint256 id = handler.FIRST_WINDOW(); id <= handler.LAST_WINDOW(); ++id) {
            IHamsterHour.Window memory w = game.window(id);
            for (uint256 b; b < bettors.length; ++b) {
                address bettor = bettors[b];
                bool flagged = rewards.claimed(id, bettor);
                assertEq(flagged, handler.paidOnce(id, bettor), "claimed flag disagrees with ledger");
                uint256 amount = handler.paidTo(id, bettor);
                total += amount;
                assertLe(amount, handler.wagered(id, bettor), "paid more than the wager");
                if (flagged) {
                    assertGt(amount, 0, "a claim was consumed for nothing");
                    assertEq(w.status, 2, "paid on a window that is not settled");
                    assertGe(block.timestamp, w.endsAt, "paid before the window ended");
                    assertEq(amount, handler.expectedLoss(id, bettor), "payout differs from the eligibility model");
                    assertEq(rewards.rewardFor(id, bettor), 0, "quote not zero after payment");
                } else if (w.status == 2 && block.timestamp >= w.endsAt) {
                    assertEq(
                        rewards.rewardFor(id, bettor), handler.expectedLoss(id, bettor), "quote differs from model"
                    );
                    assertEq(rewards.eligibleLoss(id, bettor), handler.expectedLoss(id, bettor));
                } else if (w.status == 3) {
                    assertEq(rewards.rewardFor(id, bettor), 0, "voided window quotes a reward");
                }
            }
        }
        assertEq(total, rewards.totalPaid());
        assertEq(rewards.claimed(0, bettors[0]), false);
    }

    function invariant_ConfigurationIsPermanentAndOwnerPowerless() public view {
        assertEq(address(rewards.game()), address(game));
        assertEq(rewards.firstEligibleWindow(), handler.FIRST_WINDOW());
        assertEq(address(rewards.hamster()), address(token));
        assertEq(rewards.REWARD_PER_IMD(), 1);
        address current = rewards.owner();
        bool known = current == address(0);
        for (uint256 i; i < owners.length; ++i) {
            if (current == owners[i]) known = true;
        }
        assertTrue(known, "ownership left the known set");
    }

    function invariant_GameRecordsStayFinal() public view {
        for (uint256 id = handler.FIRST_WINDOW(); id <= handler.LAST_WINDOW(); ++id) {
            IHamsterHour.Window memory w = game.window(id);
            if (handler.settledAt(id)) assertEq(w.status, 2, "a settled window changed status");
            assertLe(w.rankCount, 3);
            for (uint256 i; i < w.rankCount; ++i) {
                assertGt(w.ties[i], 0, "model produced an empty rank");
            }
        }
    }
}
