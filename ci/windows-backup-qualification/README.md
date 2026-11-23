# Windows backup qualification

Manual workflow `.github/workflows/windows-backup-qualification.yml`. It tests the quantum stake return key backup
(`src/wallet/quantum_return_backup.cpp`, `PrepareQuantumStakeReturn` in `src/wallet/staking.cpp`) on a real Windows
runner, with the real MinGW-built `blackcoind.exe` of an unpublished `build.yml` run. It is separate from the pinned PR
gate and from the release build and never publishes anything.

## What it proves

Under a genuine standard (non-administrator) local user, on regtest, with disposable plain and encrypted descriptor
wallets:

| Case | Pass criterion |
|---|---|
| `default-path` | `-quantumkeybackupdir` omitted, datadir in the user's profile: the key activates only after a verified backup; the backup restores in a fresh datadir and holds the same key |
| `mounted-ntfs` | an NTFS VHD mounted inside the network datadir: backup and restore succeed, the files are on the mounted volume |
| `junction` | a junction to another NTFS volume inside the datadir works |
| `subst-drive` | `subst` drive in the child's own session as the datadir works |
| `outside-denied` | an outside path whose ancestors reach `C:\` is refused with an accurate pending error naming `C:\`; the earlier destination is untouched; the same key activates on the default path; a writable test-volume root works |
| `unc-share` | ordinary file creation works through the share first. A UNC value (`\\host\share\...`) is refused when the daemon starts, with "a network or device path is not supported", never with access denied; the generations already on the share are untouched; a second UNC value that names a folder that does not exist leaves nothing behind, at the share or at the local folder `<data directory drive>:\<host>\<share>\...` the value was once mistaken for; the daemon then works on the default path |
| `mapped-drive` | ordinary file creation works first; the backup is refused as unsupported; the key stays pending; existing generations are untouched; the same key activates on the default path |
| `datadir-case` | the data directory and the backup directory under it are spelled in different letter case, in both orders (`-datadir` as created with the backup directory under the case-swapped spelling, and the reverse): the backup directory is below `<datadir>\regtest` (where the product's walk ends), only ASCII letters are swapped, and a spelling that does not name the same folder is classed unresolved, not failed; the backup succeeds and restores, because the walk up from the wallet's directory ends at the data directory by its identity (volume serial number and file index), not by its path text |
| `relative-path` | a drive-relative value (`C:dir`, `C:dir\sub`) and a root-relative value (`\dir`, `/dir`) are refused when the daemon starts, with "relative to a drive or to the root of a drive" (not the network or device message, not access denied); nothing is created in the current directory, the data directory, the drive root or any other folder the value could resolve to; a full path with a drive and a separator, below `<datadir>\regtest`, is accepted and works |
| `long-path` | the per-wallet backup directory (the resolved base, the separator and the wallet's component) of exactly 150 and 149 UTF-16 units, below `<datadir>\regtest`, works end to end (a backup in progress needs 109 more characters below it, 259 in all) and restores on a separate node with a short default path (the restored wallet's own directory would be nine units longer); 151 and 190 are refused when the wallet is created, and 151 when an existing wallet is loaded at startup (the daemon exits with code 1) and by `loadwallet`, with "the path is too long: it has N characters and at most 150 are allowed", the wallet is not made and no folder is created |
| `denied-ancestor` | `icacls /deny` on an ancestor gives an ancestor-specific refusal; after the denial is removed and the node restarted the same key activates |
| `affected-wallet` | the AFFECTED wallet has an active return address and a second key pending; four real generations (written by the daemon, using the `before_activation` crash point) sit in the path that then fails (denied ancestor); the repeated call, a restart and the recovery leave the active address, the full key inventory and every file of the failing path unchanged; only the success prunes, to exactly the newest three |
| `fat32` | FAT32 mounted volume: refused naming the file system although ordinary writes succeed |
| `failcommit` | `-quantumreturnfailcommit=<directory-name>`: the key stays pending, a restart without it activates the same key |
| `crash-points` | the four `-quantumreturncrashpoint` values end the daemon with exit code 7 (`TerminateProcess`; an intentional crash, verified by its code, never counted as a clean shutdown); after a restart the pending or active state is the expected one and the key is recoverable from a backup |
| `flush-probe` | `flush_probe.exe` compiles the real `quantum_return_backup.cpp` with `FlushFileBuffers` shimmed: real success; injected `ERROR_WRITE_FAULT` on a directory handle fails `EnsureQuantumKeyBackupDirectory` with the flush error (leaf and ancestor); the retry on the existing directories succeeds |

Each case writes `case-<name>.json` (name, expected, observed, status, `daemon_error`, relevant `debug.log` lines).
A case whose infrastructure could not be set up (VHD, share, `subst`, `net use`) is `unresolved`; `unresolved` fails
the job exactly as `fail` does. `summary.json` must show every listed case passed.

"Restores and signs" is checked as: the restored wallet owns the address, `dumpquantumkey` returns the same ML-DSA
private key as the wallet that was backed up (key equality, an additional check), and, after unlocking, `backupwallet`
on the restored wallet succeeds. That call runs the daemon's own backup verifier: it stages a copy, reopens it, and with
every quantum key signs and verifies a fresh random ML-DSA challenge before it installs the file. This proves the restored
wallet holds working private key material that signs and verifies. It does NOT show that a transaction is built, accepted
or relayed: no spend is made and no funded chain is used. The same restore and challenge is done after the recoveries of the
refused-path and commit-failure cases, together with `pending == false`, `backup_verified == true` and an unchanged key
inventory.

How the `affected-wallet` state is reached (read from the source): `PrepareQuantumStakeReturn` makes a new key only when no
usable return address is saved, so `allow_new_quantum_key` cannot create a second pending key beside an active address
(`src/wallet/staking.cpp`, the "already saved" return). The state is reached in the other order: a key becomes pending
(crash point `after_key_insertion`), then an existing quantum address is saved with `existing_address`;
`ActivatePendingQuantumStakeReturn` keeps that address when the pending key completes. Each crash at `before_activation`
leaves one genuine, manifested generation and the key still pending.

## What it does not prove

- No power-loss, storage-controller or write-cache claim. A process can be killed and restarted here; a machine
  cannot. Only tested Windows API success, fail-closed behaviour and process-crash recovery are claimed.
- That the MinGW compile and link of the probe works. This stays unresolved until the `flush-probe` job succeeds on the
  runner: a successful link of the probe on a POSIX host (`PROBE_TARGET=native`) establishes nothing about MinGW.
- Acceptance of a transaction signed by a restored key (see above).
- Only the file systems and path kinds above. NTFS on a VHD is not proof about every physical disk.
- It tests the build artifact of one commit; a different commit needs a new run.
- The hosted runner is an administrator with UAC disabled; the standard user is a separate local account created for
  the run. This is a user-level separation, not a sandbox.

## How to run it

1. Build the candidate with `build.yml` (`target: windows-64-bit` is enough), dispatched from a branch whose head is
   `target_sha` (that workflow requires it). Note the run id and the artifact name of the Windows artifact,
   `release-<package_label>-windows-64-bit-<primary|verifier>-<target_sha>`.
2. Dispatch `windows-backup-qualification.yml` from a branch that holds this directory:
   `gh workflow run windows-backup-qualification.yml --ref <branch> -f target_sha=<40 hex> -f build_run_id=<id> -f artifact_name=<name>`.
3. The `flush-probe` job builds `flush_probe.exe` from the sources of `target_sha`. The `windows-backup` job verifies
   that the build run is run `build_run_id` of this repository, belongs to the workflow file
   `.github/workflows/build.yml` (the run's `path` and the id of that workflow), was a successful dispatch with head
   `target_sha`, that the artifact is exactly the three files `build.yml` uploads, that their SHA-256 and the manifest's
   own SHA-256 match the unsigned canary manifest and checksum list of the same run (duplicate entries are rejected),
   the payload and the daemon's embedded identity (`verify_windows_payload.py`), `blackcoind.exe --version`, and the
   probe's hash; then it creates the standard user, VHDs, share and ACLs, runs the child harness as that user within a
   30 minute budget (the process tree is terminated on a timeout), and always uploads the results (plus the live results
   directory as a fallback) and always cleans up. A failed copy of the results, a timeout, a child exit code that cannot
   be read, or a clean-up failure fails the job.

Results: the workflow artifact `windows-backup-qualification-results-<target_sha>-<run id>` (case files,
`summary.json`, `child-identity.json`, `child-profile.json`, `child-whoami-all.txt`, `final-receipt.json` with the
clean-up outcome, `admin-evidence/` with the runner facts, `child-run.json`, partition access paths, volume and ACL
details and `sha256-harness-probe-payload.txt`, `diskpart/` with every diskpart script and its output,
`artifact-verification.json`, `build-run-verification.json`, `build-artifacts.json` (the build artifacts' expiry),
`daemon-version.txt`, the probe's provenance, `tested/` with the exact probe and portable payload that ran and their
SHA-256, `logs/` with each daemon's console output and its full `debug.log`). A daemon that had to be killed after a stop
timeout is recorded in its case file and fails the case. A stop that the harness expects to be clean (every restart of a node) requires that the
process has exited with code 0 and was not killed by the harness: a daemon that crashed, or ended with any nonzero code (a Windows
exception status included), fails the case, whether it had already exited or ended while it was asked to stop. A crash point never counts as a clean stop: `wait_crash` verifies the exact exit code 7, and only `restart_after_crash` starts the
daemon again after it. A startup refusal must end with exit code exactly 1, and its message is read from that start's own output only.

## Files

- `qualify-admin.ps1`: administrator side (user, VHDs through `diskpart /s`, share, ACLs, launch, verdict, teardown).
- `qualify-child.ps1`: runs as the standard user; records `whoami /all`, fails if the token holds the administrators SID in
  any form (deny-only included), is elevated, or has `SeBackupPrivilege`/`SeRestorePrivilege` enabled; sets its profile and
  temporary folders from its own identity, checks them against the profile registered for its SID and proves a temporary
  file can be created; runs the harness.
- `harness.py`: standard library only; `--selftest` tests its pure helpers (and the clean-stop rule with fake processes) on any platform, `--list` lists the cases.
- `flush_probe.cpp`, `build-probe.sh`: the probe and its build (`PROBE_TARGET=native` is a link check on a POSIX host).
- `verify_inputs.py`: fail-closed checks of the run, the artifact names and the hashes (`selftest` included).
