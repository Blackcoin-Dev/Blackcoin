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

- **Legacy stakes in the last blocks of Migration are paid out as quantum coins.** A legacy
  coinstake created at height h can only be spent from h plus the maturity (500 blocks on
  mainnet), and the Final phase rejects every legacy input, so a legacy-return stake made in the
  last 500 blocks of Migration could never be spent. From block height 6,921,499 (one block early, to keep a migration margin: a
  stake at 6,921,499 would mature only in the last Migration block, and from 6,921,500 on it could not
  mature before Final at all) a wallet
  that stakes a legacy kernel pays its principal and reward to ONE quantum output of its own
  instead (the quantum stake return address), with nothing else of value in the coinstake and no
  stake split or donation output. The legacy key still signs the block, in the usual zero-value
  output, so every released version accepts these blocks; no consensus rule changes. The stake
  weight shown matches. A quantum return can stake again when it is 500 blocks old: the first one
  (made at height 6,921,499) in the last Migration block (6,921,999), any later one from the first
  Final block (6,922,000) on. Legacy coins that never win a stake stay legacy and must still be
  migrated before Final. The return address is saved in the wallet (a new `quantumstakereturn` record that
  older versions skip). A fully unlocked wallet picks it by itself from an existing quantum address
  (or, only with `-qqallowautokeycreation`, makes one); `setquantumstakereturn` sets it explicitly.
  A wallet unlocked for staking only cannot create a key, so the address must exist before the
  window opens; if none is ready the wallet does not stake legacy coins in the window and says so.
- **The wallet says so, early.** `getstakinginfo` now reports `legacy_staking_scheduled`,
  `legacy_staking_last_height`, `legacy_staking_blocks_remaining`, `legacy_staking_stopped`,
  `legacy_migration_end_height`, `legacy_staking_window_start_height`, `legacy_staking_in_window`,
  `legacy_staking_pays_quantum`, `legacy_stake_return_ready`, `legacy_stake_return_address`,
  `legacy_stake_return_action` and a plain-language `legacy_staking_notice`; `getmigrationstatus`
  reports the same fields. The Staking page shows the notice. Legacy coins that are not migrated
  before the Final phase starts (height 6,922,000) can never be spent.
- **Large wallets can migrate.** `migratetoquantum` and `migrategoldrushrewards` now build one
  bounded batch per call (new `max_inputs` option; defaults of 400 legacy inputs and 90 payout
  inputs; a batch is always cut to fit a standard transaction). The result lists how many outputs
  remain (`remaining_inputs`, `remaining_amount`, `more_batches`); call again with
  `existing_address` set to the returned destination until `more_batches` is false. A partial batch
  leaves a way to finish only as far as the wallet could simulate it, for the inputs, destination, fee
  assumptions and eligible remainder it saw: once no legacy anchor is left, the confirmed quantum output of the
  earlier batch can anchor and fund the next one (and fund a tail that cannot pay its own fee); its
  value is reported separately as `auxiliary_inputs` and `auxiliary_amount`, never as legacy value
  moved. A batch that would strand the rest is refused before anything is committed or broadcast (the first
  transaction has been constructed by then, and signed on the signed path, and is discarded). `more_batches` false means
  no ELIGIBLE input remains: `excluded_legacy_outputs`, `excluded_legacy_amount` and
  `next_maturity_height` report legacy outputs that were not eligible yet (immature, locked,
  unconfirmed), and the Staking page says so instead of "no legacy outputs remain". The dry run
  now reports the maximum signed size and the exact fee of the real call instead of the much smaller
  unsigned size. The Staking page buttons move one batch per click, reuse the same address for
  the next batch, and say how much remains.
