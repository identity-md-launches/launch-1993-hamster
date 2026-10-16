// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm, stdError} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {HamsterToken} from "../src/HamsterToken.sol";
import {HamsterRewards} from "../src/HamsterRewards.sol";
import {IHamsterHour} from "../src/interfaces/IHamsterHour.sol";
import {MockHamsterHour} from "./mocks/MockHamsterHour.sol";

/// @dev Has code and the right IMD, but no window schedule: configuration must fail closed.
contract HalfGame {
    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;

    function currentWindow() external pure returns (uint256) {
        return 0;
    }
}

/// @notice Inputs the first suite did not try: boundaries of the rank data, partial refunds, overflowing
///         stakes, windows below the first eligible one that are also voided, contracts that half-implement
///         the game, ownership after configuration, and funding from wallets that cannot pay.
contract HamsterRewardsEdgeTest is Test {
    HamsterToken internal token;
    HamsterRewards internal rewards;
    MockHamsterHour internal game;
    address internal admin = makeAddr("launch owner");
    address internal alice = makeAddr("bettor");
    address internal relayer = makeAddr("relayer");

    event RewardClaimed(address indexed account, uint256 indexed windowId, uint256 lostIMD, uint256 reward);

    function setUp() public {
        vm.warp(1 hours);
        token = new HamsterToken();
        game = new MockHamsterHour(uint64(block.timestamp));
        rewards = new HamsterRewards(address(token), admin);
        vm.prank(admin);
        rewards.configureGame(address(game), 1);
        token.approve(address(rewards), 1_000 ether);
        rewards.fund(1_000 ether);
        vm.warp(4 hours);
        game.setWindow(1, _window());
    }

    function _window() internal pure returns (IHamsterHour.Window memory w) {
        w.status = 2;
        w.startsAt = 2 hours;
        w.endsAt = 3 hours;
        w.line = 100;
        w.result = 120;
        w.over = [uint256(100 ether), 100 ether];
        w.sleep = [uint256(100 ether), 100 ether];
        w.distances = [uint256(0), 1, 2];
        w.ties = [uint256(1), 1, 1];
        w.rankCount = 3;
    }

    function _position() internal pure returns (IHamsterHour.Position memory p) {
        p.over[0] = 10 ether; // UNDER, loses when result > line
        p.over[1] = 7 ether; // OVER, wins here
        p.sleep[0] = 3 ether; // RUNNING, loses only when the result is zero
        p.sleep[1] = 5 ether; // SLEEPING, loses here
        p.exactAmount = 20 ether;
        p.guess = 1_000; // far from any rank
    }

    // ---------------------------------------------------------------- eligibility boundaries

    function test_RewardQuoteRevertsForPendingWindowRatherThanQuotingZero() public {
        IHamsterHour.Window memory w = _window();
        w.status = 1;
        game.setWindow(2, w);
        game.setPosition(2, alice, _position());
        vm.expectRevert(HamsterRewards.WindowNotSettled.selector);
        rewards.rewardFor(2, alice);
        vm.expectRevert(HamsterRewards.WindowNotSettled.selector);
        rewards.eligibleLoss(2, alice);
        // An unknown window has the default status and is treated the same way.
        vm.expectRevert(HamsterRewards.WindowNotSettled.selector);
        rewards.rewardFor(99, alice);
    }

    function test_IneligibleWindowRejectedEvenWhenVoided() public {
        IHamsterHour.Window memory w = _window();
        w.status = 3;
        game.setWindow(0, w);
        game.setPosition(0, alice, _position());
        vm.expectRevert(HamsterRewards.WindowNotEligible.selector);
        rewards.rewardFor(0, alice);
        vm.expectRevert(HamsterRewards.WindowNotEligible.selector);
        rewards.claimFor(0, alice);
    }

    function test_VoidedWindowQuotesZeroEvenBeforeItsEnd() public {
        IHamsterHour.Window memory w = _window();
        w.status = 3;
        w.endsAt = uint64(block.timestamp + 1 days);
        game.setWindow(1, w);
        game.setPosition(1, alice, _position());
        assertEq(rewards.rewardFor(1, alice), 0);
        vm.expectRevert(HamsterRewards.NothingToClaim.selector);
        rewards.claimFor(1, alice);
        assertFalse(rewards.claimed(1, alice));
    }

    function test_UnknownStatusValuesAreNotSettled() public {
        game.setPosition(1, alice, _position());
        uint8[4] memory statuses = [4, 5, 128, 255];
        for (uint256 i; i < statuses.length; ++i) {
            IHamsterHour.Window memory w = _window();
            w.status = statuses[i];
            game.setWindow(1, w);
            vm.expectRevert(HamsterRewards.WindowNotSettled.selector);
            rewards.claimFor(1, alice);
        }
    }

    function test_BinaryOnlyWalletClaimsWhenExactMarketHadNoRanks() public {
        IHamsterHour.Window memory w = _window();
        w.rankCount = 0;
        w.distances = [uint256(0), 0, 0];
        w.ties = [uint256(0), 0, 0];
        game.setWindow(1, w);
        IHamsterHour.Position memory p = _position();
        p.exactAmount = 0;
        p.guess = 0;
        game.setPosition(1, alice, p);
        assertEq(rewards.eligibleLoss(1, alice), 15 ether);
        assertEq(rewards.claimFor(1, alice), 15 ether);
    }

    function test_VoidedExactMarketSkipsRankValidation() public {
        IHamsterHour.Window memory w = _window();
        w.rankCount = 0;
        w.ties = [uint256(0), 0, 0];
        w.marketVoided[1] = true;
        game.setWindow(1, w);
        game.setPosition(1, alice, _position());
        // No InvalidGameState: the exact stake is refunded by the game, so the ranks are irrelevant.
        assertEq(rewards.eligibleLoss(1, alice), 15 ether);
    }

    function test_EachMarketRefundFlagRemovesOnlyThatMarket() public {
        game.setPosition(1, alice, _position());
        IHamsterHour.Window memory w = _window();
        w.marketVoided = [true, false, false];
        game.setWindow(1, w);
        assertEq(rewards.eligibleLoss(1, alice), 25 ether, "over/under refund");
        w.marketVoided = [false, true, false];
        game.setWindow(1, w);
        assertEq(rewards.eligibleLoss(1, alice), 15 ether, "exact refund");
        w.marketVoided = [false, false, true];
        game.setWindow(1, w);
        assertEq(rewards.eligibleLoss(1, alice), 30 ether, "sleep refund");
    }

    function test_TiesBeyondRankCountAreIgnored() public {
        IHamsterHour.Window memory w = _window();
        w.rankCount = 1;
        w.ties = [uint256(2), 0, 0];
        w.distances = [uint256(5), 0, 0];
        game.setWindow(1, w);
        IHamsterHour.Position memory p = _position();
        p.guess = w.result; // distance 0 is not a winning rank here, only distance 5 is
        game.setPosition(1, alice, p);
        assertEq(rewards.eligibleLoss(1, alice), 35 ether);
        p.guess = w.result + 5;
        game.setPosition(1, alice, p);
        assertEq(rewards.eligibleLoss(1, alice), 15 ether);
    }

    function test_LastRankWithZeroTiesFailsClosed() public {
        IHamsterHour.Window memory w = _window();
        w.ties = [uint256(1), 1, 0];
        game.setWindow(1, w);
        game.setPosition(1, alice, _position());
        vm.expectRevert(HamsterRewards.InvalidGameState.selector);
        rewards.eligibleLoss(1, alice);
        // The same wallet without an exact ticket is unaffected by the malformed ranks.
        IHamsterHour.Position memory p = _position();
        p.exactAmount = 0;
        game.setPosition(1, alice, p);
        assertEq(rewards.eligibleLoss(1, alice), 15 ether);
    }

    function test_ZeroLineBoundaries() public {
        IHamsterHour.Window memory w = _window();
        w.line = 0;
        w.result = 0;
        game.setWindow(1, w);
        IHamsterHour.Position memory p = _position();
        p.exactAmount = 0;
        game.setPosition(1, alice, p);
        // Equal to the line refunds OVER/UNDER; result zero means SLEEPING wins, RUNNING loses.
        assertEq(rewards.eligibleLoss(1, alice), 3 ether);
        w.result = 1;
        game.setWindow(1, w);
        // Above a zero line: UNDER loses; nonzero result: SLEEPING loses.
        assertEq(rewards.eligibleLoss(1, alice), 15 ether);
    }

    function test_ExcessiveStakesFailClosedInsteadOfWrapping() public {
        IHamsterHour.Position memory p;
        p.over[0] = type(uint256).max;
        p.sleep[1] = 1;
        game.setPosition(1, alice, p);
        vm.expectRevert(stdError.arithmeticError);
        rewards.eligibleLoss(1, alice);
        vm.expectRevert(stdError.arithmeticError);
        rewards.claimFor(1, alice);
        assertFalse(rewards.claimed(1, alice));
    }

    function test_SingleMaximalStakeIsQuotedButNeverPayable() public {
        IHamsterHour.Position memory p;
        p.over[0] = type(uint256).max;
        game.setPosition(1, alice, p);
        assertEq(rewards.rewardFor(1, alice), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(HamsterRewards.InsufficientRewards.selector, 1_000 ether, type(uint256).max)
        );
        rewards.claimFor(1, alice);
    }

    function test_OneWeiLossPaysOneBaseUnit() public {
        IHamsterHour.Position memory p;
        p.over[0] = 1;
        game.setPosition(1, alice, p);
        vm.prank(alice);
        vm.expectEmit(true, true, false, true, address(rewards));
        emit RewardClaimed(alice, 1, 1, 1);
        assertEq(rewards.claim(1), 1);
        assertEq(token.balanceOf(alice), 1);
        assertEq(rewards.totalPaid(), 1);
    }

    function test_RelayerClaimingForItselfIsAnOrdinaryClaim() public {
        game.setPosition(1, relayer, _position());
        vm.prank(relayer);
        assertEq(rewards.claimFor(1, relayer), 35 ether);
        assertEq(token.balanceOf(relayer), 35 ether);
        vm.prank(relayer);
        vm.expectRevert(HamsterRewards.AlreadyClaimed.selector);
        rewards.claim(1);
    }

    function test_SameWalletDifferentWindowsAreIndependentEvenWhenOneIsVoided() public {
        game.setPosition(1, alice, _position());
        IHamsterHour.Window memory voided = _window();
        voided.status = 3;
        game.setWindow(2, voided);
        game.setPosition(2, alice, _position());
        assertEq(rewards.claimFor(1, alice), 35 ether);
        vm.expectRevert(HamsterRewards.NothingToClaim.selector);
        rewards.claimFor(2, alice);
        assertTrue(rewards.claimed(1, alice));
        assertFalse(rewards.claimed(2, alice));
    }

    function test_ClaimConsumesExactlyTheInventoryItNeeds() public {
        IHamsterHour.Position memory p;
        p.over[0] = 1_000 ether;
        game.setPosition(1, alice, p);
        game.setPosition(2, alice, p);
        game.setWindow(2, _window());
        assertEq(rewards.claimFor(1, alice), 1_000 ether);
        assertEq(token.balanceOf(address(rewards)), 0);
        vm.expectRevert(abi.encodeWithSelector(HamsterRewards.InsufficientRewards.selector, 0, 1_000 ether));
        rewards.claimFor(2, alice);
        assertEq(rewards.rewardFor(2, alice), 1_000 ether, "entitlement survives an empty reserve");
    }

    // ---------------------------------------------------------------- configuration and ownership

    function test_ContractWithoutTheGameInterfaceIsRejected() public {
        HamsterRewards fresh = new HamsterRewards(address(token), admin);
        HamsterToken other = new HamsterToken();
        vm.startPrank(admin);
        vm.expectRevert();
        fresh.configureGame(address(other), 10);
        HalfGame half = new HalfGame();
        vm.expectRevert();
        fresh.configureGame(address(half), 10);
        vm.stopPrank();
        assertEq(address(fresh.game()), address(0));
    }

    function test_FirstWindowSchedulingBoundaries() public {
        HamsterRewards fresh = new HamsterRewards(address(token), admin);
        uint64 now_ = uint64(block.timestamp);
        vm.startPrank(admin);
        // Zero-length window.
        vm.mockCall(address(game), abi.encodeCall(game.windowTimes, (10)), abi.encode(now_ + 1, now_ + 1));
        vm.expectRevert(HamsterRewards.InvalidFirstWindow.selector);
        fresh.configureGame(address(game), 10);
        // Window that already ended.
        vm.mockCall(address(game), abi.encodeCall(game.windowTimes, (10)), abi.encode(now_ - 2, now_ - 1));
        vm.expectRevert(HamsterRewards.InvalidFirstWindow.selector);
        fresh.configureGame(address(game), 10);
        // Window with no schedule at all.
        vm.mockCall(address(game), abi.encodeCall(game.windowTimes, (10)), abi.encode(uint64(0), uint64(0)));
        vm.expectRevert(HamsterRewards.InvalidFirstWindow.selector);
        fresh.configureGame(address(game), 10);
        // Starts one second from now and lasts one second: the smallest acceptable schedule.
        vm.mockCall(address(game), abi.encodeCall(game.windowTimes, (10)), abi.encode(now_ + 1, now_ + 2));
        fresh.configureGame(address(game), 10);
        vm.stopPrank();
        assertEq(fresh.firstEligibleWindow(), 10);
    }

    function test_CurrentWindowBoundaryUsesStrictComparison() public {
        HamsterRewards fresh = new HamsterRewards(address(token), admin);
        game.setCurrentWindow(type(uint256).max - 1);
        vm.startPrank(admin);
        vm.expectRevert(HamsterRewards.InvalidFirstWindow.selector);
        fresh.configureGame(address(game), type(uint256).max - 1);
        game.setCurrentWindow(0);
        vm.expectRevert(HamsterRewards.InvalidFirstWindow.selector);
        fresh.configureGame(address(game), 0);
        vm.stopPrank();
    }

    function test_NonOwnerCannotRenounceBeforeOrAfterConfiguration() public {
        HamsterRewards fresh = new HamsterRewards(address(token), admin);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fresh.renounceOwnership();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        rewards.renounceOwnership();
        assertEq(rewards.owner(), admin);
    }

    function test_OwnershipTransferAfterConfigurationGrantsNoPowers() public {
        vm.prank(admin);
        rewards.transferOwnership(alice);
        vm.prank(alice);
        rewards.acceptOwnership();
        assertEq(rewards.owner(), alice);
        vm.startPrank(alice);
        vm.expectRevert(HamsterRewards.AlreadyConfigured.selector);
        rewards.configureGame(address(game), 50);
        rewards.renounceOwnership();
        vm.stopPrank();
        assertEq(rewards.owner(), address(0));
        assertEq(rewards.pendingOwner(), address(0));
        assertEq(address(rewards.game()), address(game));
        assertEq(rewards.firstEligibleWindow(), 1);
        game.setPosition(1, alice, _position());
        assertEq(rewards.claimFor(1, alice), 35 ether);
    }

    function test_PendingTransferIsCancelledByRenounce() public {
        vm.startPrank(admin);
        rewards.transferOwnership(alice);
        rewards.renounceOwnership();
        vm.stopPrank();
        assertEq(rewards.pendingOwner(), address(0));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        rewards.acceptOwnership();
    }

    // ---------------------------------------------------------------- funding failures

    function test_FundingFromWalletsThatCannotPayIsAtomic() public {
        address broke = makeAddr("broke donor");
        vm.startPrank(broke);
        token.approve(address(rewards), 5 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, broke, 0, 5 ether));
        rewards.fund(5 ether);
        vm.stopPrank();
        token.transfer(broke, 5 ether);
        vm.prank(broke);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(rewards), 5 ether, 6 ether)
        );
        rewards.fund(6 ether);
        assertEq(token.balanceOf(address(rewards)), 1_000 ether);
        assertEq(token.balanceOf(broke), 5 ether);
        assertEq(token.allowance(broke, address(rewards)), 5 ether);
        vm.prank(broke);
        rewards.fund(5 ether);
        assertEq(token.balanceOf(address(rewards)), 1_005 ether);
    }

    function test_FundingWithUnlimitedAllowanceLeavesItUnlimited() public {
        token.approve(address(rewards), type(uint256).max);
        rewards.fund(1 ether);
        assertEq(token.allowance(address(this), address(rewards)), type(uint256).max);
    }

    function test_NoUnexpectedFunctionsOnRewards() public {
        string[6] memory signatures = [
            "setGame(address)",
            "setFirstEligibleWindow(uint256)",
            "setRewardPerIMD(uint256)",
            "sweep(address)",
            "emergencyWithdraw()",
            "claimBatch(uint256[])"
        ];
        vm.startPrank(admin);
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = address(rewards).call(abi.encodeWithSignature(signatures[i], admin));
            assertFalse(ok, signatures[i]);
        }
        vm.stopPrank();
        assertEq(token.balanceOf(address(rewards)), 1_000 ether);
    }

    // ---------------------------------------------------------------- properties

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_LossNeverExceedsStakeAndRespectsRefunds(
        uint64[5] memory stakes,
        uint256 guess,
        uint256 result,
        uint8 voidBits,
        bool oneSidedOver,
        bool oneSidedSleep
    ) public {
        IHamsterHour.Window memory w = _window();
        w.result = result;
        w.marketVoided = [voidBits & 1 != 0, voidBits & 2 != 0, voidBits & 4 != 0];
        if (oneSidedOver) w.over[1] = 0;
        if (oneSidedSleep) w.sleep[0] = 0;
        game.setWindow(1, w);
        IHamsterHour.Position memory p;
        p.over = [uint256(stakes[0]), uint256(stakes[1])];
        p.sleep = [uint256(stakes[2]), uint256(stakes[3])];
        p.exactAmount = stakes[4];
        p.guess = guess;
        game.setPosition(1, alice, p);

        uint256 loss = rewards.eligibleLoss(1, alice);
        uint256 total = uint256(stakes[0]) + stakes[1] + stakes[2] + stakes[3] + stakes[4];
        assertLe(loss, total, "loss exceeds wager");
        // Each refunded or uncontested market contributes nothing, so the rest bounds the loss.
        uint256 ceiling;
        if (!w.marketVoided[0] && !oneSidedOver && result != w.line) {
            ceiling += result > w.line ? stakes[0] : stakes[1];
        }
        if (!w.marketVoided[2] && !oneSidedSleep) ceiling += result == 0 ? stakes[2] : stakes[3];
        if (!w.marketVoided[1]) ceiling += stakes[4];
        assertLe(loss, ceiling, "a refunded market or a winning side was counted");
        // The exact ticket is the only part that can fall below the ceiling, and only by its own stake.
        assertGe(loss + stakes[4], ceiling, "a losing binary stake was dropped");
        if (voidBits & 7 == 7) assertEq(loss, 0);
        assertEq(rewards.rewardFor(1, alice), loss, "quote differs from eligibility");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_ClaimPaysExactlyTheQuoteOrLeavesEverythingUntouched(uint96 stake, uint96 rawInventory) public {
        uint256 inventory = bound(rawInventory, 0, 2_000 ether);
        HamsterRewards fresh = new HamsterRewards(address(token), admin);
        vm.prank(admin);
        fresh.configureGame(address(game), 5);
        game.setWindow(5, _window());
        IHamsterHour.Position memory p;
        p.over[0] = stake;
        game.setPosition(5, alice, p);
        if (inventory > 0) token.transfer(address(fresh), inventory);
        uint256 quote = fresh.rewardFor(5, alice);
        assertEq(quote, stake);
        (bool ok, bytes memory data) = address(fresh).call(abi.encodeCall(fresh.claimFor, (5, alice)));
        if (stake == 0) {
            assertFalse(ok);
            assertEq(data, abi.encodeWithSelector(HamsterRewards.NothingToClaim.selector));
        } else if (inventory < stake) {
            assertFalse(ok);
            assertEq(data, abi.encodeWithSelector(HamsterRewards.InsufficientRewards.selector, inventory, stake));
        } else {
            assertTrue(ok);
            assertEq(abi.decode(data, (uint256)), stake);
        }
        bool paidOut = ok;
        assertEq(fresh.claimed(5, alice), paidOut);
        assertEq(fresh.totalPaid(), paidOut ? stake : 0);
        assertEq(token.balanceOf(alice), paidOut ? stake : 0);
        assertEq(token.balanceOf(address(fresh)), paidOut ? inventory - stake : inventory);
        assertEq(fresh.rewardFor(5, alice), paidOut ? 0 : quote);
    }
}

