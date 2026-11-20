# Blackcoin Core 30.1.6

Blackcoin Core 30.1.6 is the production release that follows 30.1.5.2. It makes
Gold Rush claims reach the network faster, cuts the work a wallet does for every
block, shortens start-up and restart on large wallets and on hard disks, and
keeps the window responsive with many large wallets loaded. The final source is
RC0 with `CLIENT_VERSION_IS_RELEASE=true`.

The work was developed as the candidates 30.1.5.3rc1 through 30.1.5.3rc15 and
one 30.1.6 release candidate. None of them was published, and no `v30.1.5.3`
tag exists. Everything below is relative to 30.1.5.2.

Consensus and reward rules, activation heights, the wire protocol, and the
wallet and chainstate formats are unchanged.

## Measured results

Fleet figures come from 32 mainnet nodes on one host: 21 on NVMe storage and 11
on hard disks, each with one wallet of about 130 MiB and 138,000 transactions.
MacBook Air figures come from one observing node with 32 such wallets loaded.

| What was measured | Before | 30.1.6 |
|---|---|---|
| Time for a node's own claim to reach four other nodes, median | 5.2 s | 0.36 to 0.50 s |
| The same, slowest claim seen | 6.8 s | 1.5 s |
| Claims landed per block, whole network, mean | 29.0 | 29.1 |
| Restart of a hard-disk node until it mines again | about 2 hours | about 4 minutes |
| Wallet check stage at start-up on a hard disk | 103 s | 10 s |
| Start after a crash, payout blocks checked again | 67,068 (30.8 min on a hard disk) | 0 (17 ms) |
| Start after upgrading from 30.1.5.3rc15, payout blocks checked again | not applicable | 0 of 67,278 (18 ms) |
| MacBook Air, 32 wallets, launch until the window is ready | not measured | 136 s |
| MacBook Air, 32 wallets, first balance on every wallet | not measured | 2 min 44 s |

- "Before" is the fleet on an earlier candidate, not 30.1.5.2: 30.1.5.3rc13
  for propagation, restart and crash recovery, and the stage before the
  read-ahead for the wallet check. No 30.1.5.2 node was measured.
- The propagation figures are eight claims from one node before, and 29
  claims from each of two nodes on the 30.1.6 release candidate, observed on
  four other fleet nodes. The two nodes gave medians of 0.36 s and 0.50 s. One
  claim from each node was not seen on two of the observers within 12 seconds,
  in a block interval where two competing blocks arrived; those two claims are
  not in the figures.
- Claims landed per block is the count each node logs when it evaluates a
  block, over 8 hours on 30.1.5.3rc13 and over 215 blocks in 4 hours with all
  32 nodes on the 30.1.6 release candidate. In the 4 hours, 184 of 215 blocks
  carried 29 or 30 claims, three carried 31, and two carried 12 and 4. The
  difference from 29.0 is within the hour-to-hour variation. The fleet is only
  part of the network.
- The crash figures are from an offline copy of a hard-disk node, killed twice
  without a clean stop. The first start after a crash on data written by an
  older version is the 30.8 minute case; see Known limitations.
- The Air figures are single runs. "First balance" is counted from the window
  appearing.

The recorded [template benchmark](../release-evidence/v30.1.5.3-template-benchmark.json)
compares 30.1.5.2 and this source line on Apple Silicon with the same compiler
and optimization, using independent synthetic version-2 transactions. Median
assembly time fell from 92.97 ms to 5.49 ms for 1,000 transactions (16.9 times
faster), and from 19.87 seconds to 69.21 ms for 12,000 transactions (287 times
faster). Each compared workload produced identical template hashes and passed
final validity checks. These ratios measure template assembly only, using the
synthetic fixture above.

## Gold Rush claims

- A Gold Rush claim is announced to peers at once instead of waiting for the
  random announcement timer. A claim that this node's own miner created is also
  sent to peers as a whole transaction, so they do not have to ask for it.
- The fee filter sent to peers is no longer rounded above the minimum relay
  fee. Rounding made some peers decline to announce minimum-fee claims.
  The claim fee itself is unchanged: claims pay the minimum rate.
- The built-in miner wakes on a new tip and when the mempool drops its live
  claim, searches 512 hashes per loop instead of 128, and its workers stop as
  soon as one of them finds the proof.
