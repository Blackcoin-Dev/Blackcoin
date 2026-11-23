// Copyright (c) 2026 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_WALLET_QUANTUM_RETURN_BACKUP_H
#define BITCOIN_WALLET_QUANTUM_RETURN_BACKUP_H

#include <util/fs.h>

#include <cstddef>
#include <cstdint>
#include <functional>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <vector>

namespace wallet {

/** A wallet name as one safe path component. The unnamed wallet is "default". Every other name is
 *  "n_" followed by its bytes, where only lower case letters, digits and "-" stand for themselves and every
 *  other byte (separators, dots, upper case, "_" itself, multibyte characters) is "_" and two lower case hex
 *  digits. The prefix keeps a wallet called "default" apart from the unnamed one, and the escape of upper case
 *  keeps names apart on a file system that ignores case. A long name keeps its first 48 encoded characters and
 *  ends in "~" and 32 hex digits of the SHA-256 of the whole name. Distinct names never share a component. */
std::string QuantumKeyBackupWalletComponent(const std::string& wallet_name);

/** Whether a configured backup directory starts with two separators (each `\` or `/`): on Windows a network share
 *  (`\\host\share`), an extended-length path (`\\?\C:\dir`, `\\?\UNC\host\share`) or a device path (`\\.\`). The Windows
 *  build's std::filesystem does not take such a prefix for a root name, so the value would count as relative and be
 *  joined to the data directory's drive, naming a local folder nobody asked for. Pure, so it is tested on every
 *  platform. */
bool QuantumBackupPathHasWindowsDoubleSeparatorPrefix(std::string_view value);

/** The base directory: -quantumkeybackupdir (relative to the data directory) or <network datadir>/quantum-key-backups.
 *  On Windows a value with a double separator prefix (see above) is returned as it was given, never joined to the
 *  data directory; EnsureQuantumKeyBackupDirectory and PruneQuantumKeyBackups then refuse it before touching the file
 *  system. */
fs::path QuantumKeyBackupBaseDirectory();

/** The directory one wallet's backups go to: QuantumKeyBackupBaseDirectory() / the wallet's component. */
fs::path QuantumKeyBackupDirectory(const std::string& wallet_name);

/** Create the wallet's directory (mode 0700 on POSIX, tightened to 0700 when it exists and is wider) and make it
 *  durable: on every call the directory and every ancestor that this feature may have created (up to the data
 *  directory, or the file system root for a directory outside it) are committed to disk, so a name made by an
 *  earlier, interrupted attempt is committed too. Returns false with the reason in error; a directory that cannot be
 *  committed is a failure (the key it protects stays pending). On Windows the directories are flushed through a
 *  directory handle (FlushFileBuffers), and only on an NTFS volume of a fixed local disk, with the file system name and the
 *  drive type both taken from that handle (see QuantumBackupVolumeRejection); that
 *  code is compiled for the Windows target only and has not been run. On Windows a directory whose path starts with
 *  two separators (a network or device path) is refused before anything is looked up, created or committed. */
bool EnsureQuantumKeyBackupDirectory(const fs::path& directory, std::string& error);

/** GetDriveTypeW's results, kept here so the classification below is the same function on every platform. */
constexpr unsigned QUANTUM_BACKUP_DRIVE_UNKNOWN{0};
constexpr unsigned QUANTUM_BACKUP_DRIVE_NO_ROOT_DIR{1};
constexpr unsigned QUANTUM_BACKUP_DRIVE_REMOVABLE{2};
constexpr unsigned QUANTUM_BACKUP_DRIVE_FIXED{3};
constexpr unsigned QUANTUM_BACKUP_DRIVE_REMOTE{4};
constexpr unsigned QUANTUM_BACKUP_DRIVE_CDROM{5};
constexpr unsigned QUANTUM_BACKUP_DRIVE_RAMDISK{6};

/** Whether a Windows volume may vouch for a directory flush. Flushing a directory handle makes the directory's
 *  entries durable only on a local NTFS volume; on another file system, or through a network share, the call can
 *  succeed without doing it. Takes the volume's file system name (as GetVolumeInformationByHandleW reports it,
 *  compared without regard to case) and its GetDriveTypeW value, taken from the root of the same volume as the file
 *  system name (see QuantumBackupLocalVolumeRoot). Returns nullopt when the volume is accepted (NTFS on a fixed local
 *  disk; a removable drive is refused, because a volume that can be unplugged is not one the backup may rest on) and
 *  otherwise the reason it is not, naming the file system. */
std::optional<std::string> QuantumBackupVolumeRejection(std::string_view file_system, unsigned drive_type);

/** The volume root, `\\?\Volume{GUID}\`, of the final path GetFinalPathNameByHandleW(VOLUME_NAME_GUID) reports for
 *  an open directory handle: the root whose drive type is then asked of GetDriveTypeW, so the file system name and
 *  the drive type both come from the one handle. Returns nullopt when the path is not of that form (the volume has no
 *  local GUID path: a network share (`\\?\UNC\...`), a path that names a device or something else, an empty or
 *  truncated answer), and the caller then refuses the directory. Pure, so it is tested on every platform. */
std::optional<std::wstring> QuantumBackupLocalVolumeRoot(std::wstring_view final_path);

/** Tests only: apply (true) or do not apply (false) the Windows rule for a double separator prefix whatever the
 *  platform; nullopt restores the platform's own answer (applied on Windows only). */
void SetQuantumKeyBackupWindowsPathRulesForTest(std::optional<bool> rules);

/** Tests only: replace the commit of a directory (an empty function restores the real one). */
void SetQuantumKeyBackupDirectoryCommitForTest(std::function<bool(const fs::path&)> hook);

/** One file name of a generation: quantum-wallet-<UTC yyyymmddThhmmssZ>-h<height, 10 digits>-<suffix>.dat.
 *  The suffix is 16 lower case hex digits. */
std::string QuantumKeyBackupFileName(int64_t unix_time, int height, const std::string& suffix);

/** Whether name is exactly a file name QuantumKeyBackupFileName makes. */
bool IsQuantumKeyBackupFileName(const std::string& name);

/** A random suffix for QuantumKeyBackupFileName. */
std::string NewQuantumKeyBackupSuffix();

/** The ML-DSA key inventory a backup holds: the witness program of every key. */
using QuantumKeyBackupKeySet = std::set<std::vector<unsigned char>>;

/** One backup generation found in a directory. verified is true only when the wallet file has the exact file
 *  name pattern and a manifest of this feature that names it; only those count as generations. */
struct QuantumKeyBackupGeneration
{
    std::string file_name;
    bool verified{false};
    //! Position in the order the generations were made (from the manifest); larger is newer.
    uint64_t sequence{0};
    QuantumKeyBackupKeySet keys;
};

/** The file names to delete: from the verified generations, keep the newest keep_newest, and keep every older
 *  one that holds a live key none of the kept generations holds (so the sole protector of a key is never
 *  deleted). A generation that is not verified is never chosen. Pure. */
std::set<std::string> SelectQuantumKeyBackupsToPrune(const std::vector<QuantumKeyBackupGeneration>& generations,
                                                     const QuantumKeyBackupKeySet& live_keys, size_t keep_newest);

/** Number of verified generations kept without further reason. */
static constexpr size_t QUANTUM_KEY_BACKUP_KEEP_GENERATIONS{3};

/** The sequence the next generation in directory gets: one above the largest manifest sequence there. */
uint64_t NextQuantumKeyBackupSequence(const fs::path& directory);

/** Durably write the manifest of the wallet file file_name (a generation) next to it, mode 0600. */
bool WriteQuantumKeyBackupManifest(const fs::path& directory, const std::string& file_name, uint64_t sequence,
                                   const QuantumKeyBackupKeySet& keys, std::string& error);

/** Every generation in directory: files and manifests this feature wrote. Foreign files are not listed. */
std::vector<QuantumKeyBackupGeneration> ListQuantumKeyBackupGenerations(const fs::path& directory);

/** Delete the generations SelectQuantumKeyBackupsToPrune names (wallet file and manifest). Only files of the
 *  exact name patterns are ever removed. Returns the number of generations removed. */
size_t PruneQuantumKeyBackups(const fs::path& directory, const QuantumKeyBackupKeySet& live_keys, size_t keep_newest);

} // namespace wallet

#endif // BITCOIN_WALLET_QUANTUM_RETURN_BACKUP_H