- **A partial migration batch is authorised only when the rest is proven to finish.** Before
  anything is committed or broadcast the wallet simulates every later batch with the planner it
  will use: the actual signed size of spending the earlier batch's quantum output (the anchor and
  fee source of a later batch), the `max_inputs` in force, the fee rate (no lower than this batch's,
  the relay minimum and the wallet's required fee) and the dust limit. It refuses the batch when a
  simulated later batch would have no anchor, would not fit, or could not pay its fee and leave an
  output above dust. The simulation covers at most 512 later batches. When the rest needs more, the
  wallet does not guess: it refuses, and says to raise `max_inputs` or to migrate in smaller
  explicit steps (a tiered destination's outputs cannot anchor a later batch, so an aggregate
  estimate could not prove that anchors last). For a plan that passed, `continuation_batches` and
  `continuation_fees` are those of the simulated batches. `minimum_blocks_to_finish` is only a lower
  bound: the longest chain of later batches that each spend the quantum output of the one before and
  so wait for it to confirm, counting this batch. Batches that do not depend on each other can
  share a block, and nothing here predicts when a migration will finish or promises that it will
  finish before the Final phase. When even that lower bound passes the last Migration block the
  result carries `completion_warning`.
- **The leftover report is an inventory.** `excluded_legacy_outputs` and `excluded_legacy_amount`
  now cover every unspent legacy output the wallet owns that the batch did not move, not only
  what the coin-selection view shows, and `excluded_legacy_by_reason` files each one under
  protected asset (a live RGB seal, never spent automatically), locked, immature, unconfirmed,
  no signer in this wallet, or other. The Staking page says "no other legacy output" only when
  that inventory is empty, and lists the reasons otherwise.
- **The last Migration block is usable.** `migratetoquantum` now includes a coinbase or coinstake
  output that matures exactly in the last Migration block. It used to be one block more cautious
  than the consensus rules.
- **Help text.** `migratetoquantum` says it is the command that protects legacy coins.
  `migrategoldrushrewards` says Gold Rush payouts are already quantum outputs, stay spendable in
  the Final phase, and need no move.
- **Demurrage status.** `getdemurragewalletinfo` keeps `blocks_until_decay` (the end of the
  grace period) and adds `blocks_until_first_reduction`, the number of blocks until the value is
  first actually reduced. The two differ by 729 blocks on mainnet, so `blocks_until_decay` reaching
  zero does not mean decay has started. Before demurrage activates, `blocks_until_first_reduction`
  includes the blocks left until activation. It is absent for an output exempt for good (a
  treasury script or a script demurrage never applies to, before activation as well), for a locked
  output, and when activation is not given by a block height. A young output (in its grace
  period) and an output protected by an attestation are exempt only for now, so they show the
  blocks left until their first reduction.
- **Faster PSBT signing.** Signing a PSBT with many inputs no longer copies the whole PSBT for
  every input.

## Staking readiness for the first Final block

None of these changes alters which blocks or transactions are valid. They change which
outputs the wallet stakes, what it reports, and what it tells the user to do.

- **The wallet stakes an output from the block it matures in.** Consensus accepts a coinbase
  or coinstake output as a stake kernel when the height of the new block minus the height of
  the output reaches the maturity (500 blocks on mainnet), which is the block after the tip at
  which the output is 500 blocks deep. The wallet used to wait one block more, so a wallet
  whose only stakable coin was a coinstake paid exactly 500 blocks earlier did not stake it.
  That matters at the end of Migration: a quantum coinstake payout made at height 6,921,500 is
  a valid kernel for block 6,922,000 (the first Final block), and if such outputs are the only
  quantum stake available, nobody could produce that block. The staking selection, the stake
  weight shown and the forced-kernel path (`checkkernel` with a block template) now use the
  consensus condition. Balances and ordinary spending keep the wallet's existing maturity rule,
  so a coinbase or coinstake still shows as immature in the balance for one block longer than
  it can stake.
- **Quantum stake readiness.** The new read-only RPC `getquantumstakereadiness` reports, for the
  next block and for the first Final block, the quantum outputs the wallet's staker would select,
  their nominal (face) value and their effective value (the kernel principal after any scheduled
  demurrage), and the number and value of quantum outputs it would not select, by reason:
  immature, locked, below the staking minimum, no signer in the wallet's current unlock state (a
  fully locked wallet cannot stake), or another staking rule. A kernel is one whole output, and the
  reserve balance is held back from the staker's whole selected set (legacy outputs included), so
  the report gives `candidate_total`, the `allowed_balance` left after the reserve, and
  `stakeable_outputs`: the outputs whose effective principal fits in it. It never reports a
  fractional "stakeable" amount: a wallet whose only quantum output is 100 coins with a reserve of
  1 coin reports no stakeable output, because the staker would refuse that kernel. The first Final
  block is projected only from a complete height-based schedule (`final_height_known`; a
  time-only schedule has no Final height, countdown or `at_final`), and the projection uses the
  Gold Rush payout lock as it will be then, not as it is at the tip. It also reports the total
  quantum value, the legacy value still to migrate and the state of the quantum stake return
  address. It runs the staker's own candidate scan, not a second implementation, so it follows the
  wallet's real reserve balance, minimum, locks and unlock state. Value counted for the first
  Final block uses current confirmations; unconfirmed outputs are not counted as eligible.
- **A fresh wallet backup after a quantum stake return key is made.** Quantum keys are
  generated at random, one by one, and are not derived from a seed, so a wallet backup made
  before the key was created cannot recover coins paid to it. When the quantum stake return
  address is set the wallet writes a log line, and `getstakinginfo`, `getmigrationstatus`,
  `setquantumstakereturn` and the Staking page notice say so until `backupwallet` has made a
  verified backup that holds the key (`legacy_stake_return_backup_verified` and
  `legacy_stake_return_backup_action`; the readiness report carries the same fields). The
  return key is written to the wallet database, and the address record only after it, before any
  coinstake can pay to it; if either write fails the address is not used.