- The CPU setting is spent work first. After a new block each worker may use a
  full core for a bounded burst and then settles to the configured duty cycle,
  carrying the debt forward. See `-powminingcpu` below.
- A wallet's own transactions go back into the mempool as soon as the chain
  allows, with a back-off on retries.
- Staking shares its candidate selection and kernel inputs between the slots
  of one tip and scans only outputs that can stake. Any stake found is still
  checked in full before it is signed.

## Wallet work per block

- A block that changes no wallet record costs no database commit, and a
  submitted transaction costs one commit. Earlier versions wrote and synced on
  every block for every wallet.
- Connecting a block visits only the unconfirmed proof records, keeps the
  payout digest up to date incrementally, and builds the block locator once per
  block instead of once per wallet.
- A block disconnect no longer walks every coinstake or the whole lifecycle
  memo.
- Transaction metadata is held packed in memory, and per-claim index membership
  is kept on the transaction record.
- The SQLite connection has a 16 MiB page cache. Database reads no longer
  trigger LevelDB compaction.

## Start-up, restart and crash recovery

- The block index files and the wallet file are read once, in order, before
  they are loaded, so a hard disk is not read in small pieces
  (`-blockindexreadahead`, `-walletreadahead`).
- Start-up runs the quick SQLite integrity check. The full check follows in the
  background, one wallet at a time, and raises a warning if it finds damage
  (`-walletfullcheck` restores the old order).
- Gold Rush payouts that were already authenticated are not authenticated again
  at every load. The wallet stores a payout checkpoint at its tip and another
  at the last chainstate flush, so a crash does not force a full re-check.
- A checkpoint written by an earlier trusted version, from numeric version
  300105 on, is honored. Without this the version change to 300106 would have
  forced a full re-check on every upgrade.
- The wallet persists its best block per connected block and, when it attaches,
  rescans from the lowest block it had marked inactive and abandons its own
  coinstakes of lost blocks.
- The log states what each load made of each checkpoint, how long each load
  phase took, and why any saved mempool transaction failed to load.

## Balances

- Display balances for all wallets are calculated by one background worker in
  short slices that give way to block processing. The window reads the
  published result and never calculates on its own thread.
- `getwalletinfo`, `getbalances` and `getbalance` return the last calculated
  balance at once and say whether it is exact, so polling never waits on a busy
  node. Pass `exact`, or set `-walletrpcexactbalance`, to wait for an exact one.
- A balance that is behind the chain is labelled as behind.

## Window responsiveness

- macOS reopen handling restores a minimized main window before activating it.
  Hidden and minimized pages pause display work and resume on visibility events.
- History filtering, sorting and publication proceed in bounded work slices.
  Stable row identities preserve selections through live changes. Overview keeps
  an independent five-row preview, and source loading or failure remains visible.
- Account rendering and filtering use bounded work slices over the cached wallet
  snapshot. Wallet snapshot and history preparation support cancellation while
  waiting for locks and between expensive operations.
- Application shutdown drains background UI workers without blocking the GUI
  event loop. Recovery results remain owned through completion messages.
  An individual wallet unload can still wait for active worker work to finish.
- Staking display estimates run in the background with a 512-header bound and
  current-tip validation.
- Block-tip notifications to the GUI are coalesced in every synchronization
  state. Catching up after the node has left initial block download no longer
  delivers one GUI update per block, which stalled the window for seconds.
  The synchronization overlay evaluates the current time once per update.
- The wallet worker object is destroyed only after its thread has exited,
  closing a rare crash during wallet unload and shutdown.
- Optional `-uiperflog=<absolute-new-file>` records GUI event-loop timer lateness.
  It is disabled by default and does not measure input-to-paint latency.

- macOS App Nap stays off through initialization, synchronization, staking and
  mining.
- A wallet's history is read only when that wallet is shown, in chunks, and an
  Overview loading state is shown meanwhile. A busy hidden wallet gives its
  turn to the wallet being shown.
- Optional `-uipaintlog=<absolute-new-file>` records Qt event to paint-handler
  completion. It is disabled by default and is not display latency.

- Wallet balance display uses one active worker request and retains the latest
  pending update. A completed snapshot can publish while newer wallet changes
  await another poll. Recoverable failures retain the last valid display and
  release the active request. Hidden Send pages no longer scan family balances;
  visible pages use the existing authoritative coin-selection policy.
