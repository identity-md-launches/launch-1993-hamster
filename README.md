# HAMSTER

HAMSTER is a fixed-supply ERC-20 for [Hamster Hour](https://hamster-hour-bet-on-the-wheel.sites.imd.fun/).
`HamsterToken` mints **1,000,000,000 HAMSTER with 18 decimals** exactly once to its deployment caller.
`HamsterRewards` implements the site's advertised losing-bet rewards by transferring donated HAMSTER
to bettors whose losses are recorded by the existing game. Rewards never mint tokens.

## Contracts and deployment parameters

| Contract | Constructor arguments | Purpose |
| --- | --- | --- |
| `HamsterToken` | None | Name `HAMSTER`, symbol `HAMSTER`, supply `1000000000000000000000000000` base units. |
| `HamsterRewards` | `address hamster_`, `address owner_` | Pass the newly deployed token (`$token`) and the requester's launch owner (`$owner`). |

Deploy the token first, then the reward contract. The token's deployer is the launch factory, so the
factory receives the entire supply. The reward contract's owner is explicitly supplied; it does not
become the factory or the deployment transaction's origin. Neither constructor calls another contract.
The reward constructor takes no game address, oracle, signer, subscription, or guessed launch address.

The token has ordinary OpenZeppelin ERC-20 transfers and allowances, including standard zero-value
transfers and unlimited-allowance semantics. There are no taxes, transfer restrictions, owner, additional
minting, burns, upgrades, or administrative balance controls. Users should approve only the amount they
intend to spend.

The launch process handles the supplied Ethereum economics: 10% to its distributor, 10% to the IMD
pool, and 80% to `0xee2aaa315cf7ed169f93148d30d24af9318dbb66`. The supplied market cap is 888 IMD;
the pool fee is 12500 and tick spacing is 60. These are external factory operations, not token taxes
or allocations performed by these constructors. No HAMSTER is allocated to the reward contract at
launch. The separate manifest step supplies `launch.json`; this project does not create one.

## Bet, lose, receive HAMSTER

The linked site already has an Ethereum betting game. Its published interface supports OVER/UNDER,
SLEEPING/RUNNING, and EXACT guesses in hour-long windows. Betting closes before the window starts.
The existing game, using its signed oracle results, settles winners and pays IMD separately. EXACT uses
the nearest three distinct distances with ties; binary ties to the line and one-sided pools refund.
Unanswered windows can be voided after the game's 48-hour timeout. See the site's current rules before
wagering; this project does not replace its oracle, fees, staking, jackpot, or settlement logic.

The new reward contract reads the game's `window(windowId)` and `position(windowId, account)`:

| Situation | Eligible IMD loss |
| --- | --- |
| Settled, contested OVER/UNDER, result differs from the line | Stake on the losing side |
| Settled, contested SLEEPING/RUNNING | RUNNING stake if result is zero; SLEEPING stake otherwise |
| Settled EXACT, guess outside all three available winning distance ranks | That ticket's full stake |
| Winning ticket, even if its payout is smaller than its stake | Zero |
| Refunded market, equal-to-line OVER/UNDER, or voided window | Zero |
| Unknown, open, or unsettled window | Claim reverts; elapsed time alone does not prove loss |

**Chosen constant:** `REWARD_PER_IMD = 1`: one HAMSTER per IMD of eligible losing stake. Both assets have
18 decimals, so this is exact even for fractional IMD. It is a reward quantity, not a token price or an
IMD reimbursement. It cannot change after deployment. This choice and the per-ticket loss definition
fill in details the brief did not specify.

Eligible stakes are added across markets for each wallet/window. A wallet can win one bet and lose
another; only its losing bets earn HAMSTER. This is **not a calculation of net wallet trading losses**.
An exact ticket with a winning distance earns no loss reward, regardless of ties or payout rounding.
Each wallet/window can claim once. Different wallets and windows have independent claims. Claiming
IMD or a jackpot in the existing game does not itself consume HAMSTER eligibility.

Reward funding is finite and voluntary. Claims succeed only when the contract holds the entire quoted
reward. An insufficient reserve or failed token transfer reverts without consuming eligibility; top up
and retry. There are no partial payouts, reserved balances for future claimants, withdrawal rights for
donors, or claim expiry. A successful claim transfers existing HAMSTER and never changes token supply.

## After launch

1. **Owner: configure the game once.** Call `configureGame(gameAddress, firstWindow)` on `HamsterRewards`.
   Obtain the game address from the site's [deployment record](https://hamster-hour-bet-on-the-wheel.sites.imd.fun/imd-deployment.json),
   independently verify its Ethereum code and persistent finalized records, and confirm its `IMD()`
   is `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`. The observed address was
   `0xc5217f129da200a8e86229de4eabf3686eef64b1`; it is **not hardcoded** into the reward contract.
   Read `currentWindow()` and `windowTimes(firstWindow)` from that game. Choose a window strictly
   later than `currentWindow()` whose start is still in the future when configuration is mined.
   Choose a later window if existing pre-activation bets should not qualify; bet timestamps are not
   exposed by the interface. `GameConfigured` records both settings. Setup is permanent, including
   the first window; no owner can later replace the game or remove eligibility.
2. **Treasury/donors: provide reward inventory.** After configuration, approve an exact HAMSTER amount
   to the rewards address and call `fund(amount)`. Anyone can donate; `Funded` records the amount.
   Direct HAMSTER transfers also increase usable inventory but do not emit `Funded`. Donations are
   irrevocable and no owner can reclaim them. No launch-supply reservation or automatic funding exists.
3. **Site maintainer: add the reward address and ABI to the existing interface.** Show
   `firstEligibleWindow`, `REWARD_PER_IMD`, `rewardFor(windowId, wallet)`, `claimed(windowId, wallet)`,
   and `hamster.balanceOf(rewardsAddress)`. A quote is eligibility, not a promise of reserved funds.
   For eligible settled bets, offer `claim(windowId)`. It needs no token approval. A relayer can use
   `claimFor(windowId, wallet)`; it always pays the named bettor, never the relayer. Listen for
   `RewardClaimed`. The remote site is not modified by this repository.
4. **Game operators: continue existing settlement duties.** Maintain the real-wheel data source and
   oracle availability, settle/void game windows, and preserve the game's final results and historical
   stake records. A failed oracle should lead to the game's refunds, not invented HAMSTER losses.
5. **Treasury/site operators: monitor reserves and abuse.** Advertise the finite inventory honestly and
   replenish it as appropriate. Hedging opposing bets or using multiple wallets can farm losing-stake
   rewards; there is no identity check or anti-Sybil guarantee. Assess incentives against HAMSTER's
   market value before funding. The contract cannot pause or change the rate to correct economics.

Before configuration, game-dependent operations revert `NotConfigured`. The owner can transfer
ownership using a two-step acceptance. Renunciation is prevented until configuration succeeds. After
configuration the owner has no ability to withdraw funds, alter rewards, pause claims, or upgrade code.
There is no additional requester-owned external value left to guess at deployment.

## Trust and scope

The configured game is the source of truth. Its ABI checks are not a proof that its implementation is
honest. The owner must verify the address, immutable finality, status encoding (`2` settled, `3` voided),
18-decimal IMD stakes, rank semantics, and retention of positions after claims. A malicious or later
mutable game could fabricate losses or stop claims. This contract does not independently verify the
hamster's activity or the oracle's signatures. No new randomness mechanism is introduced: outcomes
are real-world measurements settled by the existing game. Tests use an explicit mock, not a production
oracle or a claim to verify that game's full implementation.

The reward contract is designed for the delivered `HamsterToken`, not arbitrary rebasing, taxed, or
callback-enabled assets. It rejects short funding receipts and uses checked token transfers and a
reentrancy guard. Native ETH is not accepted. Accidentally sent other assets have no recovery method.

An independent adversarial review is still required before use with public funds. See
[the local security review](docs/SECURITY.md) and [reference provenance](docs/REFERENCES.md).

## Build and check

Foundry is configured at the repository root with Solidity **0.8.26**, optimizer runs 200, Cancun EVM,
and `bytecode_hash = "none"`. Required OpenZeppelin sources and forge-std are vendored as ordinary files
in `lib/`; no package installation, submodules, network, private keys, or environment reads in tests are
needed. The verifier supplies the pinned compiler.

```sh
forge build
FOUNDRY_FUZZ_SEED=0xb4d78410d7493209a26523e51b0849dcfb0952f026a51260f93cdc6d0f86478a forge test
forge fmt --check
python3 tools/check_game_abi.py
```

The tests cover factory supply ownership, exact token movements, ERC-20 failures, forbidden admin
operations, owner configuration, loss classification, refunds, game-read failures, late settlement,
replays, funding exhaustion/retry, failed transfers and reentrancy. Stateful invariants check fixed
supply, reserve conservation, and one payment per wallet/window across interleaved funding and claims.
The ABI check compares the compiled read interface against a vendored snapshot of the site's ABI.
All deliverable tests are outside `test/scratch/` and run without forks or filesystem permissions.
