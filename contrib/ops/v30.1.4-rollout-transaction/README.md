# Blackcoin v30.1.4 exact-32 rollout transaction

This is a staged, fail-closed operations package for the signed public
[`v30.1.4`](https://github.com/Blackcoin-Dev/Blackcoin/releases/tag/v30.1.4)
release at commit `13262151077cce3f72d07d17dc7725b2b6a8e1ab`. Its default actions are
read-only plans. It never starts with reindex flags, parks chainstate, generates
an address, creates a wallet, or authorizes a fee-paying claim resolution.

The typed-gate changes in this package target a **post-release v30.1.4 hotfix
candidate**, not the immutable `v30.1.4` tag. The example environment retains
the immutable release pins as historical evidence only. It is not candidate
rollout authority and must not be edited until CI has produced and attested one
exact candidate source commit, binary hash, image ID, and registry digest. A
candidate starts only when all typed fields are present; a partial typed schema
fails closed and never falls back to the immutable-release predicates.

## Acceptance target

- 32/32 containers healthy, synchronized on mainnet, P2P active, one expected loaded wallet, normally unlocked, and legacy PoS actively searching with positive weight.
- Nodes 1-29 and 31-32: built-in PoW enabled at exactly one thread and one
  percent, coherent stake reserve, no automatic quantum-key creation, and a
  complete safe typed mining gate. The gate requires coherent tips, no mining
  or recovery database ambiguity, zero unsafe claims/components, and one of
  `create_new_anchor`, `wait_for_live`, `wait_for_next_tip`,
  `relay_existing`, or `refresh_same_anchor`. Zero instantaneous hashrate is
  valid for a wait or relay.
- Node 30: regular PoW remains disabled with zero hashrate and a safe typed gate
  because it is the Free Claim wallet; its separate API must be healthy, no
  `.broadcast` marker may remain older than one hour, and confirmed
  recovery-fee totals may not increase during rollout.
- Nodes 31 and 32: wallet-specific Quantum Quasar signal is confirmed, active, unexpired, and recent-solver-qualified in addition to legacy staking.
- All 32 VPN proofs have a valid forwarded port and a unique public IPv4 address. Node and VPN topology, mounts, restart policy, wallet/legacy/quantum identity, configuration, and role manifests remain pinned.
- The final fleet shares one mainnet height, best-block hash, and chainwork, and a fresh supervisor report proves all 32 nodes operational.

## Required order

1. Verify the signed tag and the published Linux x86_64 tarball. The pinned tarball SHA-256 is `8139520add8609aa65bd38e0524b1b55b567d7563969a65db919e4d537e4f20b`; the pinned `SHA256SUMS` SHA-256 is `c969eb048436d809a65d2425927513bef500f7b051149d039901255f3bd32bed`.
2. On the native Linux/amd64 Unraid Docker daemon, source the root-only build environment, create a new root-owned `0700` run directory below `/mnt/pulsar/Blackcoin_Blocks/operations/v30.1.4-image-builds`, and run `image-build/build_release_image.sh`. It requires a native Linux/amd64 Docker server, proves the exact audited base-layer prefix plus one candidate layer, uses `--pull=false` and `--network=none`, and seals the successful result into an exact evidence manifest. The GUI version probe runs the package's shipped `xcb` plugin against the audited base image's Xvfb as the unprivileged `blackcoin` user; it does not assume unavailable `minimal` or `offscreen` plugins.
3. Publish the unique tag with `image-build/publish_release_image.sh` only under exclusive tag-writer authority. It verifies the same-response registry digest, refetches by digest, verifies the remote config blob and all release/binary labels, then emits the immutable `repository@sha256:digest` rollout authority. It does not use a mutable tag for deployment.
4. Install/probe the frozen maintenance-compatible runtime and endpoint guards, then install the no-spend cycle and durable Free Claim pause. Normal installation requires zero existing `.broadcast` entries. The purpose-bound emergency re-pause action is used only for crash containment after a prior authenticated release.
5. Run the node-27 canary against the exact digest/ID/source/binary identity. It retains the fleet Compose entrypoint/command, never resolves claims or authorizes a fee, and preserves wallet/configuration identity without reindex. The rollout accepts only a checksum-complete canary result whose maintenance activation, crash-recovery, guard-identity, launch, release, nonce, and parent-state evidence all authenticate.
6. If read-only preflight finds a stopped node with a failed VPN proof, repair only that stopped node/VPN pair with `repair_vpn_pair.sh`. Each repair proves the other 31 generations unchanged. `recover_clean_guard_stop.sh` remains a manually authorized break-glass path, not a second cron job.
7. Copy `rollout.env.example` to a root-only operator file and fill only the build, canary, and same-lock live-preflight values that are necessarily dynamic. Run `fleet_rollout.sh preflight`; never refresh a pin merely to make a failed preflight pass.
8. Set `CONFIRM_APPLY=v30.1.4-exact-32` and run `fleet_rollout.sh apply`. Waves are `27`, `16`, groups of at most four, node 30 alone, then nodes 31/32 together. Every wave drains claims, cleanly stops, takes cold wallet/config backups and held ZFS snapshots, commits the Compose/policy/guard triplet transactionally, recreates only selected nodes with `--pull never`, reactivates the existing wallet, and gates runtime before continuing.
9. The exact-32 soak takes at least four samples across one hour while both supervisors and Free Claim broadcasts remain durably inhibited. Static checks are reused only for unchanged generations. The first and final samples bind each node's tip, typed action, candidate-state fingerprint, and hashrate. Lack of tip/action/fingerprint/hashrate progress, or a `wait_for_next_tip` action that remains across observed tip progress with no fingerprint/hashrate change, is a separate non-gating warning; it never weakens the typed safety gate or authorizes restart/unlock/spending. After the hour passes, the transaction removes maintenance under endpoint → cutover → PoW-cycle → wallet locks, requires a new exact-32 supervisor observation within five minutes, and only then releases Free Claim last. A post-release audit rechecks all 32 nodes and node 30's API/stale-broadcast gate.
10. After post-release validation, the cleanup transaction releases and destroys only the exact held rollout snapshots. Newer or unrelated snapshots are preserved; rollback falls back to exact-mountpoint `rsync` instead of recursive ZFS rollback whenever newer snapshots exist. Only then may roadmap issues be closed with links to the release, image digest, canary, rollout, soak, finalization, and cleanup evidence.

## Resume and rollback

An interrupted apply leaves the durable maintenance marker and Free Claim pause active. Resume by supplying the same environment, package bytes, wave plan, canary, and `RESUME_RUN_DIR`. The persisted transaction manifest rejects identity drift. Wave preparation occurs in a hidden directory and is atomically published only after its before/candidate evidence is checksum-sealed, so a precommit failure cannot strand resume. A checksum-verified passed wave is not repeated; a safely rolled-back wave receives a new retry evidence directory. An unterminated published wave requires full rollback rather than inference. A finalization failure reactivates both inhibitors; it does not repeat an already authenticated hour-long soak unless the fleet generation or dynamic gate regresses.

Full rollback requires `CONFIRM_ROLLBACK=v30.1.4-rollback` and the original run directory. It processes only waves with proven `passed` evidence in reverse order, restores each prior triplet and pre-upgrade data, recreates those nodes on the prior image, reactivates their existing wallets, and verifies exact-32 VPN/node health and baseline identity. Maintenance is then released first, a newer healthy exact-32 supervisor observation is required, and Free Claim is released last. A rollback that cannot be proved never writes `rolled-back`.

## Role and safety notes

- Docker `on-failure:3` is retained for node containers. Changing it to `unless-stopped` would let a clean endpoint-guard stop bypass the VPN/config proof. The existing endpoint guard is the automatic proof-gated recovery path; `recover_clean_guard_stop.sh` is manual break-glass tooling only.
- The node-30 Free Claim lock is held for stop/recreate/Core validation, then released before the separate service/stale-broadcast gate so the worker can make progress.
- The PoW quarantine-cycle lock is wave-scoped, not held during the one-hour soak. No automatic resolution or fee budget is invoked by this package.
- Unresolved, live, quarantined, blocking, family, and recovery counts are
  retained as evidence. They may be nonzero for a safe same-anchor family and
  are never compared numerically between immutable v30.1.4 and the candidate.
  Prelaunch and first-candidate locked-phase wallet transaction sets must match
  exactly. After activation, permitted PoS and authenticated PoW claims may add
  protocol transactions; confirmed recovery fees and the prohibited recovery
  payment set remain pinned. `mining_gate_can_submit` is always the fresh
  inventory decision;
  only `mining_gate_action` may report an exact cached `wait_for_next_tip`.
- Cold backups and snapshots are rollback evidence, not authority to generate keys, change payout addresses, split coins, spend funds, or replace wallets.

## Local validation

Run `tests/run.sh`. It performs Bash syntax, actionable ShellCheck, exact
wave-plan and renderer fixtures, historical schema-2 preservation, candidate
schema-3 typed-action/fail-closed fixtures, non-gating staleness fixtures,
package-tamper rejection, transaction/rollback/claim-drain/resume invariants,
and forbidden-operation assertions only. It does not contact Docker, GitHub,
Unraid, wallets, or the network. `VALIDATION.txt` and `SHA256SUMS` are generated
only after the targeted checks pass.
