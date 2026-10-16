// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {HamsterToken} from "../src/HamsterToken.sol";
import {HamsterRewards} from "../src/HamsterRewards.sol";
import {IHamsterHour} from "../src/interfaces/IHamsterHour.sol";
import {MockHamsterHour} from "./mocks/MockHamsterHour.sol";

abstract contract RewardsFixture is Test {
    HamsterToken internal token;
    HamsterRewards internal rewards;
    MockHamsterHour internal game;
    address internal admin = makeAddr("launch owner");
    address internal alice = makeAddr("losing bettor");
    address internal bob = makeAddr("winning bettor");
    address internal donor = makeAddr("donor");

    function setUp() public virtual {
        vm.warp(1 hours);
        token = new HamsterToken();
        game = new MockHamsterHour(uint64(block.timestamp));
        rewards = new HamsterRewards(address(token), admin);
        vm.prank(admin);
        rewards.configureGame(address(game), 1);
        _fund(1_000 ether);
        vm.warp(4 hours);
        game.setWindow(1, _window());
        IHamsterHour.Position memory p;
        p.over[0] = 10 ether;
        p.sleep[1] = 5 ether;
        p.exactAmount = 20 ether;
        p.guess = 1_000;
        game.setPosition(1, alice, p);
        p = _emptyPosition();
        p.over[1] = 80 ether;
        p.sleep[0] = 90 ether;
        p.exactAmount = 20 ether;
        p.guess = 121;
        game.setPosition(1, bob, p);
    }

    function _window() internal pure returns (IHamsterHour.Window memory w) {
        w.status = 2;
        w.startsAt = 2 hours;
        w.endsAt = 3 hours;
        w.line = 100;
        w.result = 120;
        w.source = "test-only wheel readings";
        w.pools = [uint256(200 ether), 100 ether, 200 ether];
        w.over = [uint256(100 ether), 100 ether];
        w.sleep = [uint256(100 ether), 100 ether];
        w.distances = [uint256(0), 1, 2];
        w.ties = [uint256(1), 1, 1];
        w.rankCount = 3;
    }

    function _emptyPosition() internal pure returns (IHamsterHour.Position memory p) {}

    function _fund(uint256 amount) internal {
        token.approve(address(rewards), amount);
        rewards.fund(amount);
    }
}

