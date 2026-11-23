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
 *  "n_" followed by its encoded bytes. Lower case letters, digits and "-" stand for themselves;
 *  every other byte is "_" followed by two lower case hexadecimal digits. The prefix distinguishes
 *  a wallet named "default" from the unnamed wallet. Encoding upper case letters distinguishes names
 *  that differ only in case on a case-insensitive file system. If the encoded component exceeds
 *  80 characters, its first 50 characters, including the "n_" prefix, are kept, followed by "~"
 *  and a 128-bit truncated SHA-256 suffix: 32 lower case hexadecimal digits representing the first
 *  16 bytes of SHA-256 of the original wallet-name bytes. Long names are distinguished by this
 *  suffix, subject to the possibility of a truncated-hash collision. */
std::string QuantumKeyBackupWalletComponent(const std::string& wallet_name);

/** The names of the folders a backup is made in, below the wallet's backup directory: the staging folder
 *  (CWallet::BackupWallet) is `<directory>\<stage prefix><unique>`, holds `wallet.dat`, and the verification of that
 *  copy (CWallet::VerifyQuantumBackup) makes its own folder `<stage folder>\<verify prefix><unique>` holding another
 *  `wallet.dat`. wallet.cpp builds those names from these constants. */
constexpr std::string_view QUANTUM_BACKUP_STAGE_FOLDER_PREFIX{".blackcoin-wallet-backup-stage-"};
constexpr std::string_view QUANTUM_BACKUP_VERIFY_FOLDER_PREFIX{".blackcoin-quantum-backup-verify-"};
constexpr std::string_view QUANTUM_BACKUP_COPY_FILE_NAME{"wallet.dat"};
//! GetUniquePath's random part: eight random bytes as sixteen hexadecimal characters.
constexpr size_t QUANTUM_BACKUP_UNIQUE_NAME_CHARS{16};
/** What the database code opens next to the verification copy's `wallet.dat` while the copy is open for writing, the
 *  longest of which sets the deepest path:
 *   - SQLite (the wallet uses its default rollback-journal mode, journal_mode DELETE, and never WAL): `wallet.dat-journal`
 *     beside the file, 8 units more than the file;
 *   - Berkeley DB (a legacy wallet): the environment opens in the verification folder with its log directory
 *     `database` and creates `database\log.0000000001` there (and `.walletlock` and `db.log` directly in the folder, both
 *     shorter). With DB_PRIVATE no `__db.*` files are made. */
constexpr std::string_view QUANTUM_BACKUP_SQLITE_JOURNAL_SUFFIX{"-journal"};
constexpr std::string_view QUANTUM_BACKUP_BDB_LOG_PATH{"database\\log.0000000001"};
/** The UTF-16 code units the deepest path of a backup in progress adds to the wallet's backup directory: a separator
 *  and the staging folder, a separator and the verification folder, and then the longer of the SQLite journal beside the
 *  copy (separator, `wallet.dat`, `-journal`) and the Berkeley DB log below it (separator, `database\log.0000000001`). */
constexpr size_t QUANTUM_BACKUP_SIDECAR_UNITS{
    1 + (QUANTUM_BACKUP_BDB_LOG_PATH.size() > QUANTUM_BACKUP_COPY_FILE_NAME.size() + QUANTUM_BACKUP_SQLITE_JOURNAL_SUFFIX.size()
             ? QUANTUM_BACKUP_BDB_LOG_PATH.size()
             : QUANTUM_BACKUP_COPY_FILE_NAME.size() + QUANTUM_BACKUP_SQLITE_JOURNAL_SUFFIX.size())};
constexpr size_t QUANTUM_BACKUP_WORK_PATH_UNITS{
    (1 + QUANTUM_BACKUP_STAGE_FOLDER_PREFIX.size() + QUANTUM_BACKUP_UNIQUE_NAME_CHARS) +
    (1 + QUANTUM_BACKUP_VERIFY_FOLDER_PREFIX.size() + QUANTUM_BACKUP_UNIQUE_NAME_CHARS) +
    QUANTUM_BACKUP_SIDECAR_UNITS};
static_assert(QUANTUM_BACKUP_SIDECAR_UNITS == 24, "the longest file a verification opens is database\\log.0000000001, 24 units below the folder");
static_assert(QUANTUM_BACKUP_WORK_PATH_UNITS == 122, "the deepest path of a backup in progress adds 122 units to the directory");
/** Windows' MAX_PATH counts the terminating null, so 259 UTF-16 code units remain for a path without the extended-length
 *  prefix, which this feature does not use. */
constexpr size_t QUANTUM_BACKUP_WINDOWS_MAX_PATH_UNITS{259};
/** The longest wallet backup directory, in UTF-16 code units, that still leaves room for QUANTUM_BACKUP_WORK_PATH_UNITS
 *  below it: 137. */
