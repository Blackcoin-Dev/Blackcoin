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
| `unc-share` / `mapped-drive` | ordinary file creation works first; the backup is refused as unsupported; the key stays pending; existing generations are untouched; the same key activates on the default path |
| `denied-ancestor` | `icacls /deny` on an ancestor gives an ancestor-specific refusal; after the denial is removed and the node restarted the same key activates |
| `fat32` | FAT32 mounted volume: refused naming the file system although ordinary writes succeed |
| `failcommit` | `-quantumreturnfailcommit=<directory-name>`: the key stays pending, a restart without it activates the same key |
| `crash-points` | the four `-quantumreturncrashpoint` values end the daemon with exit code 7 (`TerminateProcess`); after a restart the pending or active state is the expected one and the key is recoverable from a backup |
| `flush-probe` | `flush_probe.exe` compiles the real `quantum_return_backup.cpp` with `FlushFileBuffers` shimmed: real success; injected `ERROR_WRITE_FAULT` on a directory handle fails `EnsureQuantumKeyBackupDirectory` with the flush error (leaf and ancestor); the retry on the existing directories succeeds |

Each case writes `case-<name>.json` (name, expected, observed, status, `daemon_error`, relevant `debug.log` lines).
A case whose infrastructure could not be set up (VHD, share, `subst`, `net use`) is `unresolved`; `unresolved` fails
the job exactly as `fail` does. `summary.json` must show every listed case passed.

"Restores and signs" is checked as: the restored wallet owns the address and `dumpquantumkey` returns the same
ML-DSA private key as the wallet that was backed up. No spend is signed (no funded chain is used).

## What it does not prove

- No power-loss, storage-controller or write-cache claim. A process can be killed and restarted here; a machine
  cannot. Only tested Windows API success, fail-closed behaviour and process-crash recovery are claimed.
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
   that the build run's head is `target_sha`, that the artifact is exactly the three files `build.yml` uploads, that
   their SHA-256 match the unsigned canary manifest and checksum list of the same run, the payload and the daemon's
   embedded identity (`verify_windows_payload.py`), `blackcoind.exe --version`, and the probe's hash; then it creates
   the standard user, VHDs, share and ACLs, runs the child harness as that user, and always uploads the results and
   always cleans up.

Results: the workflow artifact `windows-backup-qualification-results-<target_sha>-<run id>` (case files,
`summary.json`, `child-identity.json`, `child-whoami-all.txt`, `admin-evidence/`, `artifact-verification.json`,
`daemon-version.txt`, the probe's provenance, `logs/` with each daemon's console output).

## Files

- `qualify-admin.ps1`: administrator side (user, VHDs through `diskpart /s`, share, ACLs, launch, verdict, teardown).
- `qualify-child.ps1`: runs as the standard user; records `whoami /all`, fails if administrator, elevated, or if
  `SeBackupPrivilege`/`SeRestorePrivilege` is enabled; runs the harness.
- `harness.py`: standard library only; `--selftest` tests its pure helpers on any platform, `--list` lists the cases.
- `flush_probe.cpp`, `build-probe.sh`: the probe and its build (`PROBE_TARGET=native` is a link check on a POSIX host).
- `verify_inputs.py`: fail-closed checks of the run, the artifact names and the hashes (`selftest` included).