- Account Refresh reads a cancellable snapshot on the wallet worker. Filtering
  and search use the completed snapshot without another wallet scan. Busy reads
  cannot become an empty result. Switching wallets or enabling privacy clears
  the old display immediately, and export validates the selected snapshot after
  the save dialog. A backend call already running can still delay wallet shutdown.
- Initial wallet history is prepared off the UI thread and published in chunks
  of at most 256 rows. Live updates are replayed before search and export can
  treat that history as complete. A recent-transaction click during loading is
  retained for selection after completion. The full History model can still
  perform an initial sort when attached.
- Overview exposes five recent transactions through a bounded projection of the
  existing sort/filter model. Changes below those rows no longer require a
  row-hiding loop over the full wallet history. Transaction clicks still refer
  to the authoritative history model.
- Peer statistics refresh on entry to Peers and periodically while that tab is
  visible. Hidden windows and the Console/Network Traffic tabs stop that timer.
- Background staking checks whether its wallet already searched the current
  time slot and chain tip before selecting mempool packages. A missed wallet
  try-lock follows the original path. The late eligibility check, per-wallet
  search state, explicit calls and forced-kernel paths remain in place. A skipped
  retry leaves the reported last-template statistics unchanged.
- Forward block processing can reuse the authenticated predecessor proof-bucket
  coins read during that same transition. The cache belongs to the exact view,
  block and ancestors; the current bucket is read from the updated view. Startup,
  audit and undo checks retain fresh reads.
- Payout inventory accumulators update in their original order and serialize
  once after the claim loop inside the existing staged transaction. Block and
  undo writers reuse their reservation's payload size. State serialization,
  disk framing and undo checksum calculation remain unchanged.


## Peer discovery and header replay tracking

- Automatic outbound connections prefer responsive Quantum Quasar (QQ) peers
  with validated current-chain header evidence and a matching ping response.
  The default target is half the full-relay capacity: eight of the usual
  sixteen slots. `-qqoutboundtarget=<n>` sets the preference; explicit values
  clamp below full capacity, zero disables pursuit, and negative values are
  rejected at startup. Advertised services alone do not qualify a peer.
- Replacement probes have a 120-second deadline and bounded candidate selection.
  A replacement must qualify before an existing peer is retired. Pursuit shares
  connection opportunities with other outbound tasks and requires spare probe
  capacity. `getnetworkinfo` exposes the target, qualified-peer deficit,
  constraints, and discovery counters in `qqoutbound`.
- DNS discovery can retry after an outbound outage or QQ peer deficit, with a
  30-minute cooldown plus jitter. Discovery respects disabled networking,
  automatic-connection settings, DNS seeding settings, and proxy/network
  restrictions. Seed results remain discovery hints; availability and peer
  qualification depend on the remote service.
- Header replay tracking retains at most 2,000 heights per identity and 1,024
  identities, with 64 identity slots reserved for locally initiated peers.
  Reconnect history expires after one disconnected hour. Startup rejects
  `-headerspamfiltermaxsize` outside 0 through 2,000 and negative
  `-headerspamfiltermaxavg` values.

- A bounded HTTPS directory supplies peer hints on mainnet (`-httpsseed`), with
  the same proxy and network restrictions as DNS seeding. Hints for 30.1.x
  peers that the directory verified get a guaranteed dial turn.
- A node behind a changing port forward can advertise its current public
  address and port from a file that an external process keeps up to date
  (`-publicendpointfile`, `-publicendpointmaxage`).
- A P2P listen bind that fails with "address in use" is retried for a short
  time. The log states why a peer was lost and why dials fail.

## Mining controls and template assembly

- Expensive mining controls and staking/mining detail refreshes run on the
  wallet worker thread with cooperative cancellation. Wallet-scoped consent
  and unlock requirements remain enforced.
- Explicit normal-unlock actions read current wallet encryption state so a
  delayed display update cannot suppress the passphrase prompt after a
  staking-only unlock. Cancellation preserves the restricted unlock preference.