/// @notice ERC-20 details the first token suite left out: allowance edge cases and event discipline.
contract HamsterTokenEdgeTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 ether;
    HamsterToken private token;
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    address private spender = makeAddr("spender");

    function setUp() public {
        token = new HamsterToken();
    }

    function test_SpendingTheExactAllowanceLeavesZero() public {
        token.transfer(alice, 10 ether);
        vm.prank(alice);
        token.approve(spender, 10 ether);
        vm.prank(spender);
        token.transferFrom(alice, bob, 10 ether);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(alice), 0);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    function test_ApproveOverwritesInsteadOfAccumulating() public {
        token.approve(spender, 5 ether);
        token.approve(spender, 3 ether);
        assertEq(token.allowance(address(this), spender), 3 ether);
        token.approve(spender, 0);
        assertEq(token.allowance(address(this), spender), 0);
    }

    function test_TransferFromEmitsTransferButNoApproval() public {
        token.approve(spender, 2 ether);
        vm.recordLogs();
        vm.prank(spender);
        token.transferFrom(address(this), bob, 2 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(address(uint160(uint256(logs[0].topics[1]))), address(this));
        assertEq(address(uint160(uint256(logs[0].topics[2]))), bob);
        assertEq(abi.decode(logs[0].data, (uint256)), 2 ether);
    }

    function test_FullBalanceMovesAndOneMoreWeiFails() public {
        token.transfer(alice, SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
        vm.prank(alice);
        token.transfer(bob, SUPPLY);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
        assertEq(token.balanceOf(bob), SUPPLY);
    }

    function test_TransferFromRequiresAllowanceEvenForSelf() public {
        token.transfer(alice, 4 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1 ether));
        token.transferFrom(alice, bob, 1 ether);
        vm.startPrank(alice);
        token.approve(alice, 1 ether);
        token.transferFrom(alice, bob, 1 ether);
        vm.stopPrank();
        assertEq(token.balanceOf(bob), 1 ether);
        assertEq(token.allowance(alice, alice), 0);
    }

    function test_TokenHoldsNoEtherAndHasNoReceive() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok);
        (ok,) = address(token).call{value: 1 ether}(abi.encodeCall(token.transfer, (alice, 1)));
        assertFalse(ok);
        assertEq(address(token).balance, 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_TransferChainConservesSupply(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, a);
        c = bound(c, 0, b);
        token.transfer(alice, a);
        vm.prank(alice);
        token.transfer(bob, b);
        vm.prank(bob);
        token.transfer(address(this), c);
        assertEq(token.balanceOf(alice), a - b);
        assertEq(token.balanceOf(bob), b - c);
        assertEq(token.balanceOf(address(this)), SUPPLY - a + c);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
