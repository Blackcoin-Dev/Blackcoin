# Installed-v30.1.4 node30 Free-Claim one-shot

This fleet-only package submits exactly one already-queued node30 Free-Claim
under a separately reviewed owner-only authority. It never starts the recurring
Free-Claim worker, removes the pause marker, enables ordinary PoW, unlocks a
wallet, repairs or rewrites a chain, or deploys software. Normal node30 PoS must
remain active with positive weight throughout. The public Core/release lane is
outside this package.

The runtime is bound to signed installed source commit
`13262151077cce3f72d07d17dc7725b2b6a8e1ab`, tree
`a6f7757c34b70fab841905765462d6769112d049`, and signer fingerprint
`SHA256:jAkpBudDw+ntWHSUx3e1KY+czAFjnlaPxQtRFtptL70`. The one-shot tool also
hash-pins the signed node30 retained-claim primitive that authenticates the
installed container, wallet, chain, PoS/PoW roles, pause artifacts, locks, and
receipt publisher. No live address, outpoint, transaction, runtime identity,
wallet secret, or executable financial authority is checked in.

## Exact scope

`audit` is read-only. Under the complete fleet lock set, it requires:

- the exact healthy installed node30 container and unnamed wallet;
- main chain, peers, no IBD, normal unlock, active PoS, and positive stake
  weight;
- ordinary PoW disabled with zero hashrate;
- zero ambiguous or blocking retained-claim recovery state;
- the exact pause marker, pause wrapper, and preserved original worker hashes;
- the canonical root-owned, manifest-group-owned Free-Claim root at mode 0750,
  ingress queue at mode 0770, and done directory at mode 0750; the queue's
  group-write bit is the intentional API ingress contract, while every other
  mode, group, special bit, symlink, or substituted inode is rejected;
- the exact canonical Unraid storage ancestry: `/mnt/pulsar` and
  `/mnt/pulsar/Blackcoin_Blocks` must remain uid 99, gid 100, mode 0777, while
  the protected boundary at `/mnt/pulsar/Blackcoin_Blocks/operations` must
  remain root:root, mode 0700; every prefix, share, protected-root, pool-root,
  queue, and done device/inode identity is bound without changing the
  intentional user-share permissions;
- exactly one canonical root:root, mode-0644, single-link regular queue JSON,
  no broadcast marker, and a queued payout absent from the awarded ledger;
- a valid direct witness-v16 quantum payout script;
- active unbound QQP2 work for that exact payout;
- the complete exact set of safe, confirmed, wallet-owned legacy P2PKH fee
  inputs eligible for Core's address selector; every member must share one
  exact wallet-owned address and script, and every outpoint, value, script,
  confirmation count, and canonical set digest is bound; and
- a stable active tip, active-chain `gettxout(...,false)` value and script for
  every eligible member, wallet inventory, queue bytes, and work projection.

The audit emits `audit.json` plus its SHA256 sidecar. Its
`required_authority` member is only a template. A human must review the exact
receipt, copy that member to a separate mode-0600 file, change only `decision`
to `authorize`, insert the exact audit SHA256, and supply that authority's
SHA256 explicitly. Every other field must remain byte-for-byte semantic JSON
equal, including the exact queue, payout, fee-input-set digest/count and sole
address/script, active tip, work digest, wallet inventory digest, immutable
queue-file identity digest, user order, fee rate, vsize, fee cap, maximum
tries, and risk acknowledgements. The authority expressly acknowledges that
installed Core cannot pre-bind the selected outpoint and may select any one
member of only that immutable audited set.

`execute` revalidates the complete audit, authority, runtime, wallet selection,
queue, payout, active QQP2 work, complete fee-input set, tip, role, pause
artifacts, and locks. It then immediately re-samples and compares the exact
tip, wallet inventory and txid inventory, and every eligible set member before
it fsyncs a no-clobber `intent.json` ahead of the only wallet-mutating RPC:

```text
sendshadowpowclaim <exact legacy address> <exact queued witness-v16 address> 2000000 100
```

There is no proof-override argument. The call budget is one. The exact RPC
return is fsynced as `rpc-response.json` before any post-call RPC read. The tool
then decodes the exact signed bytes and requires exactly one input that is a
member of the immutable audited set, two exact outputs, same audited
address/script, unbound PoW-mode QQP2 proof bytes for the audited target and
queued payout scripts, exact size 287 vbytes, exact same-script change, and an
independently computed fee of `0.00028700 BLK` (`287 * 100 atoms/vB`) from that
member's immediately re-proved active-chain value minus the signed output.
Multiple inputs, a nonmember input, or a different address/script fail closed.
Only then does it atomically rename the queue item to its `.broadcast` outcome
and publish `broadcast-complete.json`.