constexpr size_t QUANTUM_BACKUP_WINDOWS_MAX_DIRECTORY_UNITS{QUANTUM_BACKUP_WINDOWS_MAX_PATH_UNITS - QUANTUM_BACKUP_WORK_PATH_UNITS};
static_assert(QUANTUM_BACKUP_WINDOWS_MAX_DIRECTORY_UNITS == 137, "a wallet backup directory may be at most 137 UTF-16 units");

/** The length of a UTF-8 string in UTF-16 code units: a character outside the Basic Multilingual Plane counts two.
 *  Pure, so it is tested on every platform. */
size_t QuantumBackupUtf16Length(std::string_view utf8);

/** Whether a configured backup directory is relative to a drive or to the current drive's root, which Windows
 *  resolves against the process's current directory on that drive or against the drive of the current directory, not
 *  against the data directory: a drive letter and a colon not followed by a separator (`D:`, `D:dir`), or one
 *  separator not followed by another (`\dir`, `/dir`, `\`). A drive letter, colon and separator (`D:\dir`,
 *  `D:/dir`) and a path with no drive and no leading separator are not. Pure, so it is tested on every platform. */
bool QuantumBackupPathIsWindowsDriveOrRootRelative(std::string_view value);

/** Whether a configured backup directory starts with two separators (each `\` or `/`): on Windows a network share
 *  (`\\host\share`), an extended-length path (`\\?\C:\dir`, `\\?\UNC\host\share`) or a device path (`\\.\`). The Windows
 *  build's std::filesystem does not take such a prefix for a root name, so the value would count as relative and be
 *  joined to the data directory's drive, naming a local folder nobody asked for. Pure, so it is tested on every
 *  platform. */
bool QuantumBackupPathHasWindowsDoubleSeparatorPrefix(std::string_view value);

/** The base directory: -quantumkeybackupdir (relative to the data directory) or <network datadir>/quantum-key-backups.
 *  On Windows a value with a double separator prefix, or one relative to a drive or to a drive's root (see above), is
 *  returned as it was given, never joined to the data directory; EnsureQuantumKeyBackupDirectory and
 *  PruneQuantumKeyBackups then refuse it before touching the file system. */
fs::path QuantumKeyBackupBaseDirectory();

/** The directory one wallet's backups go to: QuantumKeyBackupBaseDirectory() / the wallet's component. */
fs::path QuantumKeyBackupDirectory(const std::string& wallet_name);

/** Why a configured -quantumkeybackupdir is refused for its spelling alone, or nullopt. Applied on Windows only: a
 *  double separator prefix (above) and a drive-relative or root-relative value (above) are refused, in different words.
 *  Reads nothing from the file system, so it can run at startup. */
std::optional<std::string> QuantumKeyBackupSpellingRejection(std::string_view configured);

/** Why a wallet's resolved backup directory is refused for its length alone, or nullopt. Applied on Windows only: more
 *  than QUANTUM_BACKUP_WINDOWS_MAX_DIRECTORY_UNITS UTF-16 code units (counting the whole resolved path, the wallet's
 *  component and every separator) leaves no room for the staging and verification folders below it. Reads nothing from
 *  the file system. */
std::optional<std::string> QuantumKeyBackupLengthRejection(const fs::path& wallet_directory);

/** What the spelling and length rules say about the named wallet's backup directory as the node is configured now, from
 *  the arguments only (the file system is never read), so it can run when a wallet is loaded or created, before a quantum
 *  key can be made for it. A backup directory that was configured (a non-empty -quantumkeybackupdir, which is the user's
 *  own choice) that breaks a rule is an `error`: the wallet is refused. An option that is unset or empty means the default
 *  path under the data directory, which the user did not choose and which ordinary wallet use does not need: a default
 *  path that is too long is only a `warning` and the wallet loads; the automatic backup is then refused at the time it
 *  would be made (EnsureQuantumKeyBackupDirectory) and a pending key and the active destination are left as they are. The
 *  check does not establish that the directory is writable, has room, is on a supported volume or that a backup will be
 *  durable. */
struct QuantumKeyBackupPathCheck
{
    std::optional<std::string> error;
    std::optional<std::string> warning;
};
QuantumKeyBackupPathCheck CheckQuantumKeyBackupWalletPath(const std::string& wallet_name);

/** The `error` of CheckQuantumKeyBackupWalletPath alone. */
std::optional<std::string> QuantumKeyBackupWalletPathRejection(const std::string& wallet_name);

/** The names a migration of a legacy wallet publishes: the wallet itself, and, only when the migration needs them,
 *  `<prefix>_watchonly` (watch-only scripts to keep) and `<prefix>_solvables` (solvable scripts to keep). The prefix is the
 *  wallet's name, or "default_wallet" for the unnamed wallet. */
