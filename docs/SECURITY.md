# Local security review

This is a source review and local verification record, not an independent audit. Public-fund use still
needs the contributor network's separate adversarial review and validation of the configured game.

| Area | Assessment |
| --- | --- |
| Supply | The sole `_mint` call in delivered token code is in the constructor. All supply goes to `msg.sender`. Reward payouts are transfers. The token has no owner or upgrade path. |
| Launch compatibility | Constructors have 0 and 2 static arguments, do not make external calls, and do not move the token's launch balance. Contract names fit the launch limits. No linked library deployment is needed. |
| Access control | Only the explicit owner can set the game and first eligible window, once. Ownership handoff requires acceptance. No withdrawal, pause, confiscation, blacklist, or mutable rate exists. |
| Setup trust | Correct game identity and semantics are an owner responsibility. An attacker-controlled implementation can emulate the ABI and fabricate losses; the `IMD()` check alone cannot authenticate it. Configuration is irreversible. |
| Outcomes | No timestamp/blockhash/caller-seed randomness. The existing game handles real-world results. Rewards require its finalized status and an ended window. Refunds and unresolved outcomes do not earn loss rewards. |
| Boundaries | Start must be strictly in the future when configured. A final result is accepted at the window end, not before it. Old windows are excluded. No arbitrary reward claim deadline exists. |
| Replay/theft | Claims are keyed by window and bettor under one permanently configured game. Third-party claims pay the bettor. There are no signatures, user-supplied proofs, arbitrary call destinations, or recipient overrides. |
| Reentrancy | Claim/funding functions use OpenZeppelin ReentrancyGuard. Claims record consumption before transfer. Game reads compile to static calls. Failed transfers revert claim state and counters. Hostile token callbacks are tested. |
| Asset accounting | Only the launch's immutable HAMSTER token is paid. SafeERC20 checks transfer success. Donations verify exact balance increase. Failed funding and insufficient reserves are atomic; claims can retry. Invariants conserve all tracked token balances. |
| Arithmetic | Both specified tokens use 18 decimals. The 1:1 base-unit reward needs no rounding. Distance uses ordered unsigned subtraction and is tested at uint256 extremes. Checked additions fail closed on malformed excessive stakes. |
| Bounded work | Each claim reads one window and one position; at most three exact ranks are inspected. No loop over all bettors/windows, storage enumeration, or batch transfer exists. |
| Griefing/incentives | Claims have no reserved inventory and may exhaust funding. Donations cannot be withdrawn, even if the game fails. Opposite-side or cross-wallet bets can earn loss rewards despite offsetting gains. Rate and economics need review before funding. |
| External failure | If the game reverts or returns malformed data, no claim is consumed. If it stops retaining old stakes, rewards may become unavailable. If it allows results to change, this design's finality assumption fails. There is no administrative bypass. |
| Trust outside this project | Game data collection, oracle signatures, fees, IMD custody, refunds and jackpot correctness belong to the existing game. Its source and post-claim record persistence were not independently audited in this task. |

## Validation

- Solidity 0.8.26 compilation and Foundry unit/fuzz tests; the supplied seed is used for local runs.
- Fuzz tests exercise ERC-20 accounting, binary outcome boundaries, exact rank distance arithmetic,
  and payment conservation/funding failures.
- Two stateful invariant assertions exercise interleaved donation and claim actions: 128 runs at
  depth 64 (8,192 handler calls), with unexpected handler reverts treated as failures.
- Offline ABI comparison against the site's published read interface.
- Token runtime scan for DELEGATECALL, CALLCODE and SELFDESTRUCT, skipping PUSH immediate bytes.
- Solidity formatting and deployment bytecode size checks.

The compiler's timestamp warnings correspond to start/end deadline checks, never winner generation.
The exact-balance warning corresponds to rejecting a nonstandard short funding receipt. The bounded
rank loop intentionally rejects invalid zero-tie ranks. These are deliberate checks, not unexamined
warnings. Slither/Mythril, the launch's protected Uniswap integration harness, and a live funded game
interaction were not run. No transaction was signed or broadcast.
