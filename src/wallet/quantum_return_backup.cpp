// Copyright (c) 2026 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <wallet/quantum_return_backup.h>

#include <chainparams.h>
#include <common/args.h>
#include <crypto/sha256.h>
#include <logging.h>
#include <random.h>
#include <util/fs_helpers.h>
#include <util/strencodings.h>
#include <util/string.h>
#include <util/syserror.h>
#include <util/time.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <cstdio>
#include <functional>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <system_error>

#ifndef WIN32
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#else
#include <windows.h>
#endif

namespace wallet {
namespace {

constexpr std::string_view FILE_PREFIX{"quantum-wallet-"};
constexpr std::string_view FILE_SUFFIX{".dat"};
constexpr std::string_view MANIFEST_SUFFIX{".keys"};
constexpr std::string_view MANIFEST_HEADER{"quantum-key-backup-manifest 1"};
//! "20261122T123456Z", "-h" and ten digits, "-", sixteen hex digits.
constexpr size_t TIME_CHARS{16};
constexpr size_t HEIGHT_CHARS{10};
constexpr size_t SUFFIX_CHARS{16};

bool IsDigits(std::string_view s)
{
    return !s.empty() && std::all_of(s.begin(), s.end(), [](char c) { return c >= '0' && c <= '9'; });
}

bool IsLowerHex(std::string_view s)
{
    return !s.empty() && std::all_of(s.begin(), s.end(), [](char c) { return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'); });
}

//! Test seam: replaces the commit of a directory (see SetQuantumKeyBackupDirectoryCommitForTest).
std::function<bool(const fs::path&)> g_directory_commit_hook;

//! Test seam: an unknown drive type counts as a fixed disk (see SetQuantumKeyBackupUnknownDriveIsFixedForTest).
bool g_unknown_drive_is_fixed_for_test{false};

//! Test seam: the Windows path rule on any platform (see SetQuantumKeyBackupWindowsPathRulesForTest).
std::optional<bool> g_windows_path_rules_for_test;

bool WindowsPathRulesApply()
{
    if (g_windows_path_rules_for_test) return *g_windows_path_rules_for_test;
#ifdef WIN32
    return true;
#else
    return false;
#endif
}

//! Test seam: the data directory the backup directory is resolved against (see SetQuantumKeyBackupDataDirectoryForTest).
std::optional<fs::path> g_data_directory_for_test;

fs::path BackupDataDirectory()
{
    return g_data_directory_for_test ? *g_data_directory_for_test : gArgs.GetDataDirNet();
}

//! Test seam: the identity of a directory (see SetQuantumKeyBackupDirectoryIdentityForTest).
std::function<std::optional<QuantumBackupDirectoryIdentity>(const fs::path&)> g_directory_identity_hook;

/** Why a backup directory given by the caller is refused for its spelling alone, before the file system is touched:
 *  on Windows, a path that starts with two separators, or one that is relative to a drive or to a drive's root. Never
 *  applied to the volume GUID path Windows reports for an open handle, which is how a local volume is recognised. */
std::optional<std::string> BackupDirectorySpellingRejection(const fs::path& directory)
{
    if (!WindowsPathRulesApply()) return std::nullopt;
    return QuantumKeyBackupSpellingRejection(fs::PathToString(directory));
}

std::string DriveTypeName(unsigned drive_type)
{
    switch (drive_type) {
    case QUANTUM_BACKUP_DRIVE_NO_ROOT_DIR: return "no volume root";
    case QUANTUM_BACKUP_DRIVE_REMOVABLE: return "a removable drive";
    case QUANTUM_BACKUP_DRIVE_FIXED: return "a fixed drive";
    case QUANTUM_BACKUP_DRIVE_REMOTE: return "a network share";
    case QUANTUM_BACKUP_DRIVE_CDROM: return "an optical drive";
    case QUANTUM_BACKUP_DRIVE_RAMDISK: return "a RAM disk";
    default: return "an unknown kind of drive";
    }
}

#ifdef WIN32
#ifndef VOLUME_NAME_GUID
#define VOLUME_NAME_GUID 0x1
#endif

/** An open Windows handle that is closed when it goes out of scope, so no exit from a function (a return or an
 *  exception) leaves it open. Close() closes it at a chosen point and reports why that failed. */
class ScopedWindowsHandle
{
public:
    explicit ScopedWindowsHandle(HANDLE handle) : m_handle(handle) {}
    ScopedWindowsHandle(const ScopedWindowsHandle&) = delete;
    ScopedWindowsHandle& operator=(const ScopedWindowsHandle&) = delete;
    ~ScopedWindowsHandle()
    {
        if (m_handle != INVALID_HANDLE_VALUE) ::CloseHandle(m_handle);
    }
    HANDLE get() const { return m_handle; }
    bool valid() const { return m_handle != INVALID_HANDLE_VALUE; }
    /** Close now. On failure error is the system error taken at the failed call. The handle is never closed twice. */
    bool Close(DWORD& error)
    {
        if (m_handle == INVALID_HANDLE_VALUE) return true;
        const HANDLE handle = m_handle;
        m_handle = INVALID_HANDLE_VALUE;
        if (::CloseHandle(handle)) return true;
        error = ::GetLastError();
        return false;
    }

private:
    HANDLE m_handle;
};

/** The identity of the directory an open handle names. On failure error says why (the system error is taken at the
 *  failed call). */
bool DirectoryIdentityOfHandle(HANDLE handle, QuantumBackupDirectoryIdentity& identity, std::string& error)
{
    BY_HANDLE_FILE_INFORMATION information{};
    if (!::GetFileInformationByHandle(handle, &information)) {
        const DWORD information_error = ::GetLastError();
        error = strprintf("its identity cannot be read: %s", Win32ErrorString(static_cast<int>(information_error)));
        return false;
    }
    identity.volume_serial = information.dwVolumeSerialNumber;
    identity.file_index_high = information.nFileIndexHigh;
    identity.file_index_low = information.nFileIndexLow;
    return true;
}

/** The identity of a directory, from a handle opened for its attributes only (no write access is needed to compare). */
bool DirectoryIdentityWindows(const fs::path& directory, QuantumBackupDirectoryIdentity& identity, std::string& error)
{
    ScopedWindowsHandle handle{::CreateFileW(directory.c_str(), FILE_READ_ATTRIBUTES,
                                             FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
                                             FILE_FLAG_BACKUP_SEMANTICS, nullptr)};
    if (!handle.valid()) {
        const DWORD open_error = ::GetLastError();
        error = strprintf("it cannot be opened to read its identity: %s", Win32ErrorString(static_cast<int>(open_error)));
        return false;
    }
    return DirectoryIdentityOfHandle(handle.get(), identity, error);
}

/** The final path of an open handle with the volume named by its GUID (`\\?\Volume{...}\dir\sub`), in a buffer sized to
 *  fit: the size the call asks for is asked for again until the answer fits, so a long path is never cut short. The
 *  system error is taken at the failed call, before anything else can change it. */
bool FinalPathByVolumeGuid(HANDLE handle, std::wstring& final_path, std::string& reason)
{
    DWORD needed = ::GetFinalPathNameByHandleW(handle, nullptr, 0, VOLUME_NAME_GUID);
    if (needed == 0) {
        const DWORD size_error = ::GetLastError();
        reason = strprintf("its volume cannot be identified: %s", Win32ErrorString(static_cast<int>(size_error)));
        return false;
    }
    for (int attempt = 0; attempt < 4; ++attempt) {
        if (needed > 65536) {
            reason = "its path is too long to be tied to one volume";
            return false;
        }
        std::wstring buffer(needed, L'\0');
        const DWORD written = ::GetFinalPathNameByHandleW(handle, buffer.data(), static_cast<DWORD>(buffer.size()), VOLUME_NAME_GUID);
        if (written == 0) {
            const DWORD path_error = ::GetLastError();
            reason = strprintf("its volume cannot be identified: %s", Win32ErrorString(static_cast<int>(path_error)));
            return false;
        }
        if (written < buffer.size()) { // success: the length without the terminating null
            buffer.resize(written);
            final_path = std::move(buffer);
            return true;
        }
        needed = written; // too small: the size it needs, with the terminating null
    }
    // Every answer was too small for the next: the path kept growing while it was read. There is no system error.
    reason = "its volume cannot be identified: its path kept changing length while it was being read";
    return false;
}

/** Flush a directory on Windows: open it as a directory (FILE_FLAG_BACKUP_SEMANTICS) with write access and take both
 *  answers about its volume from that one open handle: the volume's GUID path (GetFinalPathNameByHandleW with
 *  VOLUME_NAME_GUID, from which the volume root and so its drive type are taken; a handle that has no local volume GUID
 *  path, such as a network share, is refused) and its file system name (GetVolumeInformationByHandleW). The pair must
 *  pass QuantumBackupVolumeRejection (a fixed local disk with NTFS) before the handle is flushed. Neither answer is
 *  taken from the path that was asked for, which could name another volume by the time it is looked up.
 *  DirectoryCommit() in util/fs_helpers.cpp returns success without flushing on this platform and is left as it is
 *  for its other callers; the backup must not take that for a commit, so an error here is a failed commit, and a
 *  file system that cannot vouch for the flush is refused before it is trusted. `reason` says why it failed; the
 *  first failure is the reason, and a failure to close the handle is reported only when nothing failed before it.
 *  After a successful flush the directory's identity is read from the same handle: `identity` holds it, or stays
 *  empty with `identity_error` saying why it could not be read (which does not fail the commit). */
bool FlushDirectoryWindows(const fs::path& directory, std::string& reason, std::optional<QuantumBackupDirectoryIdentity>& identity,
                           std::string& identity_error)
{
    ScopedWindowsHandle handle{::CreateFileW(directory.c_str(), GENERIC_WRITE,
                                             FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
                                             FILE_FLAG_BACKUP_SEMANTICS, nullptr)};
    if (!handle.valid()) {
        const DWORD open_error = ::GetLastError();
        reason = strprintf("it cannot be opened for writing: %s", Win32ErrorString(static_cast<int>(open_error)));
        LogPrintf("Unable to open directory %s for durable commit: %s\n", fs::PathToString(directory), reason);
        return false;
    }
    bool committed = true;
    std::wstring final_path;
    wchar_t file_system[MAX_PATH + 1] = {};
    if (!FinalPathByVolumeGuid(handle.get(), final_path, reason)) {
        committed = false;
    } else if (const std::optional<std::wstring> volume_root = QuantumBackupLocalVolumeRoot(final_path); !volume_root) {
        reason = "the directory is not on a local volume that has a volume GUID path (a network share, or a path that cannot be tied to one local volume); use a folder on a local NTFS volume";
        committed = false;
    } else if (!::GetVolumeInformationByHandleW(handle.get(), nullptr, 0, nullptr, nullptr, nullptr, file_system, MAX_PATH + 1)) {
        const DWORD volume_error = ::GetLastError();
        reason = strprintf("its file system cannot be identified: %s", Win32ErrorString(static_cast<int>(volume_error)));
        committed = false;
    } else {
        std::string narrow_file_system;
        for (const wchar_t* c = file_system; *c != L'\0'; ++c) narrow_file_system.push_back(*c < 0x80 ? static_cast<char>(*c) : '?');
        unsigned drive_type = ::GetDriveTypeW(volume_root->c_str());
        // Tests under an emulator only: every other answer, the file system name included, is still the real one.
        if (g_unknown_drive_is_fixed_for_test && drive_type == QUANTUM_BACKUP_DRIVE_UNKNOWN) drive_type = QUANTUM_BACKUP_DRIVE_FIXED;
        if (const std::optional<std::string> rejection = QuantumBackupVolumeRejection(narrow_file_system, drive_type)) {
            reason = *rejection;
            committed = false;
        }
    }
    if (committed && !::FlushFileBuffers(handle.get())) {
        const DWORD flush_error = ::GetLastError();
        reason = strprintf("flushing it failed: %s", Win32ErrorString(static_cast<int>(flush_error)));
        committed = false;
    }
    if (committed) {
        QuantumBackupDirectoryIdentity found;
        if (DirectoryIdentityOfHandle(handle.get(), found, identity_error)) {
            identity = found;
        }
    }
    DWORD close_error{0};
    if (!handle.Close(close_error)) {
        if (committed) {
            reason = strprintf("closing it failed: %s", Win32ErrorString(static_cast<int>(close_error)));
            committed = false;
            identity.reset();
        } else {
            LogPrintf("Closing directory %s also failed: %s\n", fs::PathToString(directory), Win32ErrorString(static_cast<int>(close_error)));
        }
    }
    if (!committed) LogPrintf("Unable to durably commit directory %s: %s\n", fs::PathToString(directory), reason);
    return committed;
}
#endif

/** Make the entries of one directory durable: what has been created in it and what has been renamed into it. When
 *  it succeeds, `identity` is the directory's identity if it could be read, taken from the handle that was validated
 *  and flushed on Windows; otherwise it stays empty and `identity_error` may say why. */
bool CommitDirectory(const fs::path& directory, std::string& reason, std::optional<QuantumBackupDirectoryIdentity>& identity,
                     std::string& identity_error)
{
    identity.reset();
    identity_error.clear();
    if (g_directory_commit_hook) {
        if (!g_directory_commit_hook(directory)) return false;
        if (g_directory_identity_hook) identity = g_directory_identity_hook(directory);
        return true;
    }
#ifdef WIN32
    if (!FlushDirectoryWindows(directory, reason, identity, identity_error)) return false;
    if (g_directory_identity_hook) identity = g_directory_identity_hook(directory);
    return true;
#else
    (void)reason;
    if (!DirectoryCommit(directory)) return false;
    if (g_directory_identity_hook) identity = g_directory_identity_hook(directory);
    return true;
#endif
}

/** The identity of the data directory, as the walk compares it. */
std::optional<QuantumBackupDirectoryIdentity> DataDirectoryIdentity(const fs::path& datadir, std::string& error)
{
    error.clear();
    if (g_directory_identity_hook) return g_directory_identity_hook(datadir);
#ifdef WIN32
    QuantumBackupDirectoryIdentity identity;
    if (DirectoryIdentityWindows(datadir, identity, error)) return identity;
#endif
    return std::nullopt;
}

/** On a test chain, -quantumreturnfailcommit=<name> makes the commit of the entry of the directory called <name> fail,
 *  which is how the tests show that a failure here keeps the key pending. Never reachable on a production chain. */
bool CommitOfEntryIsInjectedToFail(const fs::path& directory)
{
    return Params().IsTestChain() && gArgs.GetArg("-quantumreturnfailcommit", "") == fs::PathToString(directory.filename());
}

std::string ManifestName(const std::string& file_name)
{
    return file_name + std::string{MANIFEST_SUFFIX};
}

std::optional<QuantumKeyBackupGeneration> ReadManifest(const fs::path& directory, const std::string& file_name)
{
    FILE* file = fsbridge::fopen(directory / fs::PathFromString(ManifestName(file_name)), "rb");
    if (file == nullptr) return std::nullopt;
    std::string content;
    std::array<char, 4096> buffer;
    size_t read;
    while ((read = std::fread(buffer.data(), 1, buffer.size(), file)) > 0) {
        content.append(buffer.data(), read);
        if (content.size() > (size_t{1} << 26)) break; // far beyond any real key inventory
    }
    std::fclose(file);

    const std::vector<std::string> lines = SplitString(content, '\n');
    // header, file, sequence, keys <n>, n key lines, end, and the empty piece after the last newline
    if (lines.size() < 6 || lines[0] != MANIFEST_HEADER) return std::nullopt;
    const auto field = [&](const std::string& line, std::string_view name) -> std::optional<std::string> {
        if (line.size() <= name.size() + 1 || line.compare(0, name.size(), name) != 0 || line[name.size()] != ' ') return std::nullopt;
        return line.substr(name.size() + 1);
    };
    const auto named = field(lines[1], "file");
    const auto sequence = field(lines[2], "sequence");
    const auto count = field(lines[3], "keys");
    if (!named || *named != file_name || !sequence || !count) return std::nullopt;
    const auto sequence_value = ToIntegral<uint64_t>(*sequence);
    const auto count_value = ToIntegral<uint64_t>(*count);
    // A generation made by this feature holds at least the key it protects: a manifest with no key is not evidence of
    // an empty wallet file, so it is not a verified generation.
    if (!sequence_value || !count_value || *count_value == 0 || lines.size() != 4 + *count_value + 2) return std::nullopt;
    if (lines[4 + *count_value] != "end" || !lines.back().empty()) return std::nullopt;

    QuantumKeyBackupGeneration generation;
    generation.file_name = file_name;
    generation.sequence = *sequence_value;
    for (uint64_t i = 0; i < *count_value; ++i) {
        const std::string& line = lines[4 + i];
        if (!IsLowerHex(line) || line.size() % 2 != 0) return std::nullopt;
        generation.keys.insert(ParseHex(line));
    }
    if (generation.keys.size() != *count_value) return std::nullopt;
    generation.verified = true;
    return generation;
}

} // namespace

std::string QuantumKeyBackupWalletComponent(const std::string& wallet_name)
{
    if (wallet_name.empty()) return "default";
    static constexpr char HEX[] = "0123456789abcdef";
    std::string out{"n_"};
    for (const char ch : wallet_name) {
        const auto c{static_cast<unsigned char>(ch)};
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-') {
            out += static_cast<char>(c);
        } else {
            out += '_';
            out += HEX[c >> 4];
            out += HEX[c & 15];
        }
    }
    if (out.size() > 80) {
        unsigned char hash[CSHA256::OUTPUT_SIZE];
        CSHA256().Write(reinterpret_cast<const unsigned char*>(wallet_name.data()), wallet_name.size()).Finalize(hash);
        out = out.substr(0, 50) + "~" + HexStr(Span<const unsigned char>{hash, 16});
    }
    return out;
}

bool QuantumBackupPathHasWindowsDoubleSeparatorPrefix(std::string_view value)
{
    const auto separator = [](char c) { return c == '\\' || c == '/'; };
    return value.size() >= 2 && separator(value[0]) && separator(value[1]);
}

bool QuantumBackupPathIsWindowsDriveOrRootRelative(std::string_view value)
{
    const auto separator = [](char c) { return c == '\\' || c == '/'; };
    const auto letter = [](char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); };
    if (value.size() >= 2 && letter(value[0]) && value[1] == ':') {
        return value.size() == 2 || !separator(value[2]);
    }
    return !value.empty() && separator(value[0]) && (value.size() == 1 || !separator(value[1]));
}

size_t QuantumBackupUtf16Length(std::string_view utf8)
{
    size_t units{0};
    for (const char ch : utf8) {
        const auto byte = static_cast<unsigned char>(ch);
        if ((byte & 0xC0) == 0x80) continue; // a continuation byte belongs to the character already counted
        units += byte >= 0xF0 ? 2 : 1;       // a four-byte character is a surrogate pair
    }
    return units;
}

std::optional<std::string> QuantumKeyBackupSpellingRejection(std::string_view configured)
{
    if (!WindowsPathRulesApply()) return std::nullopt;
    if (QuantumBackupPathHasWindowsDoubleSeparatorPrefix(configured)) {
        return "a network or device path is not supported; use a folder on a local NTFS volume";
    }
    if (QuantumBackupPathIsWindowsDriveOrRootRelative(configured)) {
        return "a path that is relative to a drive or to the root of a drive (such as D:dir or \\dir) is not supported; "
               "give the full path with its drive and a separator (such as D:\\dir), or a path relative to the data directory";
    }
    return std::nullopt;
}

std::optional<std::string> QuantumKeyBackupLengthRejection(const fs::path& wallet_directory)
{
    if (!WindowsPathRulesApply()) return std::nullopt;
    const size_t units = QuantumBackupUtf16Length(fs::PathToString(wallet_directory));
    if (units > QUANTUM_BACKUP_WINDOWS_MAX_DIRECTORY_UNITS) {
        return strprintf("the path is too long: it has %d characters and at most %d are allowed, because each backup is staged "
                         "and verified in folders inside it; use a shorter path (set -quantumkeybackupdir to a shorter folder "
                         "on a local NTFS volume)",
                         units, QUANTUM_BACKUP_WINDOWS_MAX_DIRECTORY_UNITS);
    }
    return std::nullopt;
}

QuantumKeyBackupPathCheck CheckQuantumKeyBackupWalletPath(const std::string& wallet_name)
{
    QuantumKeyBackupPathCheck check;
    if (!WindowsPathRulesApply()) return check;
    const std::string configured = gArgs.GetArg("-quantumkeybackupdir", "");
    if (const auto rejection = QuantumKeyBackupSpellingRejection(configured)) {
        check.error = strprintf("-quantumkeybackupdir: %s", *rejection);
        return check;
    }
    const fs::path directory = QuantumKeyBackupDirectory(wallet_name);
    if (const auto rejection = QuantumKeyBackupLengthRejection(directory)) {
        if (!configured.empty()) {
            check.error = strprintf("the quantum key backup directory %s: %s", fs::PathToString(directory), *rejection);
        } else {
            check.warning = strprintf("the default quantum key backup directory %s: %s. The wallet loads, but a backup of a new "
                                      "quantum stake return key is refused, and the key stays pending, until the option is set",
                                      fs::PathToString(directory), *rejection);
        }
    }
    return check;
}

std::optional<std::string> QuantumKeyBackupWalletPathRejection(const std::string& wallet_name)
{
    return CheckQuantumKeyBackupWalletPath(wallet_name).error;
}

std::vector<std::string> QuantumKeyBackupMigrationNames(const std::string& wallet_name, bool watchonly_wallet, bool solvables_wallet)
{
    const std::string prefix = wallet_name.empty() ? "default_wallet" : wallet_name;
    std::vector<std::string> names{wallet_name};
    if (watchonly_wallet) names.push_back(prefix + "_watchonly");
    if (solvables_wallet) names.push_back(prefix + "_solvables");
    return names;
}

QuantumKeyBackupPathCheck CheckQuantumKeyBackupMigrationPaths(const std::string& wallet_name, bool watchonly_wallet, bool solvables_wallet)
{
    QuantumKeyBackupPathCheck result;
    for (const std::string& name : QuantumKeyBackupMigrationNames(wallet_name, watchonly_wallet, solvables_wallet)) {
        const QuantumKeyBackupPathCheck one = CheckQuantumKeyBackupWalletPath(name);
        if (one.error) {
            result.error = strprintf("the migration publishes the wallet \"%s\", whose %s", name, *one.error);
            return result;
        }
        if (one.warning && !result.warning) result.warning = one.warning;
    }
    return result;
}

bool QuantumBackupWalkReachedDataDirectory(const std::optional<QuantumBackupDirectoryIdentity>& walked,
                                           const std::optional<QuantumBackupDirectoryIdentity>& data_directory,
                                           bool same_path)
{
    if (walked && data_directory) return *walked == *data_directory;
    return same_path;
}

void SetQuantumKeyBackupDirectoryIdentityForTest(std::function<std::optional<QuantumBackupDirectoryIdentity>(const fs::path&)> hook)
{
    g_directory_identity_hook = std::move(hook);
}

void SetQuantumKeyBackupDataDirectoryForTest(std::optional<fs::path> data_directory)
{
    g_data_directory_for_test = std::move(data_directory);
}

void SetQuantumKeyBackupWindowsPathRulesForTest(std::optional<bool> rules)
{
    g_windows_path_rules_for_test = rules;
}

fs::path QuantumKeyBackupBaseDirectory()
{
    const std::string configured = gArgs.GetArg("-quantumkeybackupdir", "");
    if (!configured.empty()) {
        fs::path path = fs::PathFromString(configured);
        // A network or device path, and a path relative to a drive or to a drive's root, keep their spelling, so
        // each is refused as what it is and never becomes a folder below the data directory.
        if (QuantumKeyBackupSpellingRejection(configured)) return path;
        if (path.is_relative()) path = BackupDataDirectory() / path;
        return path;
    }
    return BackupDataDirectory() / "quantum-key-backups";
}

fs::path QuantumKeyBackupDirectory(const std::string& wallet_name)
{
    return QuantumKeyBackupBaseDirectory() / fs::PathFromString(QuantumKeyBackupWalletComponent(wallet_name));
}

std::optional<std::string> QuantumBackupVolumeRejection(std::string_view file_system, unsigned drive_type)
{
    const std::string name = file_system.empty() ? std::string{"unknown"} : ToLower(std::string{file_system});
    if (drive_type == QUANTUM_BACKUP_DRIVE_REMOTE) {
        return strprintf("the backup directory is on a network share (file system %s), where a flush does not prove that the directory entries are on disk; use a folder on a local NTFS volume", name);
    }
    if (name != "ntfs") {
        return strprintf("the backup directory is on a volume with file system %s, where a flush does not prove that the directory entries are on disk; use a folder on a local NTFS volume", name);
    }
    if (drive_type != QUANTUM_BACKUP_DRIVE_FIXED) {
        return strprintf("the backup directory is on an NTFS volume on %s, which is not a fixed local disk; use a folder on a local NTFS volume", DriveTypeName(drive_type));
    }
    return std::nullopt;
}

std::optional<std::wstring> QuantumBackupLocalVolumeRoot(std::wstring_view final_path)
{
    // `\\?\Volume{` + 36 characters of GUID (8-4-4-4-12 hex digits) + `}\`, optionally followed by the path in the volume.
    constexpr std::wstring_view PREFIX{L"\\\\?\\Volume{"};
    constexpr size_t GUID_CHARS{36};
    constexpr size_t ROOT_CHARS{PREFIX.size() + GUID_CHARS + 2};
    if (final_path.size() < ROOT_CHARS) return std::nullopt;
    const auto lower = [](wchar_t c) { return c >= L'A' && c <= L'Z' ? static_cast<wchar_t>(c + (L'a' - L'A')) : c; };
    for (size_t i = 0; i < PREFIX.size(); ++i) {
        if (lower(final_path[i]) != lower(PREFIX[i])) return std::nullopt;
    }
    for (size_t i = 0; i < GUID_CHARS; ++i) {
        const wchar_t c = final_path[PREFIX.size() + i];
        if (i == 8 || i == 13 || i == 18 || i == 23) {
            if (c != L'-') return std::nullopt;
        } else if (!((c >= L'0' && c <= L'9') || (c >= L'a' && c <= L'f') || (c >= L'A' && c <= L'F'))) {
            return std::nullopt;
        }
    }
    if (final_path[PREFIX.size() + GUID_CHARS] != L'}' || final_path[PREFIX.size() + GUID_CHARS + 1] != L'\\') return std::nullopt;
    return std::wstring{final_path.substr(0, ROOT_CHARS)};
}

void SetQuantumKeyBackupUnknownDriveIsFixedForTest(bool unknown_is_fixed)
{
    g_unknown_drive_is_fixed_for_test = unknown_is_fixed;
}

void SetQuantumKeyBackupDirectoryCommitForTest(std::function<bool(const fs::path&)> hook)
{
    g_directory_commit_hook = std::move(hook);
}

bool EnsureQuantumKeyBackupDirectory(const fs::path& directory, std::string& error)
{
    if (const std::optional<std::string> rejection = BackupDirectorySpellingRejection(directory)) {
        error = strprintf("cannot make the backup directory %s durable: %s", fs::PathToString(directory), *rejection);
        return false;
    }
    if (const std::optional<std::string> rejection = QuantumKeyBackupLengthRejection(directory)) {
        error = strprintf("cannot make the backup directory %s durable: %s", fs::PathToString(directory), *rejection);
        return false;
    }
    try {
        // Create what is missing from the top down, each with mode 0700, so no part of the path is ever
        // readable by others, and tighten the wallet's own directory when it already exists and is wider.
        std::vector<fs::path> missing;
        for (fs::path path = directory; !path.empty() && !fs::exists(path); path = path.parent_path()) {
            missing.push_back(path);
            if (path == path.parent_path()) break;
        }
        for (auto it = missing.rbegin(); it != missing.rend(); ++it) {
#ifndef WIN32
            if (::mkdir(it->c_str(), S_IRWXU) != 0 && errno != EEXIST) {
                error = strprintf("cannot create the backup directory %s: %s", fs::PathToString(*it), SysErrorString(errno));
                return false;
            }
#else
            std::error_code ec;
            fs::create_directory(*it, ec);
            if (ec) {
                error = strprintf("cannot create the backup directory %s: %s", fs::PathToString(*it), ec.message());
                return false;
            }
#endif
        }
        if (!fs::is_directory(directory)) {
            error = strprintf("the backup path %s is not a directory", fs::PathToString(directory));
            return false;
        }
#ifndef WIN32
        const fs::perms current = fs::status(directory).permissions();
        if ((current & (fs::perms::group_all | fs::perms::others_all)) != fs::perms::none) {
            std::error_code ec;
            fs::permissions(directory, fs::perms::owner_all, fs::perm_options::replace, ec);
            if (ec) {
                error = strprintf("cannot make the backup directory %s private: %s", fs::PathToString(directory), ec.message());
                return false;
            }
        }
#endif
        // Durability is established on EVERY call for the whole chain of directories that this feature may have
        // created and not yet committed: the wallet's own directory, then each ancestor, up to the data directory
        // when the backup directory is below it (the node made that one) and to the root of the file system when it
        // is not. Flushing a directory commits the entries made in it, so flushing the parent of each is what makes
        // the name of the directory below it durable. A directory made by an earlier attempt that was interrupted
        // between its creation and the commit of its parent's entry, or that could not be taken away again, is
        // found by this walk like any other: nothing here depends on what an earlier attempt managed to undo.
        // The data directory is recognised by its identity when the file system gives one (its volume and file
        // index, which a path spelled in another case or by a short name shares), and by its path otherwise.
        const fs::path datadir = gArgs.GetDataDirNet();
        std::string datadir_identity_error;
        const std::optional<QuantumBackupDirectoryIdentity> datadir_identity = DataDirectoryIdentity(datadir, datadir_identity_error);
        for (fs::path path = directory;; path = path.parent_path()) {
            std::string reason;
            std::optional<QuantumBackupDirectoryIdentity> identity;
            std::string identity_error;
            if (!CommitDirectory(path, reason, identity, identity_error)) {
                error = strprintf("cannot make the backup directory %s durable", fs::PathToString(path));
                if (!reason.empty()) error += ": " + reason;
                return false;
            }
            if (!identity && !identity_error.empty()) {
                LogPrintf("Comparing the path of %s with the data directory because its identity cannot be read: %s\n",
                          fs::PathToString(path), identity_error);
            } else if (!datadir_identity && !datadir_identity_error.empty()) {
                LogPrintf("Comparing the path of %s with the data directory because the data directory's identity cannot be read: %s\n",
                          fs::PathToString(path), datadir_identity_error);
            }
            const fs::path parent = path.parent_path();
            if (QuantumBackupWalkReachedDataDirectory(identity, datadir_identity, path == datadir) || parent.empty() || parent == path) break;
            // The entry of `path` is in `parent`, which the next round commits.
            if (CommitOfEntryIsInjectedToFail(path)) {
                error = strprintf("cannot make the entry of the backup directory %s durable", fs::PathToString(path));
                return false;
            }
        }
    } catch (const fs::filesystem_error& e) {
        error = strprintf("the backup directory %s is not usable: %s", fs::PathToString(directory), fsbridge::get_filesystem_error_message(e));
        return false;
    }
    return true;
}

std::string QuantumKeyBackupFileName(int64_t unix_time, int height, const std::string& suffix)
{
    std::string stamp = FormatISO8601DateTime(unix_time); // 2026-11-22T12:34:56Z
    stamp.erase(std::remove_if(stamp.begin(), stamp.end(), [](char c) { return c == '-' || c == ':'; }), stamp.end());
    std::string digits = ToString(std::max(height, 0));
    if (digits.size() < HEIGHT_CHARS) digits.insert(0, HEIGHT_CHARS - digits.size(), '0');
    return strprintf("%s%s-h%s-%s%s", FILE_PREFIX, stamp, digits, suffix, FILE_SUFFIX);
}

bool IsQuantumKeyBackupFileName(const std::string& name)
{
    // quantum-wallet-YYYYMMDDTHHMMSSZ-hNNNNNNNNNN-<16 hex>.dat
    const size_t expected = FILE_PREFIX.size() + TIME_CHARS + 2 + HEIGHT_CHARS + 1 + SUFFIX_CHARS + FILE_SUFFIX.size();
    if (name.size() != expected || name.compare(0, FILE_PREFIX.size(), FILE_PREFIX) != 0) return false;
    size_t pos = FILE_PREFIX.size();
    const std::string_view view{name};
    const std::string_view stamp = view.substr(pos, TIME_CHARS);
    if (!IsDigits(stamp.substr(0, 8)) || stamp[8] != 'T' || !IsDigits(stamp.substr(9, 6)) || stamp[15] != 'Z') return false;
    pos += TIME_CHARS;
    if (view.substr(pos, 2) != "-h") return false;
    pos += 2;
    if (!IsDigits(view.substr(pos, HEIGHT_CHARS))) return false;
    pos += HEIGHT_CHARS;
    if (view[pos] != '-') return false;
    ++pos;
    if (!IsLowerHex(view.substr(pos, SUFFIX_CHARS))) return false;
    pos += SUFFIX_CHARS;
    return view.substr(pos) == FILE_SUFFIX;
}

std::string NewQuantumKeyBackupSuffix()
{
    std::array<unsigned char, SUFFIX_CHARS / 2> bytes;
    GetRandBytes(bytes);
    return HexStr(bytes);
}

std::set<std::string> SelectQuantumKeyBackupsToPrune(const std::vector<QuantumKeyBackupGeneration>& generations,
                                                     const QuantumKeyBackupKeySet& live_keys, size_t keep_newest)
{
    std::vector<const QuantumKeyBackupGeneration*> verified;
    for (const QuantumKeyBackupGeneration& generation : generations) {
        if (generation.verified) verified.push_back(&generation);
    }
    std::sort(verified.begin(), verified.end(), [](const auto* a, const auto* b) {
        return a->sequence != b->sequence ? a->sequence > b->sequence : a->file_name > b->file_name;
    });
    QuantumKeyBackupKeySet covered;
    std::set<std::string> doomed;
    for (size_t i = 0; i < verified.size(); ++i) {
        const QuantumKeyBackupGeneration& generation = *verified[i];
        bool keep = i < keep_newest;
        if (!keep) {
            // An older generation stays when it holds a key this wallet does not know (a key another process
            // sharing the directory made, or one since removed from the wallet), because this wallet cannot say
            // whether another generation protects that key, and when it holds a key that no newer retained
            // generation holds (so the sole protector of a key is never deleted). Only the retained generations
            // newer than it count as covering.
            for (const auto& key : generation.keys) {
                if (!live_keys.count(key) || !covered.count(key)) {
                    keep = true;
                    break;
                }
            }
        }
        if (keep) {
            covered.insert(generation.keys.begin(), generation.keys.end());
        } else {
            doomed.insert(generation.file_name);
        }
    }
    return doomed;
}

std::vector<QuantumKeyBackupGeneration> ListQuantumKeyBackupGenerations(const fs::path& directory)
{
    std::vector<QuantumKeyBackupGeneration> generations;
    std::error_code ec;
    fs::directory_iterator it{directory, ec};
    if (ec) return generations;
    for (const fs::directory_iterator end; it != end; it.increment(ec)) {
        if (ec) break;
        const std::string name = fs::PathToString(it->path().filename());
        if (!IsQuantumKeyBackupFileName(name)) continue;
        std::error_code type_ec;
        if (!it->is_regular_file(type_ec) || type_ec) continue;
        if (auto generation = ReadManifest(directory, name)) {
            generations.push_back(std::move(*generation));
        } else {
            QuantumKeyBackupGeneration unverified;
            unverified.file_name = name;
            generations.push_back(std::move(unverified));
        }
    }
    return generations;
}

uint64_t NextQuantumKeyBackupSequence(const fs::path& directory)
{
    uint64_t highest{0};
    for (const QuantumKeyBackupGeneration& generation : ListQuantumKeyBackupGenerations(directory)) {
        if (generation.verified) highest = std::max(highest, generation.sequence);
    }
    return highest + 1;
}

bool WriteQuantumKeyBackupManifest(const fs::path& directory, const std::string& file_name, uint64_t sequence,
                                   const QuantumKeyBackupKeySet& keys, std::string& error)
{
    std::string content = strprintf("%s\nfile %s\nsequence %s\nkeys %s\n", MANIFEST_HEADER, file_name, ToString(sequence), ToString(keys.size()));
    for (const auto& key : keys) content += HexStr(key) + "\n";
    content += "end\n";

    const fs::path final_path = directory / fs::PathFromString(ManifestName(file_name));
    const fs::path temporary = directory / fs::PathFromString("." + ManifestName(file_name) + ".tmp");
    FILE* file{nullptr};
#ifndef WIN32
    const int fd = ::open(temporary.c_str(), O_WRONLY | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR);
    if (fd >= 0) {
        file = ::fdopen(fd, "wb");
        if (file == nullptr) ::close(fd);
    }
#else
    file = fsbridge::fopen(temporary, "wb");
#endif
    if (file == nullptr) {
        error = strprintf("cannot create the backup manifest %s: %s", fs::PathToString(temporary), SysErrorString(errno));
        return false;
    }
    const bool written = std::fwrite(content.data(), 1, content.size(), file) == content.size();
    const bool committed = written && FileCommit(file);
    const bool closed = std::fclose(file) == 0;
    if (!written || !committed || !closed) {
        error = strprintf("cannot write the backup manifest %s", fs::PathToString(temporary));
        std::error_code ec;
        fs::remove(temporary, ec);
        return false;
    }
    // The system's reason for a failed rename is taken at the call, before the temporary file is removed.
    std::string rename_error;
    if (!RenameOver(temporary, final_path, &rename_error)) {
        error = strprintf("cannot install the backup manifest %s", fs::PathToString(final_path));
        if (!rename_error.empty()) error += ": " + rename_error;
        std::error_code ec;
        fs::remove(temporary, ec);
        return false;
    }
    if (!DirectoryCommit(directory)) {
        error = strprintf("cannot make the installed backup manifest %s durable", fs::PathToString(final_path));
        return false;
    }
    return true;
}

size_t PruneQuantumKeyBackups(const fs::path& directory, const QuantumKeyBackupKeySet& live_keys, size_t keep_newest)
{
    if (const std::optional<std::string> rejection = BackupDirectorySpellingRejection(directory)) {
        LogPrintf("Not pruning the wallet backups in %s: %s\n", fs::PathToString(directory), *rejection);
        return 0;
    }
    const std::set<std::string> doomed = SelectQuantumKeyBackupsToPrune(ListQuantumKeyBackupGenerations(directory), live_keys, keep_newest);
    size_t removed{0};
    for (const std::string& name : doomed) {
        // Only a name that is exactly a generation's file name is ever removed: the wallet file first, so a
        // crash between the two steps leaves a stray manifest and never a wallet file that looks unverified.
        if (!IsQuantumKeyBackupFileName(name)) continue;
        std::error_code ec;
        fs::remove(directory / fs::PathFromString(name), ec);
        if (ec) continue;
        fs::remove(directory / fs::PathFromString(ManifestName(name)), ec);
        ++removed;
    }
    return removed;
}

} // namespace wallet
