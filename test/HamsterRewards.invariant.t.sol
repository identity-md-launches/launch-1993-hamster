// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {HamsterToken} from "../src/HamsterToken.sol";
import {HamsterRewards} from "../src/HamsterRewards.sol";
import {IHamsterHour} from "../src/interfaces/IHamsterHour.sol";
import {MockHamsterHour} from "./mocks/MockHamsterHour.sol";

contract RewardsHandler is Test {
    HamsterToken public immutable token;
    HamsterRewards public immutable rewards;
    address[4] public bettors;
    uint256 public funded;
    uint256 public paid;
    uint256 public successfulClaims;
    uint256 public failedClaims;
    uint256 public constant ENDOWMENT = 1_000_000 ether;
    mapping(uint256 => mapping(address => bool)) public paidOnce;

    constructor(HamsterToken token_, HamsterRewards rewards_, address[4] memory bettors_) {
        token = token_;
        rewards = rewards_;
        bettors = bettors_;
    }

    function fund(uint256 rawAmount, bool direct) external {
        uint256 available = token.balanceOf(address(this));
        if (available == 0) return;
        uint256 amount = bound(rawAmount, 1, available);
        if (direct) {
            token.transfer(address(rewards), amount);
        } else {
            token.approve(address(rewards), amount);
            rewards.fund(amount);
        }
        funded += amount;
    }

    function claim(uint256 rawWindow, uint256 rawBettor, bool self) external {
        uint256 windowId = bound(rawWindow, 1, 8);
        address bettor = bettors[rawBettor % bettors.length];
        uint256 amount = 1 ether * windowId;
        bool duplicate = paidOnce[windowId][bettor];
        bool enough = token.balanceOf(address(rewards)) >= amount;
        bytes memory callData =
            self ? abi.encodeCall(rewards.claim, (windowId)) : abi.encodeCall(rewards.claimFor, (windowId, bettor));
        if (self) vm.prank(bettor);
        (bool ok, bytes memory result) = address(rewards).call(callData);
        if (duplicate) {
            assertFalse(ok, "duplicate reward succeeded");
            assertEq(result, abi.encodeWithSelector(HamsterRewards.AlreadyClaimed.selector));
            ++failedClaims;
        } else if (!enough) {
            assertFalse(ok, "unfunded reward succeeded");
            assertEq(
                result,
                abi.encodeWithSelector(
                    HamsterRewards.InsufficientRewards.selector, token.balanceOf(address(rewards)), amount
                )
            );
            ++failedClaims;
        } else {
            assertTrue(ok, "funded reward failed");
            assertEq(abi.decode(result, (uint256)), amount);
            paidOnce[windowId][bettor] = true;
            paid += amount;
            ++successfulClaims;
        }
    }
}

contract HamsterRewardsInvariantTest is StdInvariant, Test {
    HamsterToken private token;
    HamsterRewards private rewards;
    RewardsHandler private handler;
    address[4] private bettors;

    function setUp() public {
        vm.warp(1 hours);
        token = new HamsterToken();
        rewards = new HamsterRewards(address(token), address(this));
        MockHamsterHour game = new MockHamsterHour(uint64(block.timestamp));
        rewards.configureGame(address(game), 1);
        for (uint256 a; a < bettors.length; ++a) {
            bettors[a] = makeAddr(string.concat("bettor ", vm.toString(a)));
        }
        for (uint256 id = 1; id <= 8; ++id) {
            IHamsterHour.Window memory w;
            w.status = 2;
            w.endsAt = 10 hours;
            w.line = 100;
            w.result = 200;
            w.over = [uint256(100 ether), 100 ether];
            w.pools[0] = 200 ether;
            game.setWindow(id, w);
            IHamsterHour.Position memory p;
            p.over[0] = 1 ether * id;
            for (uint256 a; a < bettors.length; ++a) {
                game.setPosition(id, bettors[a], p);
            }
        }
        vm.warp(11 hours);
        handler = new RewardsHandler(token, rewards, bettors);
        token.transfer(address(handler), handler.ENDOWMENT());
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = RewardsHandler.fund.selector;
        selectors[1] = RewardsHandler.claim.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_FixedSupplyAndReserveConservation() public view {
        uint256 bettorBalances;
        for (uint256 a; a < bettors.length; ++a) {
            bettorBalances += token.balanceOf(bettors[a]);
        }
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(rewards)) + handler.paid(), handler.funded());
        assertEq(rewards.totalPaid(), handler.paid());
        assertEq(bettorBalances, handler.paid());
        assertEq(token.balanceOf(address(handler)) + handler.funded(), handler.ENDOWMENT());
        assertEq(
            token.balanceOf(address(this)) + token.balanceOf(address(handler)) + token.balanceOf(address(rewards))
                + bettorBalances,
            token.totalSupply()
        );
    }

    function invariant_EachWalletWindowPaysAtMostOnce() public view {
        uint256 expectedPaid;
        uint256 claims;
        for (uint256 id = 1; id <= 8; ++id) {
            for (uint256 a; a < bettors.length; ++a) {
                bool paid = handler.paidOnce(id, bettors[a]);
                assertEq(rewards.claimed(id, bettors[a]), paid);
                if (paid) {
                    expectedPaid += id * 1 ether;
                    ++claims;
                    assertEq(rewards.rewardFor(id, bettors[a]), 0);
                }
            }
        }
        assertEq(expectedPaid, handler.paid());
        assertEq(claims, handler.successfulClaims());
        assertLe(handler.paid(), 144 ether);
    }
}
