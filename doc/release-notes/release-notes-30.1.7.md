# Blackcoin Core 30.1.7rc1 (DEVELOPMENT, unreleased candidate)

RELEASE_NOTES_NOT_FINAL

Blackcoin Core 30.1.7rc1 follows 30.1.6. It is an efficiency and cleanup release on
the wallet and node side, with clearer behaviour around the migration to quantum
outputs, the Final phase and the end of Gold Rush.

Consensus and reward rules, activation heights, the wire protocol and the wallet
file format are unchanged. None of the changes below alters which blocks or
transactions are valid. A wallet file written by 30.1.7 stays readable by 30.1.6
and earlier.

This candidate has `CLIENT_VERSION_IS_RELEASE=false`.
Release qualification is pending.

## Wallet load and cleanup

- Loading a wallet builds the indexes of live unspent outputs once, instead of
  once per transaction and again after the load. The result is the same as before.
- The wallet no longer creates a database batch for a spent input unless the coin
  is locked.
- The unused stake weight refresh was removed from the wallet model and from the
  wallet, interface and chain functions that only it used. The staking weight
  shown in the window is unchanged.
- **Fixed: a newly created encrypted legacy-format wallet could miss incoming confirmed
  transactions.** A legacy (Berkeley DB) wallet created with a passphrase generated its first keys
  after encryption without recording their creation time as the wallet's birth time, so every block
  counted as older than the wallet and a payment to one of those keys that confirmed in a block the
  wallet had not first seen in its memory pool stayed invisible until the node was restarted and the
  missed blocks were rescanned with `rescanblockchain`. The wallet now records the time when it
  creates the keys. This was present in 30.1.6. Descriptor wallets were not affected.

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

- **Legacy self-stakes are paid as quantum coins from 6,917,000, when a return address is ready.**
  Ten maturities before the first Final block (6,917,000 on mainnet; never before the first
  Migration block) a wallet that has a ready quantum stake return address already pays a legacy
  self-stake (a pay-to-pubkey, pay-to-pubkey-hash or bech32 kernel) as ONE positive quantum
  output: all principal, reward and fees, no stake split and no donation output, and the legacy
  key still signs in the zero-value output, so every released version accepts the block. The same
  independent check that guards the last 500 blocks (a refusal if the coinstake has any other
  output of value) now covers every redirected coinstake. Without a ready address the wallet
  stakes legacy outputs exactly as before until 6,921,499, and `getstakinginfo`, `getmigrationstatus`
  and the Staking page notice name the action to take (`legacy_staking_opportunistic_start_height`,
  `legacy_staking_in_opportunistic_window`, and an "Opportunistic return is OFF" line in the
  notice). The mandatory window (6,921,499 to 6,921,999, no ready address means no legacy
  staking) is unchanged. Quantum cold-stake kernels, delegation restrictions, operator payments and
  tier covenants are untouched, and a delegator's principal is never redirected to an operator's
  return address. This is wallet policy only.
