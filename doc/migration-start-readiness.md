# Readiness for the first Migration block

This note is for people who run staking nodes. It describes what the consensus rules do at the first
Migration block on mainnet, gives a calculation you can redo for how slow the first blocks can be, and
lists what to check before and after. Nothing here is a rule change: 30.1.7 does not alter any of it.
Line references are to this source tree.

## What changes at the first Migration block

The last Gold Rush block is height 6,192,999 (G, `nGoldRushEndHeight`, set from
`MAINNET_SHADOW_REWARD_END_HEIGHT` in `src/kernel/chainparams.cpp`). The first Migration block is
6,193,000 (G+1). Several rules switch at that same height:

| What | Before G+1 | From G+1 | Where |
|---|---|---|---|
| Stake weight of an ordinary liquid legacy stake (including a legacy self-stake) | full value | value times 2,500 out of 10,000, rounded down | `src/pos.cpp` 127 to 134, `EffectiveStakeWeight` |
| Stake weight of a tiered quantum stake | not applicable | between 2,500 and 10,000 out of 10,000 of its value, from its program's unbonding period | `src/pos.cpp` 140 to 142 |
| Kernel product (target times weight) | 256-bit wraparound | full width (512-bit) comparison | `src/pos.cpp` 277 to 290 |
| Quantum witness spends and the stake tiers | not active | active | `src/shadow_schedule.cpp` 47 to 66, `src/validation.cpp` 3998 to 4008 |

The effect on timing comes from the first two rows. A node that stakes an ordinary legacy output has a
quarter of the chance per second after G+1 that it had before, if the difficulty target is unchanged.
The target is changed only by the blocks that are produced (`src/pow.cpp` 56 to 94), so the network
cannot react before the first slow blocks exist.

## Expected first interval

Assumptions (all of them):

1. The target spacing is 64 seconds, the target timespan is 16 minutes, so the retarget interval is 15
   (`src/kernel/chainparams.cpp` 109 to 111).
2. The target in force at G+1 is the one that produced normal 64 second blocks from the pre-switch
   stake. The chance per second of finding a block is proportional to target times effective weight, so
   the expected spacing scales as one over the effective weight.
3. Nobody adds or removes stake except as stated. Stake on nodes that are not running a
   consensus-compatible release, or that are offline, produces no valid blocks and counts as gone.
4. The 4-fold figure is an initial expectation. It holds while the target is unchanged and the
   participating liquid stake is unchanged, and it is not a multiplier for later blocks: each block
   moves the target.
5. The numbers below are expected values from a mean-field recurrence (the next expected spacing is
   this one divided by the factor the target just grew by). Real spacings are random and the first
   blocks can be much longer or shorter than the mean. Compact rounding of the target and the limit
   `posLimitV2` are not significant at these sizes and are ignored. Block times are whole seconds.

Let `u` be the share of the pre-switch staking weight that is on upgraded nodes that are online at G+1,
and `w` the average weight factor of that stake after the switch: 0.25 if all of it is ordinary liquid
legacy stake, up to 1.0 if all of it is tiered at full strength. The expected first interval is
`64 / (u * w)` seconds. For ordinary legacy stake on every producer (`u = 1`, `w = 0.25`) that is
256 seconds, the four-fold expectation.

### The retarget rule, as the code implements it

After each block the target is multiplied by `(14 * 64 + 2 * A) / (16 * 64)`, where `A` is the time
between the last two Proof of Stake blocks, counted as at most ten target spacings (`src/pow.cpp` 66
to 94; with interval 15 the rule is `((interval - 1) * spacing + 2 * A) / ((interval + 1) * spacing)`).
A block after exactly 64 seconds leaves the target alone; a block after 256 seconds (four spacings)
raises it by 22/16, about 1.375; a block after 640 seconds or more raises it by at most 34/16, 2.125.
Waiting without a block changes nothing.

### Table

Each cell is the first expected interval, the number of blocks until the expected spacing is within 10%
of 64 seconds, and the time those blocks take in total. The recurrence is run by the unit test
`migration_start_expected_interval_follows_the_retarget_rule` (`src/test/blackcoin_tests.cpp`), which
calls the real `CalculateNextTargetRequired`, so every cell is asserted by code.

