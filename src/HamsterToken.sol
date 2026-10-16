// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed-supply HAMSTER. The deployment caller receives the complete supply exactly once.
contract HamsterToken is ERC20 {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    constructor() ERC20("HAMSTER", "HAMSTER") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
