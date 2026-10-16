# Reference provenance

The task's supplied protected token/owner checks and Ethereum security reference were read as task
inputs. They are not copied into this deliverable, imported by its build, or changed. The protected
checks need the separate launch verifier and its generated manifest/configuration; they are not
claimed as locally executed here.

## Hamster Hour

Sources inspected on 2026-10-16:

- [Site](https://hamster-hour-bet-on-the-wheel.sites.imd.fun/): existing IMD betting and pending HAMSTER
  loss rewards motivated adding `HamsterRewards` alongside the requested token.
- [Deployment record](https://hamster-hour-bet-on-the-wheel.sites.imd.fun/imd-deployment.json): Ethereum
  HamsterHour at `0xc5217f129da200a8e86229de4eabf3686eef64b1`, recorded game source commit
  `7ab2a01b3d9a15e2acca8b317e77058e6f2d41e9`.
- [Published ABI](https://hamster-hour-bet-on-the-wheel.sites.imd.fun/abi/HamsterHour.json): full downloaded
  file SHA-256 `818700404c7ab99d31914280820da87c1c829861f6ed64288c14c722fa886232`, matching the site's
  deployment asset hash. The five read functions used here are preserved in
  `reference/HamsterHour.reads.abi.json`. Struct field order is ABI-critical, including unused fields.
- [Site application](https://hamster-hour-bet-on-the-wheel.sites.imd.fun/assets/index-hsWlai-o.js):
  SHA-256 `72ef6a05b77da8c1eb552d8b32bcc897f9c7ec482cc7d1d347215bae452501f2`, also matching the
  deployment record. Its reads and result classification corroborated status values and rank rules.
- Public Ethereum RPC named by the site: `https://ethereum-rpc.publicnode.com` (also
  `https://eth.drpc.org`). Read-only chain checks confirmed chain id 1, nonempty game runtime (20,755
  bytes), and `IMD()` equal to the task's IMD address. These observations establish an interface/address
  reference, not a source-code audit. No settled game windows were returned by `settledWindows()` at
  observation time, so live post-claim position persistence was not empirically tested.

The external game is not deployed, modified, or vendored here. Deployment operators must validate its
implementation and the final address before permanent configuration. Sources may change; the committed
ABI snapshot and this reward implementation will not automatically follow site changes.

## Vendored dependencies

| Dependency | Version | Included material | Archive SHA-256 |
| --- | --- | --- | --- |
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.1.0) | v5.1.0 | ERC20, SafeERC20, Ownable2Step, ReentrancyGuard and their transitive imports; MIT license | `8a3b08cfc756437ba3343901565b18182adb42ec1e621960240a19da5d738686` |
| [forge-std](https://github.com/foundry-rs/forge-std/tree/v1.9.6) | v1.9.6 | `src/` and upstream MIT/Apache license files; tests only | `53d2b498183cb7dc62cf726cc6c1a222ad728b0d87976a877ca1f3ed3707b1c6` |

Archives were obtained from the corresponding GitHub tag archives. No submodule, package-manager
state, or external library link is required. Upstream licenses remain in each dependency directory.