std::vector<std::string> QuantumKeyBackupMigrationNames(const std::string& wallet_name, bool watchonly_wallet, bool solvables_wallet);

/** The first name of a migration's publication plan whose configured backup directory breaks a rule (an `error` naming
 *  it), and the first warning for a name on a default path. The migration calls it with both flags false for the wallet's
 *  own name alone before the wallet is unloaded (before any change), and again with the plan once the descriptors are
 *  produced, which is after the wallet's database was converted and before any auxiliary wallet is created. */
QuantumKeyBackupPathCheck CheckQuantumKeyBackupMigrationPaths(const std::string& wallet_name, bool watchonly_wallet, bool solvables_wallet);

/** The identity of a directory as Windows reports it for an open handle: the volume's serial number and the file
 *  index, which together name one directory whatever the spelling or case of the path that reached it. */
struct QuantumBackupDirectoryIdentity
{
    uint32_t volume_serial{0};
    uint32_t file_index_high{0};
    uint32_t file_index_low{0};
    bool operator==(const QuantumBackupDirectoryIdentity& other) const
    {
        return volume_serial == other.volume_serial && file_index_high == other.file_index_high &&
               file_index_low == other.file_index_low;
    }
};

/** Whether the walk up from the wallet's backup directory has reached the data directory, after the directory just
 *  walked was validated and flushed. When both identities are known, only equal identities stop the walk (a path
 *  that differs only in case or spelling still names the data directory, and a lexical match never overrides two
 *  different identities). When either is unknown, the walk stops at the lexical match. Pure, so it is tested on every
 *  platform. */
bool QuantumBackupWalkReachedDataDirectory(const std::optional<QuantumBackupDirectoryIdentity>& walked,
                                           const std::optional<QuantumBackupDirectoryIdentity>& data_directory,
                                           bool same_path);

/** Tests only: report the identity of a directory (on every platform) instead of the operating system's; an empty
 *  function restores the platform's own answer (the Windows file information of a directory handle; none elsewhere). */
void SetQuantumKeyBackupDirectoryIdentityForTest(std::function<std::optional<QuantumBackupDirectoryIdentity>(const fs::path&)> hook);

/** Create the wallet's directory (mode 0700 on POSIX, tightened to 0700 when it exists and is wider) and make it
 *  durable: on every call the directory and every ancestor that this feature may have created (up to the data
 *  directory, or the file system root for a directory outside it) are committed to disk, so a name made by an
 *  earlier, interrupted attempt is committed too. Returns false with the reason in error; a directory that cannot be
 *  committed is a failure (the key it protects stays pending). On Windows the directories are flushed through a
 *  directory handle (FlushFileBuffers), and only on an NTFS volume of a fixed local disk, with the file system name and the
 *  drive type both taken from that handle (see QuantumBackupVolumeRejection); that
 *  code is compiled for the Windows target only and has not been run. On Windows a directory whose path starts with
 *  two separators (a network or device path), is relative to a drive or to a drive's root, or is longer than
 *  QUANTUM_BACKUP_WINDOWS_MAX_DIRECTORY_UNITS is refused before anything is looked up, created or committed. The walk
 *  up stops at the data directory, recognised by its identity where the file system gives one. */
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

/** Tests only: resolve the backup directory against this data directory instead of the node's, so a test can build a
 *  directory of an exact length whatever the length of the test run's own paths; nullopt restores the node's. */
void SetQuantumKeyBackupDataDirectoryForTest(std::optional<fs::path> data_directory);

/** Tests only: apply (true) or do not apply (false) the Windows rule for a double separator prefix whatever the
 *  platform; nullopt restores the platform's own answer (applied on Windows only). */
void SetQuantumKeyBackupWindowsPathRulesForTest(std::optional<bool> rules);

/** Tests only: on Windows, take a drive whose type the system reports as unknown for a fixed disk. The Wine emulator
 *  the cross-built unit tests run under reports its drives that way; a removable, network, optical or RAM drive and
 *  a file system other than NTFS are still refused. Off by default and never set outside the test binary. */
void SetQuantumKeyBackupUnknownDriveIsFixedForTest(bool unknown_is_fixed);

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

/** The file names to delete. From the verified generations, in descending order of sequence and then of file
 *  name, a generation is kept when it is among the newest keep_newest, or when any key it holds is not in
 *  live_keys, or when any key it holds is not held by a newer generation that is itself kept. Only a verified
 *  generation outside those conditions is chosen; a generation that is not verified never is. So the sole
 *  protector of a live key is never deleted, and neither is a generation that holds a key this wallet does not
 *  know (made by another process that shares the directory, or since removed), so such generations can accumulate
 *  beyond keep_newest. Equal sequences are ordered by file name, which is not a chronological order across
 *  processes; file names are random and a published generation is never rewritten. Pure. */
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