- **A final stake reserve keeps outputs for the first Final block.** A quantum coinstake made
  in the last 500 blocks of Migration cannot stake again before the first Final block, so a wallet
  that stakes all its quantum outputs there can have nothing mature when Final starts. For the
  candidate heights 6,921,500 to 6,921,999 (inclusive; released for 6,922,000) the wallet now
  holds back R = min(32, (N + 1) / 2) of its N qualifying quantum outputs, the largest effective
  value at the first Final block first. N counts the outputs that are unspent and will be able to
  stake at the first Final block (a v16 output the wallet holds the key for, or a v14 cold-stake
  output it holds the staker key for, created at or before height 6,921,500, not locked by the
  user), plus those its confirmed coinstakes consumed since 6,921,500, so the reserve does not
  shrink as the wallet stakes. The reserve is recomputed from the wallet and the active chain on
  every staking pass and is never stored (a restart or a reorganisation gives the same answer, and
  nothing is added to the wallet file); the staker leaves the reserve out of kernels and of
  added inputs, and automatic coin selection (an ordinary send, `sendall`, the migration batches,
  the automatic demurrage-attestation fee input and the automatic redelegation) leaves it alone
  and rechecks it before it commits. The commit itself derives the reserve again under the same
  locks the transaction is published under, so a block, a reorganisation or another operation
  after a transaction was built (a payment confirmed in a dialog, say) cannot slip a reserved
  input through: a transaction whose inputs the wallet chose itself and that now includes a
  reserved output is refused with a clear error and leaves no record and no lock. The UTXO
  optimiser (`optimizeutxoset`, with or without a from-address) and the demurrage sweep choose
  their inputs through the same filter. Explicit coin control can still spend a reserved output,
  and `send` and `sendall` then report which reserved outputs were consumed and the reduction of
  the reserve and of the eligibility for the first Final block (`final_stake_reserve_spent`); the
  readiness report shows the reduction as well. The readiness for the next block and the staking
  weight leave the reserved outputs out (an N = 1 wallet inside the guard reports no stakeable
  output now and one at the first Final block; `reserve_withheld_outputs` and
  `reserve_withheld_nominal` say how many and what they are worth), and for the first Final block
  itself, where the guard is released, the eligibility is still reported.
  Equal effective values are ordered by the outpoint's internal byte order (the transaction hash
  as stored, which is the reverse of the transaction id as displayed), then by output index, both
  ascending: a tie does not sort by the displayed id text.
  `getquantumstakereadiness` reports the guard in
  `final_stake_reserve`: whether it is enabled and active, N, the target R, the reserved
  outpoints and their weight, the outputs and weight eligible at the first Final block, any
  shortfall, and what excluded an output (a missing key is told apart from a locked wallet).
  `-finalstakereserve=0` turns it off. A wallet with a single output withholds it for the 500
  candidate heights and stakes it again from the first Final block. Winning the first Final block
  stays a matter of chance. Wallet policy only; no consensus rule changes.
- **A new quantum stake return key is backed up before it becomes the return address.**
  Quantum keys are random, so a wallet backup made before a key existed cannot recover coins paid
  to it. A key made for the legacy-stake return address is now written to the wallet together
  with a pending record (one database transaction, so a crash leaves both or neither), and
  `CWallet::BackupWallet` with key verification (every key reopened and challenged) runs into the
  wallet's backup directory before the key is saved as the return address; the address and the
  removal of the pending record are one atomic write. If the backup fails (an unwritable
  directory, a full disk), the key stays in the wallet as pending, the previous return address
  stays in use, the error is reported, and the same key is retried, by the next
  `setquantumstakereturn`, by the wallet's own maintenance, and after a restart. A pending key
  cannot be used as the return address in the meantime, including through `existing_address`.
  Concurrent callers produce one key, and no backup work is done while the chain or staking lock
  is held. `getstakinginfo`, `getmigrationstatus`, `getquantumstakereadiness`, the Staking page
  notice and the log report the pending key (`legacy_stake_return_pending`, `..._pending_address`,
  `..._pending_error`; `stake_return.pending` and friends) apart from the readiness of the
  active address. A wallet that holds a pending record opens in v30.1.6, which ignores the
  record, and in this version again with the pending state intact. A reused key whose
  verified-backup flag is unset keeps the existing "make a fresh backup" prompt.
- **`-quantumkeybackupdir`.** Where those backups go. The default is
  `<network datadir>/quantum-key-backups/<wallet>/`; with the option, `<dir>/<wallet>/`. The wallet
  name becomes one safe path component (`default` for the unnamed wallet; anything else is `n_`
  and its lower case letters, digits and `-`, every other byte escaped, so no two names share a
  folder, even on a file system that ignores case; a very long name is shortened with a hash of
  the whole name). A file is named `quantum-wallet-<UTC time>-h<height>-<random>.dat` with a
  manifest of the keys it holds next to it, keeps the wallet's encryption, and is private:
  directory 0700 and files 0600 on POSIX. The three newest verified backups are kept, plus any
  older one that is the only backup of a key the wallet still holds. Pruning happens after the
  new return address is durable, never touches a file this feature did not write and never counts
  a failed attempt as a backup.
