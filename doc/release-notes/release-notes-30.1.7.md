# Blackcoin Core 30.1.7

Blackcoin Core 30.1.7 follows 30.1.6. It is an efficiency and cleanup release on
the wallet and node side, with clearer behaviour around the migration to quantum
outputs, the Final phase and the end of Gold Rush.

Consensus and reward rules, activation heights, the wire protocol and the wallet
file format are unchanged. None of the changes below alters which blocks or
transactions are valid. A wallet file written by 30.1.7 stays readable by 30.1.6
and earlier.

## Wallet load and cleanup

- Loading a wallet builds the indexes of live unspent outputs once, instead of
  once per transaction and again after the load. The result is the same as before.
- The wallet no longer creates a database batch for a spent input unless the coin
  is locked.
- The unused stake weight refresh was removed from the wallet model and from the
  wallet, interface and chain functions that only it used. The staking weight
  shown in the window is unchanged.

## Migration and the Final transition

- **Legacy staking stops before it can lose coins.** A legacy coinstake created at height h can
  only be spent from h plus the maturity (500 blocks on mainnet), and the Final phase rejects every
  legacy input. A legacy stake made in the last 500 blocks of Migration therefore could never be spent.
  The wallet now stops creating legacy stakes after block height 6,921,498 (the last block whose
  output matures before Migration ends, with one block of margin), and the stake weight shown
  matches. Quantum staking is not affected, and legacy coins that stopped staking can still be
  migrated. Blocks made by other wallets are validated exactly as before.
- **The wallet says so, early.** `getstakinginfo` now reports `legacy_staking_scheduled`,
  `legacy_staking_last_height`, `legacy_staking_blocks_remaining`, `legacy_staking_stopped`,
  `legacy_migration_end_height` and a plain-language `legacy_staking_notice`. `getmigrationstatus`
  reports `legacy_staking_last_height` and the same notice. The Staking page shows the notice.
  Legacy coins that are not migrated before the Final phase starts (height 6,922,000) can never
  be spent.
- **Large wallets can migrate.** `migratetoquantum` and `migrategoldrushrewards` now build one
  bounded batch per call (new `max_inputs` option; defaults of 400 legacy inputs and 90 payout
  inputs; a batch is always cut to fit a standard transaction). The result lists how many outputs
  remain (`remaining_inputs`, `remaining_amount`, `more_batches`); call again with
  `existing_address` set to the returned destination until `more_batches` is false. The dry run
  now reports the maximum signed size and the exact fee of the real call instead of the much smaller
  unsigned size. The Staking page buttons move one batch per click, reuse the same address for
  the next batch, and say how much remains.
- **The last Migration block is usable.** `migratetoquantum` now includes a coinbase or coinstake
  output that matures exactly in the last Migration block. It used to be one block more cautious
  than the consensus rules.
- **Help text.** `migratetoquantum` says it is the command that protects legacy coins.
  `migrategoldrushrewards` says Gold Rush payouts are already quantum outputs, stay spendable in
  the Final phase, and need no move.
- **Demurrage status.** `getdemurragewalletinfo` keeps `blocks_until_decay` (the end of the
  grace period) and adds `blocks_until_first_reduction`, the number of blocks until the value is
  first actually reduced. The two differ by 729 blocks on mainnet, so `blocks_until_decay` reaching
  zero does not mean decay has started.
- **Faster PSBT signing.** Signing a PSBT with many inputs no longer copies the whole PSBT for
  every input.

## Transaction relay at the lifecycle boundaries

- A node no longer disconnects or discourages a peer for relaying a transaction
  that was valid one block earlier and became invalid because a lifecycle
  boundary was crossed. This covers a legacy transaction whose signature lacks
  the FORKID flag required from the first Migration block, a legacy-to-quantum
  migration transaction that arrives when Final begins, and a spend whose input
  value, lock state or remaining fee over the minimum changed because of
  demurrage at the next block. The transaction is still rejected and is not
  relayed; only the penalty for the sender is gone. Blocks are validated exactly
  as before, and genuinely malformed transactions, bad signatures, a fee that was
  already below the minimum and every rejection that does not depend on the
  lifecycle phase still penalize the sender.
- The missing-FORKID case is identified by a distinct internal script error
  value reported with the same text as before; no second script evaluation is
  run and no block-height window applies.
- The rejection text of `sendrawtransaction` is unchanged. The debug message only
  states that the transaction conflicts with lifecycle-dependent or demurrage
  rules at the current next-block evaluation point.

## The end of Gold Rush

- A Gold Rush claim that is still unconfirmed when the last Gold Rush block
  (height 6,192,999) connects can no longer confirm. Its funding input used to
  stay reserved with no explanation, so the wallet showed a lower balance and an
  empty `listunspent`. `getbalances` and `getwalletinfo` now carry a
  `closed_claim_reserved` entry while such an amount is held, and
  `getpowclaimrecoveryinfo` and `getpowmininginfo` always carry it. It names the
  amount, the reason and the command that releases it
  (`resolveallshadowpowclaims`). The Staking & Mining page shows the same amount
  and points to Review claim recovery.
- Recovery of such a claim no longer needs the Gold Rush miner to be enabled.
  The existing conflicting recovery transaction can be previewed and committed
  by hand, and a wallet that already chose automatic recovery with a fee budget
  releases the input by itself, still only within that budget, only with a
  normal unlock, and only for claims the closed window left unconfirmable. The
  wallet checks for it at the first block after the end and at every block while
  such a claim remains. Nothing is abandoned or unlocked locally.
- The claim miner stops after the last Gold Rush block. `-powmining` does
  nothing after the end and logs one line, `getpowmininginfo` reports the state
  `gold_rush_ended` and a new field `gold_rush_ended`, and `setpowmining true`
  says that Gold Rush has ended. If a reorganisation returns the chain below the
  end, a miner that was stopped by the end starts again with its settings.
  Nothing changes while Gold Rush is open.
- The hourly advice to consolidate outputs for claim creation is no longer
  logged after the end.
- The resource monitor no longer raises the "outside operational envelope"
  warning on every mainnet node and in the GUI when the chain passes the last
  Gold Rush block. `getshadowresourceinfo` reports the status
  `qualification_expired` with the new fields `qualification_expired` and
  `qualification_notice`; an unreadable measurement, a database that is too
  large and too little free disk space still warn. A full supply scan still needs
  explicit consent after the horizon.
- The automatic Gold Rush signal, the demurrage attestation scan and the
  redelegation scan now remember the block they last scanned, not only its
  height, so a competing block at the same height is scanned too. Retry state
  recorded on a disconnected block is dropped. The wallet file stays readable by
  30.1.6 and earlier; an older record without a block hash means scan again.