- PoW worker-count and duty preferences persist independently of autostart.
  Duty accounting covers the whole worker iteration, including template and
  claim preparation. `getpowmininginfo` reports aggregate hashrate and worker
  hashing/error counts. The percentage sets a per-worker active-work duty
  target; host-wide CPU use depends on the workload and worker count.
- `getpowmininginfo.duty_cycle` reports measured active and wait time for each
  worker, separating completed periods from interrupted periods. Successful
  hash counts identify periods containing proof work. The bounded counters
  reset when a worker group starts and remain available after it stops.
  Durations use wall time from a steady clock; they do not measure thread CPU
  time or electrical power.
- Block-template assembly retains selected outputs and spends in an overlay
  for each package-selection pass, avoiding repeated reconstruction of selected
  transaction state. Rejected packages remain isolated from selected state,
  and final template validity checks remain in place.
- Wallet inventory work checks cancellation before further expensive processing.


## UTXO scans

UTXO statistics capture the database cursor and its block identity together
under the chain lock, then scan the snapshot outside that lock. Cursors retain
the database for their lifetime, and database cache resizing is deferred while
cursors are active. Witness inventory scans check for an obsolete active tip
every 1,024 coins and at scan completion, returning a retry error when the tip
changes. History scans also check RPC cancellation for each record.


## Other corrections

- REST `getutxos` decodes POST bodies directly as protocol bytes, correcting
  binary and hex request handling.
- I2P session-creation errors use the redacted request text so the diagnostic
  does not expose the session private key.
- `getpeerinfo` help identifies `pingtime`, `minping`, and `pingwait` values as
  seconds, matching the existing RPC output.
- Quantum pool calculations revalidate operator commitments against the
  caller's current coins view. Pool queries and wallet operations reuse one
  cold-stake total per operation while checking individual claims and
  commitments against that view.
- Quantum wallet key serialization avoids intermediate plaintext key copies in
  ordinary vectors. Deserialization uses cleansing key material, including on
  error paths, while preserving the database record format.
- PoW workers distinguish local proof errors from completed hashes, report the
  error state, and wait one interruptible second before retrying. Repeated error
  messages are rate-limited to one per worker every 30 seconds.
- Shadow index rewind batches atomically persist undo changes, the custom tip,
  and the restart locator so an interrupted rewind can resume from the same
  committed parent.

- The shadow index reconciles appended records across chain reorganizations.
- The redelegation win history is repaired when a wallet attaches and after a
  zap.

## New options and RPC fields

Options:

- `-blockindexreadahead` (default 1) and `-walletreadahead` (default 1): read
  the block index files, and the wallet file, once in order before loading.
  Each is skipped when the data is larger than a quarter of the memory.
- `-walletfullcheck` (default 0): run the full wallet integrity check before
  the wallet loads, as earlier versions did.
- `-walletrpcexactbalance` (default 0): make the three balance RPCs wait for an
  exact balance when the caller does not pass `exact`.
- `-dbcache=<n>`: the default is now one sixteenth of the system memory,
  between 100 and 1024 MiB, halved when little memory is available, and 450
  MiB when the memory cannot be detected. The chainstate database's own cache
  takes at most 8 MiB of it. An explicit value still wins.
- `-powminingcpu=<n>`: unchanged range and default, but the percentage is now a
  long-run average. After a new block each worker may use a full core for up
  to 10 seconds of proof search before settling to the duty cycle.
- `-qqoutboundtarget=<n>`: preferred number of responsive current-chain QQ
  peers. The default is half the full-relay capacity; 0 disables pursuit.
- `-httpsseed` (default 1): fetch bounded peer hints from the mainnet HTTPS
  directory.
- `-publicendpointfile=<name>` and `-publicendpointmaxage=<seconds>` (default
  180): advertise a runtime public endpoint read from a file in the data
  directory. Off unless the file option is given.
- `-headerspamfiltermaxsize=<n>` now accepts 0 through 2,000, and a negative
  `-headerspamfiltermaxavg` is rejected at start-up.
- `-uiperflog=<path>`, `-uipaintlog=<path>` and `-uipaintcalibrate`: opt-in
  window diagnostics, disabled by default.

RPC:

- `getpowmininginfo` adds `last_claim_timing` (offsets from the tip to gate
  ready, first hash, proof found, mempool acceptance and first announcement,
  and the peers announced to or sent the whole claim within one second),
  `duty_cycle` (measured active and wait time per worker), `workers_hashing`,
  `workers_error`, `legacy_source_output_limit` and
  `legacy_source_outputs_near_limit`.