- **Downgrade.** A wallet that holds the quantum stake return record, a quantum key made for it,
  a migration batch and a quantum-return coinstake opens in v30.1.6 with the same balances,
  unspent outputs and transactions; v30.1.6 skips the record it does not know, and this
  version finds it again when it opens the same wallet. Do not replace a newer wallet with an
  older backup to downgrade: a backup made before a quantum key existed cannot recover it.

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
  lifecycle phase still penalize the sender. A bad signature is punished when its
  verification is reached; an earlier rejection that does not penalize (see the
  attestation check below) can end the admission first.
- The missing-FORKID case is identified by a distinct internal script error
  value reported with the same text as before; no second script evaluation is
  run and no block-height window applies.
- A demurrage attestation whose payload is well formed but names a state that has
  moved, a target that is now locked, or an attestation that came too soon is
  turned away by a cheap check that runs before the ML-DSA signature is verified.
  It is not punished: another attestation for the same key can confirm while a
  peer's is in flight, and a target can become locked in the same way. The check
  looks at the target, the controlling key, the referenced state, the lock state
  and the minimum interval, in the mempool only; a flood of such candidates
  costs no signature verification. In the mempool the signature verification itself now comes
  after the other cheap admission decisions (sequence locks, input value, locks, minimum fee,
  standardness, signature operation count, feerate, ancestor and package limits), for a single
  transaction and for a package. A bad signature on a current state is still rejected and
  penalizes the sender if verification is reached, as does a target the transaction itself spends
  and a key that does not control the target. A target that is not a confirmed unspent coin is
  turned away earlier, as mempool policy, without a penalty. Block
  validation does not use the check and is unchanged: the same attestation in a
  block is still invalid.
- The rejection text of `sendrawtransaction` for a transaction with a single failure is as before.
  A transaction that fails more than one check is reported for the first check it fails, and for a
  transaction with an attestation that order has changed (the cheap checks now come before the
  signature verification), so a different failure can be reported first. The debug message only
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

## Behaviour that changes before the end of Gold Rush

Gold Rush is still running on mainnet and nodes are mining claims. Nothing below changes a
consensus rule or which blocks are valid, and the claim reward, the proof calculation and the
acceptance of a valid manual claim are untouched. These are the remaining differences a node
operator can see before the last Gold Rush block (height 6,192,999), in plain language:

- **Staking a coinbase or coinstake one block earlier.** The staker takes such an output as a
  kernel from the block it matures in, one block earlier than before, as consensus already
  accepts it. This changes which kernels the wallet tries now. Balances and ordinary spending keep
  their old maturity rule.
- **Claim input selection is unchanged.** The stake reserve that keeps your largest stakeable
  legacy coins out of claim fee-input selection keeps the wallet's own maturity rule, so which
  coin is reserved and which coin a claim spends is exactly what 30.1.6 did. The only coin the
  staker now sees one block earlier is the one exactly at maturity, and the claim selector cannot
  spend it yet, so the staker and the claim miner cannot contend for it.
- **The quantum stake return address is not prepared by itself before Gold Rush ends.** The
  wallet's own maintenance saves a return address (or, with `-qqallowautokeycreation`, creates a
  key) only once the next block is above the last Gold Rush block and only for a wallet that
  holds legacy coins the staker could stake that it owns and can sign for. No key, saved record or
  backup prompt appears from this preparation before that. (Other automatic maintenance is not
  changed by this: with automatic redelegation and automatic key creation enabled, the redelegation
  scan records its last scanned height, and the same-height reorganisation rescan of automatic
  attestations and Gold Rush signals can reach the existing automatic signal path, which under the
  existing consent settings can create a payout key and ask for a backup.) The `setquantumstakereturn` command works at any time; calling it can create a
  key and changes the saved choice, and it reports `created` whenever a key was made, including by
  its automatic path.
- **New status fields and commands exist now.** `getquantumstakereadiness`,
  `setquantumstakereturn` and the `legacy_*` status fields are available before the end. The
  readiness report is read-only and short: 0.01 to 0.05 seconds on a wallet with 20,000 legacy
  outputs, and 0.07 seconds (0.12 seconds once demurrage is active) on a wallet with 20,000 quantum
  outputs. It holds the chain and wallet locks for that time, which is shorter than
  `getdemurragewalletinfo` takes on the same wallet (0.2 to 0.27 seconds), so it is not sliced.
- **A backup prompt appears for the return key** once one is selected (by the explicit command
  before the end, by the wallet itself after it). It never blocks staking.