contract HamsterRewardsSetupTest is RewardsFixture {
    event GameConfigured(address indexed game, uint256 indexed firstEligibleWindow);

    function test_UnconfiguredOperationsHaveClearErrors() public {
        HamsterRewards fresh = new HamsterRewards(address(token), admin);
        vm.expectRevert(HamsterRewards.NotConfigured.selector);
        fresh.fund(1);
        vm.expectRevert(HamsterRewards.NotConfigured.selector);
        fresh.claim(1);
        vm.expectRevert(HamsterRewards.NotConfigured.selector);
        fresh.claimFor(1, alice);
        vm.expectRevert(HamsterRewards.NotConfigured.selector);
        fresh.rewardFor(1, alice);
        vm.expectRevert(HamsterRewards.NotConfigured.selector);
        fresh.eligibleLoss(1, alice);
        vm.prank(admin);
        vm.expectRevert(HamsterRewards.NotConfigured.selector);
        fresh.renounceOwnership();
    }

    function test_ConstructorValidatesAddressesButMakesNoExternalCalls() public {
        vm.expectRevert(HamsterRewards.InvalidAddress.selector);
        new HamsterRewards(address(0), admin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new HamsterRewards(address(token), address(0));
        // Models dependency addresses on the launch's empty-chain constructor check.
        address futureToken = makeAddr("future token");
        HamsterRewards fresh = new HamsterRewards(futureToken, admin);
        assertEq(address(fresh.hamster()), futureToken);
        assertEq(fresh.owner(), admin);
    }

    function test_OnlyExplicitOwnerConfigures() public {
        HamsterRewards fresh = new HamsterRewards(address(token), admin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        fresh.configureGame(address(game), 10);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fresh.configureGame(address(game), 10);
        vm.prank(admin);
        vm.expectEmit(true, true, false, true, address(fresh));
        emit GameConfigured(address(game), 10);
        fresh.configureGame(address(game), 10);
        assertEq(fresh.firstEligibleWindow(), 10);
    }

    function test_ConfigurationCannotChangeEvenWithoutFundingOrClaims() public {
        HamsterRewards fresh = new HamsterRewards(address(token), admin);
        vm.startPrank(admin);
        fresh.configureGame(address(game), 10);
        vm.expectRevert(HamsterRewards.AlreadyConfigured.selector);
        fresh.configureGame(address(game), 11);
        vm.stopPrank();
    }

    function test_InvalidGameAndWrongWagerTokenRejected() public {
        HamsterRewards fresh = new HamsterRewards(address(token), admin);
        vm.startPrank(admin);
        vm.expectRevert(HamsterRewards.InvalidGame.selector);
        fresh.configureGame(address(0), 10);
        vm.expectRevert(HamsterRewards.InvalidGame.selector);
        fresh.configureGame(alice, 10);
        vm.expectRevert(HamsterRewards.InvalidGame.selector);
        fresh.configureGame(address(token), 10);
        vm.expectRevert(HamsterRewards.InvalidGame.selector);
        fresh.configureGame(address(fresh), 10);
        vm.stopPrank();
        game.setIMD(address(token));
        vm.prank(admin);
        vm.expectRevert(HamsterRewards.InvalidGame.selector);
        fresh.configureGame(address(game), 10);
        assertEq(address(fresh.game()), address(0));
    }

    function test_FirstWindowMustBeFutureAndNotCurrent() public {
        HamsterRewards fresh = new HamsterRewards(address(token), admin);
        game.setCurrentWindow(2);
        vm.startPrank(admin);
        vm.expectRevert(HamsterRewards.InvalidFirstWindow.selector);
        fresh.configureGame(address(game), 2);
        // Starts at exactly the current timestamp, which is already too late.
        vm.expectRevert(HamsterRewards.InvalidFirstWindow.selector);
        fresh.configureGame(address(game), 3);
        fresh.configureGame(address(game), 4);
        vm.stopPrank();
    }

    function test_InvalidGameTimesRejected() public {
        HamsterRewards fresh = new HamsterRewards(address(token), admin);
        vm.mockCall(
            address(game), abi.encodeCall(game.windowTimes, (10)), abi.encode(uint64(100 hours), uint64(99 hours))
        );
        vm.prank(admin);
        vm.expectRevert(HamsterRewards.InvalidFirstWindow.selector);
        fresh.configureGame(address(game), 10);
    }

    function test_TwoStepOwnershipTransferBeforeConfiguration() public {
        HamsterRewards fresh = new HamsterRewards(address(token), admin);
        vm.prank(admin);
        fresh.transferOwnership(alice);
        assertEq(fresh.owner(), admin);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        fresh.acceptOwnership();
        vm.prank(alice);
        fresh.acceptOwnership();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        fresh.configureGame(address(game), 10);
        vm.prank(alice);
        fresh.configureGame(address(game), 10);
    }

    function test_RenounceAfterConfigurationDoesNotStopClaims() public {
        vm.prank(admin);
        rewards.renounceOwnership();
        assertEq(rewards.owner(), address(0));
        rewards.claimFor(1, alice);
        assertEq(token.balanceOf(alice), 35 ether);
    }

    function test_AdminCannotWithdrawPauseOrChangeRate() public {
        string[4] memory signatures =
            ["withdraw(address,uint256)", "pause()", "setRate(uint256)", "rescue(address,uint256)"];
        vm.startPrank(admin);
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = address(rewards).call(abi.encodeWithSignature(signatures[i], admin, 1_000 ether));
            assertFalse(ok);
        }
        vm.stopPrank();
        assertEq(token.balanceOf(address(rewards)), 1_000 ether);
        rewards.claimFor(1, alice);
        assertEq(token.balanceOf(alice), 35 ether);
    }
}

contract HamsterRewardsEligibilityTest is RewardsFixture {
    function test_LosingBetsAcrossMarketsEarnExistingTokens() public {
        assertEq(rewards.eligibleLoss(1, alice), 35 ether);
        assertEq(rewards.rewardFor(1, alice), 35 ether);
        vm.prank(alice);
        assertEq(rewards.claim(1), 35 ether);
        assertEq(token.balanceOf(alice), 35 ether);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(rewards.rewardFor(1, alice), 0);
    }

    function test_WinnersAndNonBettorsReceiveNoLossReward() public {
        assertEq(rewards.eligibleLoss(1, bob), 0);
        assertEq(rewards.eligibleLoss(1, donor), 0);
        vm.prank(bob);
        vm.expectRevert(HamsterRewards.NothingToClaim.selector);
        rewards.claim(1);
        assertFalse(rewards.claimed(1, bob));
    }

    function test_UnderResultAndZeroResultChooseCorrectLosers() public {
        IHamsterHour.Window memory w = _window();
        w.result = 50;
        game.setWindow(1, w);
        assertEq(rewards.eligibleLoss(1, alice), 25 ether);
        assertEq(rewards.eligibleLoss(1, bob), 100 ether);
        w.result = 0;
        game.setWindow(1, w);
        assertEq(rewards.eligibleLoss(1, alice), 20 ether);
        assertEq(rewards.eligibleLoss(1, bob), 190 ether);
    }

    function test_LineEqualityRefundsBothBinarySides() public {
        IHamsterHour.Window memory w = _window();
        w.result = w.line;
        game.setWindow(1, w);
        assertEq(rewards.eligibleLoss(1, alice), 25 ether);
        assertEq(rewards.eligibleLoss(1, bob), 20 ether);
    }

    function test_UncontestedBinaryMarketsNeverEarnRewards() public {
        IHamsterHour.Window memory w = _window();
        w.over[1] = 0;
        w.sleep[0] = 0;
        game.setWindow(1, w);
        assertEq(rewards.eligibleLoss(1, alice), 20 ether);
        w.over = [uint256(0), 100 ether];
        w.sleep = [uint256(100 ether), 0];
        game.setWindow(1, w);
        assertEq(rewards.eligibleLoss(1, alice), 20 ether);
    }

    function test_MarketRefundFlagsExcludeAllRefundedBets() public {
        IHamsterHour.Window memory w = _window();
        w.marketVoided = [true, true, true];
        game.setWindow(1, w);
        assertEq(rewards.eligibleLoss(1, alice), 0);
        vm.expectRevert(HamsterRewards.NothingToClaim.selector);
        rewards.claimFor(1, alice);
    }

    function test_VoidedWindowHasNoRewardEvenWithLosingLookingPositions() public {
        IHamsterHour.Window memory w = _window();
        w.status = 3;
        game.setWindow(1, w);
        assertEq(rewards.rewardFor(1, alice), 0);
        vm.expectRevert(HamsterRewards.NothingToClaim.selector);
        rewards.claimFor(1, alice);
    }

    function test_ExactAllThreeRanksAndTiesAreWinners() public {
        IHamsterHour.Window memory w = _window();
        w.ties = [uint256(4), 2, 8];
        game.setWindow(1, w);
        IHamsterHour.Position memory p;
        p.exactAmount = 7 ether;
        for (uint256 distance; distance < 3; ++distance) {
            p.guess = w.result - distance;
            game.setPosition(1, alice, p);
            assertEq(rewards.eligibleLoss(1, alice), 0);
            p.guess = w.result + distance;
            game.setPosition(1, alice, p);
            assertEq(rewards.eligibleLoss(1, alice), 0);
        }
        p.guess = w.result + 3;
        game.setPosition(1, alice, p);
        assertEq(rewards.eligibleLoss(1, alice), 7 ether);
    }

    function test_ExactSingleRankAndNoUnusedRankMatch() public {
        IHamsterHour.Window memory w = _window();
        w.rankCount = 1;
        w.distances[0] = 2;
        w.distances[1] = 1;
        game.setWindow(1, w);
        IHamsterHour.Position memory p;
        p.exactAmount = 1 ether;
        p.guess = 122;
        game.setPosition(1, alice, p);
        assertEq(rewards.eligibleLoss(1, alice), 0);
        p.guess = 121;
        game.setPosition(1, alice, p);
        assertEq(rewards.eligibleLoss(1, alice), 1 ether);
    }

    function test_ExactDistanceWorksAtUint256Extremes() public {
        IHamsterHour.Window memory w = _window();
        IHamsterHour.Position memory p;
        p.exactAmount = 1 ether;
        p.guess = type(uint256).max;
        w.result = 0;
        game.setWindow(1, w);
        game.setPosition(1, alice, p);
        assertEq(rewards.eligibleLoss(1, alice), 1 ether);
        w.result = type(uint256).max;
        p.guess = 0;
        game.setWindow(1, w);
        game.setPosition(1, alice, p);
        assertEq(rewards.eligibleLoss(1, alice), 1 ether);
    }

    function test_InvalidRankDataFailsClosed() public {
        IHamsterHour.Window memory w = _window();
        w.rankCount = 4;
        game.setWindow(1, w);
        vm.expectRevert(HamsterRewards.InvalidGameState.selector);
        rewards.claimFor(1, alice);
        w.rankCount = 0;
        game.setWindow(1, w);
        vm.expectRevert(HamsterRewards.InvalidGameState.selector);
        rewards.claimFor(1, alice);
        w.rankCount = 3;
        w.ties[1] = 0;
        game.setWindow(1, w);
        vm.expectRevert(HamsterRewards.InvalidGameState.selector);
        rewards.claimFor(1, alice);
    }

    function test_UnknownOpenAndUnsettledWindowsCannotClaim() public {
        for (uint8 status; status < 2; ++status) {
            IHamsterHour.Window memory w = _window();
            w.status = status;
            game.setWindow(1, w);
            vm.expectRevert(HamsterRewards.WindowNotSettled.selector);
            rewards.claimFor(1, alice);
        }
        // Passing the game's timeout is not evidence of a losing bet.
        vm.warp(100 days);
        vm.expectRevert(HamsterRewards.WindowNotSettled.selector);
        rewards.claimFor(1, alice);
        assertFalse(rewards.claimed(1, alice));
    }

    function test_PrematureSettledResultRejectedUntilEnd() public {
        vm.warp(3 hours - 1);
        vm.expectRevert(HamsterRewards.WindowNotSettled.selector);
        rewards.claimFor(1, alice);
        vm.warp(3 hours);
        assertEq(rewards.claimFor(1, alice), 35 ether);
    }

    function test_OldWindowsExcludedAndNoRewardExpiryAfterFinality() public {
        game.setWindow(0, _window());
        vm.expectRevert(HamsterRewards.WindowNotEligible.selector);
        rewards.claimFor(0, alice);
        vm.warp(10 * 365 days);
        rewards.claimFor(1, alice);
        assertEq(token.balanceOf(alice), 35 ether);
    }

    function test_IMDAndJackpotClaimStateCannotChangeEligibility() public {
        IHamsterHour.Position memory p = game.position(1, alice);
        p.imdClaimed = true;
        p.jackpotClaimed = true;
        game.setPosition(1, alice, p);
        IHamsterHour.Window memory w = game.window(1);
        w.paid = w.rewards;
        w.rankPaid = w.rankRewards;
        w.claimedWeight = w.pools;
        w.rankClaimed = w.ties;
        w.jackpotClaimed = 4;
        game.setWindow(1, w);
        assertEq(rewards.claimFor(1, alice), 35 ether);
    }

    function test_WalletWithBothWinningAndLosingBetsOnlyEarnsLosingStake() public {
        IHamsterHour.Position memory p = game.position(1, bob);
        p.over[0] = 1 ether;
        game.setPosition(1, bob, p);
        assertEq(rewards.claimFor(1, bob), 1 ether);
    }

    function testFuzz_ExactRanking(uint256 guess, uint256 result, uint128 stake) public {
        IHamsterHour.Window memory w = _window();
        w.result = result;
        IHamsterHour.Position memory p;
        p.guess = guess;
        p.exactAmount = uint256(stake);
        game.setWindow(1, w);
        game.setPosition(1, alice, p);
        uint256 distance = guess >= result ? guess - result : result - guess;
        assertEq(rewards.eligibleLoss(1, alice), distance <= 2 ? 0 : uint256(stake));
    }

    function testFuzz_BinaryLosersAndRefunds(
        uint128 under,
        uint128 over,
        uint128 running,
        uint128 sleeping,
        uint8 result
    ) public {
        IHamsterHour.Window memory w = _window();
        w.result = result;
        IHamsterHour.Position memory p;
        p.over = [uint256(under), uint256(over)];
        p.sleep = [uint256(running), uint256(sleeping)];
        game.setWindow(1, w);
        game.setPosition(1, alice, p);
        uint256 expected;
        if (result < 100) expected = over;
        if (result > 100) expected = under;
        expected += result == 0 ? running : sleeping;
        assertEq(rewards.eligibleLoss(1, alice), expected);
    }
}

contract HamsterRewardsPaymentTest is RewardsFixture {
    event Funded(address indexed donor, uint256 amount);
    event RewardClaimed(address indexed account, uint256 indexed windowId, uint256 lostIMD, uint256 reward);

    function test_PermissionlessFundingWithExactAllowanceAndEvent() public {
        token.transfer(donor, 50 ether);
        vm.startPrank(donor);
        token.approve(address(rewards), 50 ether);
        vm.expectEmit(true, false, false, true, address(rewards));
        emit Funded(donor, 50 ether);
        rewards.fund(50 ether);
        vm.stopPrank();
        assertEq(token.balanceOf(address(rewards)), 1_050 ether);
        assertEq(token.balanceOf(donor), 0);
        assertEq(token.allowance(donor, address(rewards)), 0);
    }

    function test_ZeroFundingAndFundingWithoutAllowanceFail() public {
        vm.expectRevert(HamsterRewards.ZeroAmount.selector);
        rewards.fund(0);
        vm.expectRevert();
        rewards.fund(1);
        assertEq(token.balanceOf(address(rewards)), 1_000 ether);
    }

    function test_ClaimForPaysBettorNeverCaller() public {
        vm.prank(donor);
        vm.expectEmit(true, true, false, true, address(rewards));
        emit RewardClaimed(alice, 1, 35 ether, 35 ether);
        rewards.claimFor(1, alice);
        assertEq(token.balanceOf(alice), 35 ether);
        assertEq(token.balanceOf(donor), 0);
        assertEq(token.balanceOf(address(rewards)), 965 ether);
        assertEq(rewards.totalPaid(), 35 ether);
        vm.expectRevert(HamsterRewards.InvalidAddress.selector);
        rewards.claimFor(1, address(0));
    }

    function test_NoDoubleClaimAndIndependentWindows() public {
        rewards.claimFor(1, alice);
        vm.prank(alice);
        vm.expectRevert(HamsterRewards.AlreadyClaimed.selector);
        rewards.claim(1);
        vm.expectRevert(HamsterRewards.AlreadyClaimed.selector);
        rewards.claimFor(1, alice);
        game.setWindow(2, _window());
        game.setPosition(2, alice, game.position(1, alice));
        rewards.claimFor(2, alice);
        assertEq(token.balanceOf(alice), 70 ether);
        assertEq(rewards.totalPaid(), 70 ether);
    }

    function test_InsufficientInventoryDoesNotConsumeClaimAndTopUpAllowsRetry() public {
        IHamsterHour.Position memory p;
        p.over[0] = 1_001 ether;
        game.setPosition(1, alice, p);
        vm.expectRevert(abi.encodeWithSelector(HamsterRewards.InsufficientRewards.selector, 1_000 ether, 1_001 ether));
        rewards.claimFor(1, alice);
        assertFalse(rewards.claimed(1, alice));
        assertEq(rewards.totalPaid(), 0);
        _fund(1 ether);
        rewards.claimFor(1, alice);
        assertEq(token.balanceOf(alice), 1_001 ether);
        assertEq(token.balanceOf(address(rewards)), 0);
        assertEq(token.totalSupply(), token.INITIAL_SUPPLY());
    }

    function test_DirectDonationsAreUsable() public {
        token.transfer(address(rewards), 25 ether);
        IHamsterHour.Position memory p;
        p.over[0] = 1_025 ether;
        game.setPosition(1, alice, p);
        rewards.claimFor(1, alice);
        assertEq(token.balanceOf(address(rewards)), 0);
    }

    function test_ExternalGameFailureDoesNotConsumeClaim() public {
        game.setReadsRevert(true);
        vm.expectRevert("game unavailable");
        rewards.claimFor(1, alice);
        assertFalse(rewards.claimed(1, alice));
        assertEq(rewards.totalPaid(), 0);
        assertEq(token.balanceOf(address(rewards)), 1_000 ether);
        game.setReadsRevert(false);
        rewards.claimFor(1, alice);
        assertEq(token.balanceOf(alice), 35 ether);
    }

    function test_MalformedGameResponseFailsClosed() public {
        vm.mockCall(address(game), abi.encodeCall(game.window, (1)), hex"01");
        vm.expectRevert();
        rewards.claimFor(1, alice);
        assertFalse(rewards.claimed(1, alice));
        assertEq(rewards.totalPaid(), 0);
    }

    function test_NoAccidentalEtherAccepted() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(rewards).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function testFuzz_ClaimsConserveTokens(uint128 rawStake, uint128 rawInventory) public {
        uint256 stake = bound(rawStake, 1, 100_000 ether);
        uint256 inventory = bound(rawInventory, 0, 100_000 ether);
        HamsterRewards isolated = new HamsterRewards(address(token), admin);
        vm.prank(admin);
        isolated.configureGame(address(game), 10);
        game.setWindow(10, _window());
        IHamsterHour.Position memory p;
        p.over[0] = stake;
        game.setPosition(10, alice, p);
        token.transfer(address(isolated), inventory);
        if (inventory < stake) {
            vm.expectRevert(abi.encodeWithSelector(HamsterRewards.InsufficientRewards.selector, inventory, stake));
            isolated.claimFor(10, alice);
            assertFalse(isolated.claimed(10, alice));
            assertEq(token.balanceOf(address(isolated)), inventory);
        } else {
            isolated.claimFor(10, alice);
            assertEq(token.balanceOf(alice) + token.balanceOf(address(isolated)), inventory);
            assertEq(isolated.totalPaid(), stake);
        }
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }
}

/// @dev Deliberately hostile test asset to exercise guards and rollback. Never used in deployment.
contract AdversarialToken is ERC20 {
    HamsterRewards public target;
    address public bettor;
    bool public failTransfer;
    bool public feeOnFunding;
    bool public callback;
    bool public reentrySucceeded;
    bytes public reentryError;

    constructor() ERC20("Test only", "TEST") {
        _mint(msg.sender, 1_000 ether);
    }

    function configure(HamsterRewards target_, address bettor_, bool fail_, bool fee_, bool callback_) external {
        target = target_;
        bettor = bettor_;
        failTransfer = fail_;
        feeOnFunding = fee_;
        callback = callback_;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (failTransfer) return false;
        if (callback) {
            (reentrySucceeded, reentryError) = address(target).call(abi.encodeCall(target.claimFor, (1, bettor)));
        }
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (callback) {
            (reentrySucceeded, reentryError) = address(target).call(abi.encodeCall(target.claimFor, (1, bettor)));
        }
        return super.transferFrom(from, to, feeOnFunding ? value - 1 : value);
    }
}

contract HamsterRewardsAdversarialTest is RewardsFixture {
    AdversarialToken private hostile;
    HamsterRewards private guarded;

    function setUp() public override {
        super.setUp();
        hostile = new AdversarialToken();
        guarded = new HamsterRewards(address(hostile), admin);
        vm.warp(1 hours);
        vm.prank(admin);
        guarded.configureGame(address(game), 1);
        vm.warp(4 hours);
        hostile.approve(address(guarded), 100 ether);
        guarded.fund(100 ether);
    }

    function test_FailedTokenTransferRollsBackClaimAndAccounting() public {
        hostile.configure(guarded, alice, true, false, false);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(hostile)));
        guarded.claimFor(1, alice);
        assertFalse(guarded.claimed(1, alice));
        assertEq(guarded.totalPaid(), 0);
        assertEq(hostile.balanceOf(address(guarded)), 100 ether);
        hostile.configure(guarded, alice, false, false, false);
        guarded.claimFor(1, alice);
        assertEq(hostile.balanceOf(alice), 35 ether);
    }

    function test_TransferCallbackCannotReenterClaim() public {
        hostile.configure(guarded, alice, false, false, true);
        guarded.claimFor(1, alice);
        assertFalse(hostile.reentrySucceeded());
        assertEq(hostile.reentryError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(hostile.balanceOf(alice), 35 ether);
        assertEq(guarded.totalPaid(), 35 ether);
    }

    function test_FundingCallbackCannotReenterClaim() public {
        hostile.configure(guarded, alice, false, false, true);
        hostile.approve(address(guarded), 5 ether);
        guarded.fund(5 ether);
        assertFalse(hostile.reentrySucceeded());
        assertEq(hostile.reentryError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertFalse(guarded.claimed(1, alice));
        assertEq(guarded.totalPaid(), 0);
        assertEq(hostile.balanceOf(address(guarded)), 105 ether);
    }

    function test_FeeOnTransferFundingRejectedAtomically() public {
        hostile.configure(guarded, alice, false, true, false);
        hostile.approve(address(guarded), 5 ether);
        vm.expectRevert(HamsterRewards.UnexpectedReceivedAmount.selector);
        guarded.fund(5 ether);
        assertEq(hostile.balanceOf(address(guarded)), 100 ether);
        assertEq(hostile.allowance(address(this), address(guarded)), 5 ether);
    }
}