- `getwalletinfo`, `getbalances` and `getbalance` take `exact`.
  `getwalletinfo` and `getbalances` add `balance_exact`, `balance_height`,
  `balance_blockhash` and `balance_state`.
- `getnetworkinfo` adds `qqoutbound` (target, qualified peers, deficit,
  constraint and discovery counters) and, with the file option on,
  `publicendpoint`.
- `getiocounters` is new: process-wide counts of chainstate reads, database
  reads and wallet commits.
- `getpeerinfo` help now states that `pingtime`, `minping` and `pingwait` are
  in seconds. The values are unchanged.

## Minimum memory

A node needs about 2.3 GB of resident memory before any wallet or cache
setting counts; most of it is the block index. A machine with 2 GB of memory
cannot run this release without swapping. A node with one large wallet needs
more than 4 GB free for the first hour after a start; use 8 GB.

Measured: each fleet node with one 130 MiB wallet peaked at 4.3 to 4.5 GiB
within about five minutes of starting, stayed above 3 GiB for about an hour,
and then settled at 2.4 to 2.5 GiB. Nodes with a small staking wallet peaked
at 3.5 GiB and settled at 2.2 GiB. The
MacBook Air with 32 such wallets used 8.2 to 8.4 GB. Memory per wallet grows
with its transaction count, and a mining wallet gains about two transactions
per block.

## Known limitations

- **First start after a crash on older data.** If a node crashes on data last
  written by 30.1.5.2 or by a candidate before 30.1.5.3rc15, the next start
  authenticates every Gold Rush payout once. On a hard disk with 67,068 payout
  blocks that took 30.8 minutes. Later starts, including after another crash,
  do not repeat it. A clean stop before upgrading avoids it.
- **Downgrade.** An older version does not read the payout checkpoints, so
  going back to it repeats its own full payout check at every load.
- **Chainstate flush checkpoint at real size.** The checkpoint taken at a
  chainstate flush was accepted in the real-size crash test, but no flush
  happened during that test; the record it accepted was written at wallet
  load. The flush path itself is covered by the regtest crash tests only.
- **Balances can trail the chain.** With many large wallets a displayed balance
  can be a few blocks behind, about two minutes, and is labelled as behind
  when it is.
- **First balance on a hard disk.** After a start on a hard disk the first
  balance of a large wallet can take several minutes. Mining and staking do not
  wait for it.
- **Fee filter on older peers.** Peers running earlier versions still round
  their fee filter up. Seven of 24 peers of one fleet node did, and such a
  peer may not pass minimum-fee claims on. The direct send does not depend on
  it.
- **Mining bursts.** With several workers or wallets, the full-core bursts
  after a new block can coincide, so short-term CPU use can exceed the
  configured percentage.
- **Window.** Explicit export and copy, very large selections and an individual
  wallet unload can still block the window briefly. `-uiperflog` measures timer
  lateness, not input-to-paint latency.
- **Mac memory pressure.** On an 8 GB Mac with 32 large wallets, macOS
  compresses most of the application's memory, and a block can then take
  several seconds to show.
- **Packages.** Windows packages remain without Authenticode signatures. macOS
  applications use ad-hoc signatures and are not Developer-ID signed or
  notarized.

## Compatibility

The source version is `30.1.6`; numeric `CLIENT_VERSION` is
`300106`.
macOS uses short version `30.1.6`, bundle version `30.1.600`, and
`BlackcoinFullVersion=30.1.6`. The earlier development candidates of this
source line reported numeric version `300105`.

This release preserves consensus and reward rules, activation heights, the wire
protocol, and the wallet and chainstate formats. No reindex or wallet
recreation is required. Descriptor wallets and pinned Berkeley DB legacy
wallets load as before. Back up wallets before upgrading, and stop the node
cleanly first.

Upgrade and downgrade were exercised in both directions against 30.1.5.3rc13
and 30.1.5.3rc6 on regtest with real Gold Rush payout records, and the upgrade
at real wallet size on an offline copy of a mainnet node.

The source commit and annotated tag are SSH-signed by Blackcoin-Dev.
Publication follows the [release process](../release-process.md).
