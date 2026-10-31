# Blackcoin Core 30.1.5.3rc1 (DEVELOPMENT, unreleased candidate)

RELEASE_NOTES_NOT_FINAL

Blackcoin Core 30.1.5.3rc1 improves peer discovery, bounds header replay tracking,
and reduces work in mining controls, block-template assembly, and UTXO scans.
This candidate has `CLIENT_VERSION_IS_RELEASE=false`.
Release qualification is pending.

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

The recorded [template benchmark](../release-evidence/v30.1.5.3-template-benchmark.json)
compares the baseline and candidate on Apple Silicon with the same compiler and
optimization, using independent synthetic version-2 transactions. Median assembly
time fell from 92.97 ms to 5.49 ms for 1,000 transactions (16.9 times faster),
and from 19.87 seconds to 69.21 ms for 12,000 transactions (287 times faster).
Each compared workload produced identical template hashes and passed final
validity checks.

These ratios measure template assembly only, using the synthetic fixture above.
The evidence identifies the measured source hashes and build configurations;
overall application performance and release artifacts require separate measurements.

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

## Compatibility and release qualification

The source version is `30.1.5.3rc1`; numeric `CLIENT_VERSION` remains
`300105`.
macOS uses short version `30.1.5`, bundle version `30.1.503`, and
`BlackcoinFullVersion=30.1.5.3` (the base revision). The runtime and configured
package version remain `30.1.5.3rc1`.

This release preserves consensus and reward rules, activation
heights, wire protocol, wallet storage, and chainstate formats. No reindex or
wallet recreation is required by these changes. Back up wallets before
upgrading.

Final qualification remains pending, including native platform artifacts,
pinned Berkeley DB legacy-wallet checks, sanitizers and fuzzing, mixed-version
compatibility, restart and resource soak tests, and reproducible package
comparison. MacBook Air responsiveness and resource measurements are also
pending. Production publication must satisfy the
[release process](../release-process.md).

Windows packages remain without Authenticode signatures. macOS applications use
ad-hoc signatures and are not Developer-ID signed or notarized.
