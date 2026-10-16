// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {HamsterToken} from "../src/HamsterToken.sol";

/// @dev Drives the fixed-supply token with several holders in random order. Every call records the
///      outcome it expected from the ERC-20 rules, so a transfer that silently succeeds with too little
///      balance, or an allowance that is not spent, is caught at the call and not only at the invariant.
contract TokenHandler is Test {
    HamsterToken public immutable token;
    address[6] public actors;
    uint256 public transfers;
    uint256 public rejectedTransfers;
    uint256 public approvals;
    uint256 public transfersFrom;
    uint256 public rejectedTransfersFrom;
    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    constructor(HamsterToken token_, address[6] memory actors_) {
        token = token_;
        actors = actors_;
    }

    function seed(address actor, uint256 amount) external {
        ghostBalance[actor] += amount;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 rawAmount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 balance = token.balanceOf(from);
        // One in four attempts asks for more than the sender holds.
        uint256 amount =
            rawAmount % 4 == 0 ? bound(rawAmount, balance + 1, type(uint256).max) : bound(rawAmount, 0, balance);
        vm.prank(from);
        if (amount > balance) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount)
            );
            token.transfer(to, amount);
            ++rejectedTransfers;
            return;
        }
        assertTrue(token.transfer(to, amount), "transfer returned false");
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ++transfers;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 rawAmount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        // Mix exact, zero and unlimited allowances.
        uint256 amount = rawAmount % 5 == 0 ? type(uint256).max : bound(rawAmount, 0, 2_000 ether);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "approve returned false");
        ghostAllowance[owner][spender] = amount;
        ++approvals;
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 rawAmount) external {
        address spender = actors[spenderSeed % actors.length];
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 balance = token.balanceOf(from);
        uint256 allowance = token.allowance(from, spender);
        uint256 cap = balance < allowance ? balance : allowance;
        uint256 amount = rawAmount % 4 == 0 ? bound(rawAmount, cap + 1, cap + 1_000 ether) : bound(rawAmount, 0, cap);
        vm.prank(spender);
        if (amount > allowance) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowance, amount)
            );
            token.transferFrom(from, to, amount);
            ++rejectedTransfersFrom;
            return;
        }
        if (amount > balance) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount)
            );
            token.transferFrom(from, to, amount);
            ++rejectedTransfersFrom;
            return;
        }
        assertTrue(token.transferFrom(from, to, amount), "transferFrom returned false");
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        if (allowance != type(uint256).max) ghostAllowance[from][spender] = allowance - amount;
        ++transfersFrom;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
contract HamsterTokenInvariantTest is StdInvariant, Test {
    uint256 private constant SUPPLY = 1_000_000_000 ether;
    HamsterToken private token;
    TokenHandler private handler;
    address[6] private actors;

    function setUp() public {
        token = new HamsterToken();
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("holder ", vm.toString(i)));
        }
        handler = new TokenHandler(token, actors);
        // Uneven starting balances; the first holder starts with nothing and only receives.
        uint256[6] memory amounts = [uint256(0), 1 ether, 1_000 ether, 1_000_000 ether, SUPPLY / 2, 1];
        for (uint256 i; i < actors.length; ++i) {
            if (amounts[i] == 0) continue;
            token.transfer(actors[i], amounts[i]);
            handler.seed(actors[i], amounts[i]);
        }
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = TokenHandler.transfer.selector;
        selectors[1] = TokenHandler.approve.selector;
        selectors[2] = TokenHandler.transferFrom.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_SupplyIsFixedAndFullyAccountedFor() public view {
        assertEq(token.totalSupply(), SUPPLY);
        uint256 held;
        for (uint256 i; i < actors.length; ++i) {
            held += token.balanceOf(actors[i]);
        }
        assertEq(held + token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function invariant_BalancesMatchTheGhostLedger() public view {
        for (uint256 i; i < actors.length; ++i) {
            assertEq(token.balanceOf(actors[i]), handler.ghostBalance(actors[i]));
        }
    }

    function invariant_AllowancesMatchTheGhostLedger() public view {
        for (uint256 i; i < actors.length; ++i) {
            for (uint256 j; j < actors.length; ++j) {
                assertEq(token.allowance(actors[i], actors[j]), handler.ghostAllowance(actors[i], actors[j]));
            }
        }
    }

    function invariant_MetadataNeverChanges() public view {
        assertEq(token.name(), "HAMSTER");
        assertEq(token.symbol(), "HAMSTER");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
    }
}