| Upgraded and online (`u`) | All ordinary liquid legacy (`w` = 0.25) | Average weight factor 0.5 | Average weight factor 1.0 |
|---|---|---|---|
| 100% | 256 s; 16 blocks; 29 min | 128 s; 13 blocks; 19 min | 64 s; no easing needed |
| 75% | 341 s; 17 blocks; 33 min | 171 s; 15 blocks; 24 min | 85 s; 8 blocks; 10 min |
| 50% | 512 s; 17 blocks; 38 min | 256 s; 16 blocks; 29 min | 128 s; 13 blocks; 19 min |
| 25% | 1,024 s; 18 blocks; 55 min | 512 s; 17 blocks; 38 min | 256 s; 16 blocks; 29 min |

How to read it: with every producer upgraded and all stake ordinary liquid legacy, the expected first
block takes about four minutes, and the expected spacing has come back to within 10% of normal after
about 16 blocks and half an hour. Each producer that is missing at G+1 lengthens the first interval in
proportion (half the producers means twice as long) and adds one or two blocks to the recovery. Below
about a quarter of the pre-switch weight the first interval is over fifteen minutes, one interval can
be a good deal longer than the mean, and the spacing cap of ten target spacings (640 seconds) limits
how fast the target can ease from a single very long block.

### What loss of producers does

A producer that is not running at G+1 does not slow the chain by itself; the effect is the same as the
share `u` being lower. If it comes back during the recovery, the chain speeds up, and the target,
which was raised for fewer producers, then lowers again over the following blocks. While any stake that
satisfies the rules is online and staking, blocks keep being produced, only more slowly the less there
is; the recurrence above shows how quickly the target follows.

## Check on every staking node before G+1

- The node runs a release that implements the Migration rules (30.1.6 or later) and shows the expected
  version in `getnetworkinfo`.
- It is fully synced: `getblockchaininfo` reports `initialblockdownload` false and the tip is recent.
- Staking is enabled and the worker runs: `getstakinginfo` shows `enabled`, `worker_running`, and
  `staking_state` other than `disabled`, `locked` or `error`.
- An encrypted wallet is unlocked for staking only (`walletpassphrase <passphrase> <seconds> true`),
  with a timeout that outlasts the window you intend to watch, or the wallet is not locked.
- It has peers in both directions: `getnetworkinfo` and `getpeerinfo` show several connections, and at
  least one is outbound.
- There are coins that can stake: `getstakinginfo` shows a positive `weight` and `eligible` true.
- The system clock is correct; Proof of Stake block times must not be in the future.

## Watch after G+1, and when to act

- `getblockchaininfo` and `getstakinginfo` (`blocks`, `difficulty`, `expectedtime`, `netstakeweight`):
  the tip should keep moving, slowly at first, and `difficulty` should fall block by block as the
  target rises.
- Expect the first intervals in the table above and treat a single long gap as normal. Act only if the
  tip has not moved for much longer than the table's first interval for your situation (for example
  more than 45 minutes with most producers upgraded), or if your node's tip differs from other nodes you
  trust.
- What to do then: confirm the node is synced and has peers, that staking is enabled and the wallet is
  unlocked for staking, restart the wallet or node only if one of those is wrong, and do not reduce your
  own stake or move coins in a hurry. A wallet that stakes in this window is not at fault.
- Legacy stake that should keep earning can be moved to tiered quantum stake after G+1; that raises its
  weight above the liquid quarter, but it is a separate decision with its own lock period and is not
  required for the chain to continue.

## Tests

The weight and arithmetic switch at G and G+1 is asserted in `mainnet_migration_start_quarters_ordinary_legacy_stake_weight`
(`src/test/blackcoin_tests.cpp`), including the real `CheckStakeKernelHash` at both heights with a
target at which the wraparound and the full-width products disagree. The retarget numbers above are
asserted in `migration_start_expected_interval_follows_the_retarget_rule` in the same file.