- **Automatic Gold Rush signal and attestation rescans** react to competing blocks at the same
  height and are rate-limited across a run of reorganisations, so the timing of a fee-paying
  automatic signal after a reorganisation can differ from before. An automatic demurrage attestation
  reuses a pending wallet attestation for the same key and state instead of signing another.
- **Claim maintenance and the miner** check the Gold Rush window; before the last Gold Rush block
  this does nothing. An explicit `setpowmining` records the consent and cancels a queued automatic
  restart.
- **Mempool rejection classes.** Premature lifecycle transactions, and demurrage attestations that
  are stale, locked or too early, are rejected without the usual penalty for the sender. They are
  still not accepted, relayed or mined.
- **Migration planning** builds bounded batches and reports the inventory, the continuation plan and
  the reasons described above. Actual migration of legacy coins stays refused until Gold Rush ends.
  Planning counts an output that matures in the next block as movable.
- **Less database and index work** while loading a wallet and recording spends, and no stake weight
  refresh in the Qt window; PSBT signing no longer copies the PSBT per input.

## Known limitations

- **Quantum transaction hex without the witness.** `getrawtransaction` and `gettransaction` return
  the transaction without its witness under the default `-rpcserialversion=0`, so the hex of a
  quantum transaction (about 137 bytes for a one-input transaction against about 3,880 with the
  witness) is not broadcastable as returned. This predates 30.1.7. Start the node with
  `-rpcserialversion=1` to get witness-inclusive hex; the `send` family already returns the full
  signed form. The default is not changed in this release.
- **`getstakinginfo.weight` is a cached value.** It is the weight of the last completed staking scan
  and stays at that value when staking is switched off. It is not the weight the staker would use
  now; `weight_cached` and `weight_cache_height` say how old it is. Use `getquantumstakereadiness`
  for the current figures. This predates 30.1.7.
- **`send` does not fall back to legacy inputs during Migration.** For a quantum recipient,
  `sendtoaddress` and `sendmany` retry with legacy inputs during Migration when quantum inputs
  cannot pay. `send` does not: a wallet funded only with legacy coins gets `Insufficient funds`
  from it while a migration transaction is permitted. Use `migratetoquantum`, `sendtoaddress`, or
  select the inputs explicitly. This is unchanged from 30.1.6.
- **Automatic demurrage attestation in a very large wallet can slow other loaded wallets.** This
  applies only after Final, and only to a node started with `-qqautodemurrageattest=1` (it is off
  by default) that has an unlocked wallet with staking on. In a very large wallet (tens of
  thousands of outputs with many keys due) a pass of the automatic attestation can delay RPC calls
  to the other loaded wallets, and some node calls that need the same locks, for several seconds.
  It happens roughly once a minute while due work remains, and the first pass after the node
  starts can take longer. Each wait is the sum of repeated short holds of the wallet and chain
  locks, so the longest single hold is not a limit on how long a call can wait. Leave the option
  off and attest with `senddemurrageattestation` if the delay matters.
- **A pass of the automatic attestation is bounded.** One pass makes at most 16 submissions and
  at most 16 failed attempts, so at most 32 attempts, however many keys are due and however many
  fee inputs the wallet holds. A key that fails for a reason another fee input cannot cure (the
  target is unconfirmed or locked, the state is stale, the attestation is too early, or the target
  conflicts with a transaction that is not the fee input) is not retried through its other fee
  inputs in that pass. Keys the pass did not reach come first in the next pass, so a few keys that
  keep failing cannot starve the others. The wallet file is not changed by this.
- **Attestations choose a confirmed output.** The attestation of a key names an output of that key
  that is in the confirmed chain: the output that made the key due when the automatic path asks,
  otherwise the lowest-sorting confirmed output that is not locked. A trusted but unconfirmed
  output of the same key (change, for example) is never chosen, because the mempool refuses an
  attestation whose target is unconfirmed. The manual `senddemurrageattestation` follows the same
  rule: for a key that has only unconfirmed outputs it fails at once with the existing message
  "Demurrage attestation requires a live wallet UTXO controlled by this quantum key" instead of
  building a transaction the mempool refuses.
- **Downgrade.** A wallet written by 30.1.7 opens in 30.1.6 with the same balances, unspent outputs
  and transactions, and 30.1.7 finds its quantum stake return record again. 30.1.6 does not know the
  late-Migration policy: do not use 30.1.6 to stake legacy coins in the last Migration window (from
  height 6,921,499). A legacy return created at 6,921,499 matures at 6,921,999, the last Migration
  block, so it has only that one block (the margin) to be spent before Final; a return created from
  6,921,500 on matures too late and can never be spent. Switch legacy staking off from height
  6,921,499, or stay on 30.1.7.