`reconcile` is the only permitted continuation after a killed process, timeout,
lost response, malformed response, or unmatched intent. It never invokes
`sendshadowpowclaim`. It serializes under the same locks, revalidates the exact
wallet selection and receipt chain, compares the pre-call wallet txid
inventory, queries every audited set member's spender, loads candidate wallet
bytes, and accepts only one transaction that independently reproduces one
exact member, the sole address/script, QQP2 proof, vsize, and fee. If no exact
transaction is visible, it records an observation and leaves authority
consumed. It never authorizes a retry. If an immediate response receipt
survived, reconciliation heals a missing sidecar and binds that exact
acknowledgment into the completion chain.

`monitor` is read-only with respect to the wallet and chain. It re-proves the
confirmed wallet transaction bytes against the immutable authorized evidence,
separating txid/raw bytes/input/output/proof/fee from mutable confirmations and
blockhash. It requires an active block header and exactly one synthetic payout
record for the exact claim txid, proof output, queued script/address, credited
QQP2 disposition, inclusion height, and exact base fee. Only after that proof
does it atomically append the queued identity to `awarded.txt`, atomically move
the `.broadcast` item to `.confirmed.json`, and publish `terminal.json`.
Mempool presence or a confirmation without the exact indexed quantum payout is
not terminal success.

## Crash and receipt contract

An unknown response consumes authority permanently. The tool never guesses
whether the installed RPC mutated the wallet and never calls it again. Durable
intent, response, completion, observation, and terminal receipts are canonical
owner-only JSON files with SHA256 sidecars, fsync, hard-link no-clobber
publication, and secure fixed child names. A valid JSON receipt whose sidecar
was interrupted can recreate only that missing sidecar. A crash that leaves
the publisher's exact same-inode temporary hard link can remove only that sole
recognized second link. Symlinks, an unrecognized hard link, unsafe modes,
non-owner files, malformed JSON, mismatched sidecars, and path escapes fail
closed.

Every receipt also records the complete Free-Claim storage ancestry and its
digest. The separate authority binds that digest. Audit, execute, reconcile,
and monitor reject a different share, protected-root, or device/inode identity
even when the textual path is unchanged.

The ingress directory's gid-100 group-write permission does not extend to the
existing API-produced queue item. That file must remain root:root, mode 0644,
single-link, canonical, and regular. Its bytes, size, device, inode, uid, gid,
mode, link count, and record are reduced to an immutable identity digest in the
authority. Atomic queue-to-done renames preserve that identity; copied,
replaced, relinked, re-owned, or permission-changed outcome files fail closed.

The state transitions are restart-safe:

```text
queued -> broadcast -> confirmed
   |          ^
   +-> uncertain -- read-only reconcile only
```

A crash after intent but before a known response remains consumed and
reconcilable. A crash after the response receipt, queue rename, awarded-ledger
replacement, confirmed rename, terminal JSON link, or JSON/sidecar temporary
link resumes without another send. Fully published broadcast and terminal
receipts are idempotently validated rather than overwritten.

## Installed-v30.1.4 API limitation

Installed v30.1.4 `sendshadowpowclaim` signs, wallet-persists, test-accepts, and
broadcasts before returning. It has no plan/idempotency token, exact-input
selector, caller-supplied maximum-total-fee parameter, or separate sign/commit
phase. Its product-level fee cap is broader than this package's
`0.00028700 BLK` authority. On the audited installed wallet, one target address
can hold multiple eligible fee UTXOs, so the installed RPC cannot truthfully
pre-bind an exact outpoint. The package instead binds the complete eligible set
at one exact wallet-owned address/script, re-proves every member and the wallet
immediately before the call, and authorizes Core to select any one member of
only that immutable set. It then proves the sole signed input is a member and
computes the actual fee from that member's active-chain value and the signed
same-script output. It cannot undo a transaction already broadcast by Core if
those returned bytes use multiple inputs, a nonmember, or violate the narrow
cap. The separate authority therefore acknowledges the exact-outpoint and
installed-API risk expressly. Requiring Core-enforced idempotency, plan-bound
or exact-input selection, or a hard caller fee cap remains a public-product
requirement, not a fleet workaround.

## Controller runtime

The live host has no `/usr/bin/python3`. Never execute this tool through its
portable test shebang. Live commands are accepted only under the audited real
interpreter:

```text
/mnt/user/appdata/projectblackcoin-ops-runtime/cpython-3.12.13-20260510/python/bin/python3.12
```

