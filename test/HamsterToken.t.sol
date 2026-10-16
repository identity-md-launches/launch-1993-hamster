// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {HamsterToken} from "../src/HamsterToken.sol";
import {HamsterRewards} from "../src/HamsterRewards.sol";

contract FactoryHarness {
    function deploy(address launchOwner) external returns (HamsterToken token, HamsterRewards rewards) {
        token = new HamsterToken();
        rewards = new HamsterRewards(address(token), launchOwner);
    }

    function distribute(HamsterToken token, address to, uint256 amount) external {
        require(token.transfer(to, amount));
    }
}

contract HamsterTokenTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 ether;
    HamsterToken private token;
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    address private spender = makeAddr("spender");

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new HamsterToken();
    }

    function test_MetadataAndWholeSupply() public view {
        assertEq(token.name(), "HAMSTER");
        assertEq(token.symbol(), "HAMSTER");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function test_ConstructorEmitsSingleMint() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), address(this), SUPPLY);
        new HamsterToken();
    }

    function test_FactoryOwnsEntireSupplyAndAppHasExplicitOwner() public {
        FactoryHarness factory = new FactoryHarness();
        (HamsterToken launched, HamsterRewards rewards) = factory.deploy(alice);
        assertEq(launched.balanceOf(address(factory)), SUPPLY);
        assertEq(launched.balanceOf(address(rewards)), 0);
        assertEq(launched.balanceOf(alice), 0);
        assertEq(rewards.owner(), alice);
        assertEq(address(rewards.game()), address(0));
        assertEq(address(rewards.hamster()), address(launched));
    }

    function test_LaunchDistributionAndClaimArriveExactly() public {
        FactoryHarness factory = new FactoryHarness();
        (HamsterToken launched,) = factory.deploy(alice);
        address distributor = makeAddr("distributor");
        address poolManager = makeAddr("pool manager");
        factory.distribute(launched, distributor, SUPPLY / 10);
        factory.distribute(launched, poolManager, SUPPLY / 10);
        factory.distribute(launched, alice, SUPPLY * 8 / 10);
        assertEq(launched.balanceOf(address(factory)), 0);
        assertEq(launched.balanceOf(alice), SUPPLY * 8 / 10);
        vm.prank(distributor);
        launched.transfer(bob, SUPPLY / 10);
        assertEq(launched.balanceOf(bob), SUPPLY / 10);
        // Exact movement through a pool and back; the independent floor exercises real v4 swaps.
        vm.prank(poolManager);
        launched.transfer(spender, 100 ether);
        vm.prank(spender);
        launched.transfer(poolManager, 100 ether);
        assertEq(launched.balanceOf(poolManager), SUPPLY / 10);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    function test_TransferAndEvents() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), alice, 12 ether);
        assertTrue(token.transfer(alice, 12 ether));
        assertEq(token.balanceOf(alice), 12 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 12 ether);
    }

    function test_ApproveTransferFromAndRevoke() public {
        token.transfer(alice, 10 ether);
        vm.prank(alice);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(alice, spender, 7 ether);
        token.approve(spender, 7 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 4 ether));
        assertEq(token.allowance(alice, spender), 3 ether);
        assertEq(token.balanceOf(bob), 4 ether);
        vm.prank(alice);
        token.approve(spender, 0);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    function test_StandardUnlimitedAllowanceBehavior() public {
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        token.transferFrom(address(this), bob, 9);
        assertEq(token.allowance(address(this), spender), type(uint256).max);
    }

    function test_InsufficientBalanceAndAllowanceAreAtomic() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
        vm.prank(alice);
        token.approve(spender, 20);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 10));
        token.transferFrom(alice, bob, 10);
        assertEq(token.allowance(alice, spender), 20);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ZeroAddressesRejected() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.transferFrom(address(0), bob, 0);
    }

    function test_ZeroAndSelfTransfersAreStandard() public {
        vm.prank(alice);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 0);
        token.transfer(bob, 0);
        token.transfer(address(this), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        vm.prank(spender);
        token.transferFrom(alice, bob, 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_NoMintFreezeSeizeOrUpgradeEndpoints() public {
        token.transfer(alice, 100);
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "pause()",
            "blacklist(address)",
            "freeze(address)",
            "seize(address)",
            "burnFrom(address,uint256)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool success,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, type(uint128).max));
            assertFalse(success, signatures[i]);
        }
        assertEq(token.balanceOf(alice), 100);
        vm.prank(alice);
        token.transfer(bob, 100);
        assertEq(token.balanceOf(bob), 100);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_NoForbiddenRuntimeOpcodes() public view {
        bytes memory runtime = address(token).code;
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
        }
    }

    function testFuzz_ConservationAndAllowance(uint256 rawAmount, uint256 rawSpend) public {
        uint256 amount = bound(rawAmount, 0, SUPPLY);
        uint256 spend = bound(rawSpend, 0, amount);
        token.transfer(alice, amount);
        vm.prank(alice);
        token.approve(spender, spend);
        vm.prank(spender);
        token.transferFrom(alice, bob, spend);
        assertEq(token.balanceOf(alice), amount - spend);
        assertEq(token.balanceOf(bob), spend);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(alice) + token.balanceOf(bob), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