- **Windows: the backup folder must be on a local NTFS volume.** A new return key becomes active
  only after the backup folder, and every folder above it up to the data directory (or the volume
  root for a folder outside it), has been flushed to disk, and Windows vouches for that flush only
  on a local NTFS volume. The wallet checks the volume of every folder it flushes, and it needs
  permission to open each of them for writing. On a network share, ReFS, FAT32, exFAT or any
  other file system, or when a folder cannot be opened for writing, the key stays pending: the
  Staking page notice, the log and `legacy_stake_return_pending_error` name the folder and the
  reason (for example "the backup directory is on a volume with file system exfat ... use a
  folder on a local NTFS volume"), and nothing is pruned. Point `-quantumkeybackupdir` at a folder on a
  local NTFS disk and run `setquantumstakereturn` again. This Windows code was written without a
  Windows build or test machine and has not been run.
- **A better order for choosing the return address.** With no address saved, the wallet takes, in
  this order: the one `-qqpospayoutaddress`, the wallet's recorded Gold Rush claim payout key (the
  key the claim miner is bound to, the configured `-qqpowpayoutaddress`, or the key its confirmed
  Gold Rush payouts were paid to; an address-book label alone does not identify it), another
  quantum receive address of the wallet (the existing label ranking, then the oldest, then the
  address), and only then a new key, with the existing consent (`allow_new_quantum_key`, or
  `-qqallowautokeycreation`). A key that is already in every old backup is therefore reused before
  one is made. A wallet unlocked for staking only still cannot choose or create a key, and can
  still bind an existing one with `existing_address`.

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
- **Operator note: staking power drops at the first Migration block, and blocks can be slower for a
  while.** This describes the consensus rules as they have always been; 30.1.7 does not change
  them. The last Gold Rush block is 6,192,999 (G). From block G+1 the stake weight of a kernel is
  its value times the liquid multiplier of 2,500 out of 10,000, so liquid legacy stake, including an
  ordinary legacy self-stake, counts at a quarter of its value, and the kernel product is compared
  in full width instead of the wraparound arithmetic used through G. The difficulty target is
  adjusted only from blocks that were produced, and waiting alone does not lower it. If the
  same stakers are online, the first blocks after G can therefore take about four times longer than
  before until the target has followed. Wallets that stake in that window are not at fault and need
  no action; keep them online and unlocked for staking.

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
  Likewise 30.1.6 does not know the opportunistic window (from 6,917,000) or the final stake
  reserve: it pays legacy stakes to legacy outputs in that window, and it stakes every quantum
  output in the last 500 blocks of Migration.
  Record compatibility is not command-line compatibility. `-finalstakereserve` and
  `-quantumkeybackupdir` are new in 30.1.7, and 30.1.6 refuses to start with an option it does
  not know: remove both from the command line and from the configuration file before starting
  30.1.6, and put them back when you upgrade again (the wallet keeps working without them; the
  backup directory then falls back to its default, and the reserve to its default, on). While
  30.1.6 is running it also cannot enforce the pending-key quarantine: it does not know the
  pending record, so it may treat a new quantum key that is still waiting for its first verified
  backup like any other key. Finish the pending backup (`setquantumstakereturn`) before
  downgrading, and do not use a pending key for anything while 30.1.6 runs.

## Version identity

The source is configured as `30.1.7rc1`: major 30, minor 1, build 7, revision 0, RC1. The
numeric `CLIENT_VERSION` is
`300107`. macOS uses short version `30.1.7` and bundle version `30.1.700`, and
`BlackcoinFullVersion` is `30.1.7`. The steps to a signed release are in the
[release process](../release-process.md).