That file must be root:root, mode 0700, single-link, size 30,846,632 bytes,
and SHA256
`202c17d1671602a4ef1d43e9b2fdbef0769443f37bf5e51f6b603e0b2c27d9d8`.
It must report CPython 3.12.13. The convenience `python3` symlink is not
accepted.

The real Unraid host exposes `/mnt/user` and `/mnt/user/appdata` as uid 99,
gid 100, mode 0777 user-share directories. Those two ancestors are accepted
only at those exact canonical nonsymlink identities and modes; the package
does not require or recommend changing them. `/` and `/mnt` must remain
canonical root-owned prefixes without group or other write. The protected
boundary begins at
`/mnt/user/appdata/projectblackcoin-ops-runtime`: that directory and every
directory below it through the interpreter's parent must remain root:root,
mode 0700, single-link, canonical, and nonsymlink. The tool reads each prefix,
share, protected-subtree, and executable device/inode identity twice, hashes
the exact opened executable, and fails if any identity moves during
validation. The complete controller identity and its digest are included in
every receipt; the separate authority binds the same digest, so a later
invocation cannot resume an audit produced by a different controller path
identity.

Invoke the real binary under the exact isolated environment and `-I`:

```bash
sudo /usr/bin/env -i \
  HOME=/root PATH=/usr/bin:/bin LC_ALL=C TZ=UTC \
  /mnt/user/appdata/projectblackcoin-ops-runtime/cpython-3.12.13-20260510/python/bin/python3.12 \
  -I "$TOOL" <command-and-arguments>
```

The tool requires `isolated=1`, `ignore_environment=1`, `no_user_site=1`,
`safe_path=true`, and exactly those four environment variables. A different
interpreter, the symlink, any drift in the exact Unraid share ancestry or
protected subtree, a different mode/owner/group/size/link/inode, an added
environment variable, or a non-isolated invocation fails before any manifest,
Docker, or RPC operation.

## Operator sequence

1. Create a fresh owner-only run directory and a completed mode-0600 runtime
   manifest from `RUNTIME-MANIFEST.example.json`.
2. Use only the exact controller invocation above to run `audit` once, then
   independently inspect `audit.json` and its sidecar.
3. Create the separate mode-0600 authority exactly as described above. This
   repository contains no live authority.
4. Run `execute` once. If it does not return an exact completion, never run it
   again; use only `reconcile` with the same authority and hash.
5. Run `monitor` until it records the exact active-chain synthetic payout. A
   pending observation is not success.
6. Preserve the complete run directory and its sidecars as the financial and
   operational receipt chain.

Every command requires the exact controller, runtime manifest/receipt chain,
and authority SHA256. Live use requires root and the production Free-Claim
root. The
hash-pinned mock transport is accepted only for nonroot offline tests and can
never substitute for `/usr/bin/docker` in live mode.

## Validation

Run `tests/run.sh` as a nonroot user. The stateful fixture contacts no Docker
daemon, SSH host, wallet, chain, or network. It tests the exact call and
parameters; authority, fee, queue, witness, QQP2, runtime, wallet, role, pause,
lock, exact directory identity/mode/group, and controller-runtime gates;
the exact Unraid uid-99/gid-100/mode-0777 share ancestry, root-owned
mode-0700 protected controller subtree, stable device/inode binding, and
share/protected mode, group, special-bit, symlink, and path-swap hostiles;
the exact uid-99/gid-100/mode-0777 Pulsar share ancestry, root-owned
mode-0700 protected `operations` root, stable device/inode binding, and
storage-share mode, group, symlink, and path-swap hostiles;
the root:root mode-0644 single-link queue-item contract, immutable authority
binding, and wrong-group, wrong-mode, group/world-write, special-bit,
hard-link, symlink, and inode-substitution hostiles;
the complete any-one-of-an-exact-audited-set fee contract, sole
address/script, digest and member binding, immediate pre-call inventory/tip/
wallet resampling, set drift, duplicate outpoint, multiple-address, multi-input,
and nonmember hostiles; independent signed-byte fee proof; immediate acknowledgment
ordering; response corruption and overprecision; process death before and
after wallet persistence and after response publication; no-retry
reconciliation; queue, awarded-ledger, confirmed, JSON, sidecar, and publisher
hard-link crash windows; directory/receipt/authority symlink and path-swap
rejection; special-bit/world-write rejection; confirmed-byte reproof; active
header proof; and exact synthetic payout completion.

This package is offline tooling only. A signed commit is not live financial
authority. A fresh exact audit and a separate exact mode-0600 authorization are
required before any one-shot execution.
