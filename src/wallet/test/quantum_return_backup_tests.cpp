// Copyright (c) 2026 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <chainparams.h>
#include <common/args.h>
#include <test/util/setup_common.h>
#include <util/fs.h>
#include <util/getuniquepath.h>
#include <util/strencodings.h>
#include <util/string.h>
#include <wallet/quantum_return_backup.h>

#include <boost/test/unit_test.hpp>

#include <algorithm>
#include <fstream>
#include <functional>
#include <set>
#include <string>
#include <vector>

#ifndef WIN32
#include <sys/stat.h>
#endif

namespace wallet {
namespace {

QuantumKeyBackupGeneration Generation(const std::string& name, uint64_t sequence, std::set<int> key_ids, bool verified = true)
{
    QuantumKeyBackupGeneration generation;
    generation.file_name = name;
    generation.verified = verified;
    generation.sequence = sequence;
    for (const int id : key_ids) generation.keys.insert(std::vector<unsigned char>{static_cast<unsigned char>(id), 0x42});
    return generation;
}

QuantumKeyBackupKeySet Keys(std::set<int> key_ids)
{
    QuantumKeyBackupKeySet keys;
    for (const int id : key_ids) keys.insert(std::vector<unsigned char>{static_cast<unsigned char>(id), 0x42});
    return keys;
}

} // namespace

BOOST_FIXTURE_TEST_SUITE(quantum_return_backup_tests, BasicTestingSetup)

BOOST_AUTO_TEST_CASE(wallet_names_become_one_safe_path_component_and_never_collide)
{
    BOOST_CHECK_EQUAL(QuantumKeyBackupWalletComponent(""), "default");
    const std::vector<std::string> names{
        "default", "Default", "DEFAULT", "a", "A", "a-b", "a_b", "a.b", "a b", "a/b", "a\\b", "..", ".", "...", "../..",
        "/", "\\", "a/../b", "wallet", "Wallet", "w\xc3\xa4llet", "w\xc3\xa4llet2", "\xe2\x82\xbf", "\xf0\x9f\x92\xb0",
        "con", "nul", "name:with:colons", "name\twith\ttab", std::string{"nul\0byte", 8}, std::string(300, 'x'),
        std::string(300, 'x') + "y", std::string(299, 'x') + "yy", std::string(300, 'X'), "n_a", "n_61",
    };
    std::set<std::string> components;
    for (const std::string& name : names) {
        const std::string component = QuantumKeyBackupWalletComponent(name);
        BOOST_CHECK_MESSAGE(!component.empty(), "empty component for " << name.size() << " byte name");
        BOOST_CHECK_MESSAGE(component.size() <= 100, "component too long: " << component);
        BOOST_CHECK_MESSAGE(component.find('/') == std::string::npos && component.find('\\') == std::string::npos &&
                            component.find("..") == std::string::npos && component.find('\0') == std::string::npos &&
                            component.find(':') == std::string::npos && component[0] != '.',
                            "unsafe component " << component);
        for (const char c : component) {
            BOOST_CHECK_MESSAGE((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '~',
                                "unexpected character in " << component);
        }
        // fs::path sees exactly one component
        const fs::path as_path = fs::PathFromString(component);
        BOOST_CHECK_EQUAL(std::distance(as_path.begin(), as_path.end()), 1);
        BOOST_CHECK_MESSAGE(components.insert(component).second, "two names share " << component);
    }
    // an upper case name and its lower case twin differ even on a file system that ignores case
    std::set<std::string> folded;
    for (const std::string& component : components) {
        std::string lower = component;
        for (char& c : lower) c = (c >= 'A' && c <= 'Z') ? static_cast<char>(c - 'A' + 'a') : c;
        BOOST_CHECK(folded.insert(lower).second);
    }
    // the unnamed wallet and a wallet called "default" are different
    BOOST_CHECK(QuantumKeyBackupWalletComponent("") != QuantumKeyBackupWalletComponent("default"));
}

BOOST_AUTO_TEST_CASE(backup_file_names_carry_time_height_and_a_suffix)
{
    const std::string name = QuantumKeyBackupFileName(1'798'000'000, 6'917'000, "0123456789abcdef");
    BOOST_CHECK_EQUAL(name, "quantum-wallet-20261223T042640Z-h0006917000-0123456789abcdef.dat");
    BOOST_CHECK(IsQuantumKeyBackupFileName(name));
    BOOST_CHECK(IsQuantumKeyBackupFileName(QuantumKeyBackupFileName(0, 0, NewQuantumKeyBackupSuffix())));
    BOOST_CHECK(NewQuantumKeyBackupSuffix() != NewQuantumKeyBackupSuffix());
    for (const std::string& foreign : {std::string{"wallet.dat"}, std::string{"backup.dat"}, name + ".bak", name.substr(1),
                                       std::string{"quantum-wallet-20261223T042640Z-h6917000-0123456789abcdef.dat"},
                                       std::string{"quantum-wallet-20261223T042640Z-h0006917000-0123456789ABCDEF.dat"},
                                       name + ".keys", "." + name, std::string{}}) {
        BOOST_CHECK_MESSAGE(!IsQuantumKeyBackupFileName(foreign), foreign);
    }
}

BOOST_AUTO_TEST_CASE(retention_keeps_three_and_every_sole_protector)
{
    // zero to five generations, each holding every key made so far (a wallet only ever gains keys)
    for (size_t count = 0; count <= 5; ++count) {
        std::vector<QuantumKeyBackupGeneration> generations;
        std::set<int> keys;
        for (size_t i = 0; i < count; ++i) {
            keys.insert(static_cast<int>(i));
            generations.push_back(Generation("g" + ToString(i), i + 1, keys));
        }
        const auto doomed = SelectQuantumKeyBackupsToPrune(generations, Keys(keys), QUANTUM_KEY_BACKUP_KEEP_GENERATIONS);
        BOOST_CHECK_EQUAL(doomed.size(), count > 3 ? count - 3 : 0);
        for (const std::string& name : doomed) {
            // only the oldest are removed
            BOOST_CHECK(ToIntegral<size_t>(name.substr(1)).value_or(count) < count - 3);
        }
    }

    // the oldest generation is the only one holding key 0, which is live: it stays; the one next to it goes
    {
        std::vector<QuantumKeyBackupGeneration> generations{
            Generation("g1", 1, {0, 1}), Generation("g2", 2, {1, 2}), Generation("g3", 3, {1, 2, 3}),
            Generation("g4", 4, {1, 2, 3, 4}), Generation("g5", 5, {1, 2, 3, 4, 5}),
        };
        auto doomed = SelectQuantumKeyBackupsToPrune(generations, Keys({0, 1, 2, 3, 4, 5}), 3);
        BOOST_CHECK(doomed == std::set<std::string>{"g2"});
        // when key 0 is no longer a live key the oldest may go too
        doomed = SelectQuantumKeyBackupsToPrune(generations, Keys({1, 2, 3, 4, 5}), 3);
        BOOST_CHECK((doomed == std::set<std::string>{"g1", "g2"}));
        // a chain of sole protectors: g1 holds key 0 alone, g2 holds key 1 alone, and the newest three hold neither
        generations = {Generation("g1", 1, {0}), Generation("g2", 2, {1}), Generation("g3", 3, {2}),
                       Generation("g4", 4, {2}), Generation("g5", 5, {2})};
        doomed = SelectQuantumKeyBackupsToPrune(generations, Keys({0, 1, 2}), 3);
        BOOST_CHECK(doomed.empty());
        // a second holder of key 1 among the kept ones frees g2 but not g1
        generations[3] = Generation("g4", 4, {1, 2});
        doomed = SelectQuantumKeyBackupsToPrune(generations, Keys({0, 1, 2}), 3);
        BOOST_CHECK(doomed == std::set<std::string>{"g2"});
    }

    // an unverified file (a failed attempt, or one with no manifest) is never counted and never chosen
    {
        std::vector<QuantumKeyBackupGeneration> generations{
            Generation("v1", 1, {1}), Generation("v2", 2, {1}), Generation("v3", 3, {1}), Generation("v4", 4, {1}),
            Generation("failed-new", 9, {1}, /*verified=*/false), Generation("failed-old", 0, {1}, /*verified=*/false),
        };
        const auto doomed = SelectQuantumKeyBackupsToPrune(generations, Keys({1}), 3);
        BOOST_CHECK(doomed == std::set<std::string>{"v1"});
        // the failed attempt does not push a verified generation out of the newest three
        generations = {Generation("v1", 1, {1}), Generation("v2", 2, {1}), Generation("v3", 3, {1}),
                       Generation("failed-1", 4, {1}, false), Generation("failed-2", 5, {1}, false)};
        BOOST_CHECK(SelectQuantumKeyBackupsToPrune(generations, Keys({1}), 3).empty());
    }
}

BOOST_AUTO_TEST_CASE(a_generation_on_disk_needs_its_manifest_and_only_generations_are_pruned)
{
    const fs::path directory = m_path_root / "retention";
    std::string error;
    BOOST_REQUIRE_MESSAGE(EnsureQuantumKeyBackupDirectory(directory, error), error);
#ifndef WIN32
    {
        struct stat st;
        BOOST_REQUIRE_EQUAL(::stat(fs::PathToString(directory).c_str(), &st), 0);
        BOOST_CHECK_EQUAL(st.st_mode & 0777, 0700U);
    }
    // an existing wider directory is tightened
    fs::permissions(directory, fs::perms::owner_all | fs::perms::group_read | fs::perms::others_read, fs::perm_options::replace);
    BOOST_REQUIRE_MESSAGE(EnsureQuantumKeyBackupDirectory(directory, error), error);
    {
        struct stat st;
        BOOST_REQUIRE_EQUAL(::stat(fs::PathToString(directory).c_str(), &st), 0);
        BOOST_CHECK_EQUAL(st.st_mode & 0777, 0700U);
    }
#endif
    const auto make_file = [&](const std::string& name, const std::string& content = "wallet") {
        std::ofstream{directory / fs::PathFromString(name), std::ios::binary} << content;
    };
    std::vector<std::string> names;
    for (int i = 1; i <= 5; ++i) {
        const std::string name = QuantumKeyBackupFileName(1'798'000'000 + i, 100 + i, NewQuantumKeyBackupSuffix());
        names.push_back(name);
        make_file(name);
        BOOST_CHECK_EQUAL(NextQuantumKeyBackupSequence(directory), static_cast<uint64_t>(i));
        BOOST_REQUIRE_MESSAGE(WriteQuantumKeyBackupManifest(directory, name, static_cast<uint64_t>(i), Keys({1, 2}), error), error);
#ifndef WIN32
        struct stat st;
        BOOST_REQUIRE_EQUAL(::stat(fs::PathToString(directory / fs::PathFromString(name + ".keys")).c_str(), &st), 0);
        BOOST_CHECK_EQUAL(st.st_mode & 0777, 0600U);
#endif
    }
    // things this feature did not write, and a generation without a manifest
    make_file("wallet.dat");
    make_file("notes.txt");
    make_file(QuantumKeyBackupFileName(1'798'000'000, 1, "ffffffffffffffff"));
    const std::string no_manifest = QuantumKeyBackupFileName(1'798'000'000, 1, "ffffffffffffffff");
    // a truncated manifest does not make a generation
    const std::string truncated = QuantumKeyBackupFileName(1'798'000'000, 2, "eeeeeeeeeeeeeeee");
    make_file(truncated);
    make_file(truncated + ".keys", "quantum-key-backup-manifest 1\nfile " + truncated + "\nsequence 9\nkeys 2\n0102\n");

    const auto listed = ListQuantumKeyBackupGenerations(directory);
    size_t verified{0};
    for (const auto& generation : listed) verified += generation.verified;
    BOOST_CHECK_EQUAL(verified, size_t{5});
    BOOST_CHECK_EQUAL(listed.size(), size_t{7}); // five generations and two unverified files, nothing foreign

    BOOST_CHECK_EQUAL(PruneQuantumKeyBackups(directory, Keys({1, 2}), 3), size_t{2});
    BOOST_CHECK(!fs::exists(directory / fs::PathFromString(names[0])));
    BOOST_CHECK(!fs::exists(directory / fs::PathFromString(names[0] + ".keys")));
    BOOST_CHECK(!fs::exists(directory / fs::PathFromString(names[1])));
    for (size_t i = 2; i < names.size(); ++i) BOOST_CHECK(fs::exists(directory / fs::PathFromString(names[i])));
    BOOST_CHECK(fs::exists(directory / "wallet.dat"));
    BOOST_CHECK(fs::exists(directory / "notes.txt"));
    BOOST_CHECK(fs::exists(directory / fs::PathFromString(no_manifest)));
    BOOST_CHECK(fs::exists(directory / fs::PathFromString(truncated)));
    BOOST_CHECK_EQUAL(NextQuantumKeyBackupSequence(directory), uint64_t{6});
}

namespace {
/** Test-chain fault injection of the directory commit, and a default chain again afterwards. */
class ScopedDirectoryCommitFault
{
public:
    explicit ScopedDirectoryCommitFault(const std::string& name)
    {
        SelectParams(ChainType::REGTEST);
        gArgs.ForceSetArg("-quantumreturnfailcommit", name);
    }
    ~ScopedDirectoryCommitFault()
    {
        gArgs.ForceSetArg("-quantumreturnfailcommit", "");
        SelectParams(ChainType::MAIN);
    }
};
} // namespace

// Every directory the wallet's backup path needs is made private on its own, so a permissive umask cannot widen one,
// and each is committed to disk with its entry in the directory above before anything is backed up into it.
#ifndef WIN32
BOOST_AUTO_TEST_CASE(created_backup_directories_are_private_whatever_the_umask)
{
    const mode_t previous = ::umask(0);
    const fs::path directory = m_path_root / "umask-base" / "level-one" / "wallet";
    std::string error;
    const bool made = EnsureQuantumKeyBackupDirectory(directory, error);
    ::umask(previous);
    BOOST_REQUIRE_MESSAGE(made, error);
    for (const fs::path& path : {m_path_root / "umask-base", m_path_root / "umask-base" / "level-one", directory}) {
        struct stat st;
        BOOST_REQUIRE_EQUAL(::stat(fs::PathToString(path).c_str(), &st), 0);
        BOOST_CHECK_MESSAGE((st.st_mode & 0777) == 0700U, fs::PathToString(path) << " has mode " << (st.st_mode & 0777));
    }
}
#endif

BOOST_AUTO_TEST_CASE(windows_volume_classification_accepts_only_local_ntfs)
{
    // The pure function the Windows directory flush asks before it trusts a flush (it runs on every platform).
    BOOST_CHECK(!QuantumBackupVolumeRejection("NTFS", QUANTUM_BACKUP_DRIVE_FIXED));
    BOOST_CHECK(!QuantumBackupVolumeRejection("ntfs", QUANTUM_BACKUP_DRIVE_FIXED));
    BOOST_CHECK(!QuantumBackupVolumeRejection("Ntfs", QUANTUM_BACKUP_DRIVE_FIXED));
    // A removable drive can be unplugged, so it is refused even with NTFS on it, and the message says why.
    const auto removable = QuantumBackupVolumeRejection("NTFS", QUANTUM_BACKUP_DRIVE_REMOVABLE);
    BOOST_REQUIRE(removable);
    BOOST_CHECK(removable->find("removable") != std::string::npos);
    BOOST_CHECK(removable->find("fixed local disk") != std::string::npos);
    // Another file system on a local disk: refused, and the message names it.
    for (const std::string file_system : {"ReFS", "FAT32", "exFAT", "FAT", "CDFS", "UDF"}) {
        const auto rejection = QuantumBackupVolumeRejection(file_system, QUANTUM_BACKUP_DRIVE_FIXED);
        BOOST_REQUIRE_MESSAGE(rejection, file_system);
        BOOST_CHECK_MESSAGE(rejection->find(ToLower(file_system)) != std::string::npos, *rejection);
        BOOST_CHECK(rejection->find("local NTFS") != std::string::npos);
    }
    // A network share is refused even when the server says NTFS.
    const auto remote = QuantumBackupVolumeRejection("NTFS", QUANTUM_BACKUP_DRIVE_REMOTE);
    BOOST_REQUIRE(remote);
    BOOST_CHECK(remote->find("network share") != std::string::npos);
    BOOST_CHECK(QuantumBackupVolumeRejection("SMB", QUANTUM_BACKUP_DRIVE_REMOTE));
    // NTFS on anything that is not a local disk, and an unidentified volume, are refused.
    for (const unsigned drive : {QUANTUM_BACKUP_DRIVE_UNKNOWN, QUANTUM_BACKUP_DRIVE_NO_ROOT_DIR, QUANTUM_BACKUP_DRIVE_CDROM,
                                 QUANTUM_BACKUP_DRIVE_RAMDISK, 99U}) {
        BOOST_CHECK(QuantumBackupVolumeRejection("NTFS", drive));
    }
    const auto unknown = QuantumBackupVolumeRejection("", QUANTUM_BACKUP_DRIVE_FIXED);
    BOOST_REQUIRE(unknown);
    BOOST_CHECK(unknown->find("unknown") != std::string::npos);
}

BOOST_AUTO_TEST_CASE(windows_volume_root_comes_only_from_a_local_volume_guid_path)
{
    // What GetFinalPathNameByHandleW(VOLUME_NAME_GUID) returns for a directory on a local volume: the root is the first
    // 49 characters, whatever follows, and the case of the letters does not matter.
    const std::wstring guid{L"12345678-9abc-def0-1234-56789ABCDEF0"};
    const std::wstring root = L"\\\\?\\Volume{" + guid + L"}\\";
    for (const std::wstring& path : {root, root + L"Users", root + L"Users\\x\\wallet", L"\\\\?\\VOLUME{" + guid + L"}\\data"}) {
        const auto found = QuantumBackupLocalVolumeRoot(path);
        BOOST_REQUIRE(found);
        BOOST_CHECK(found->size() == root.size());
    }
    BOOST_CHECK(*QuantumBackupLocalVolumeRoot(root + L"Users\\x") == root);
    // No GUID path: nothing, an empty or cut-off answer, a drive-letter path, a device path.
    BOOST_CHECK(!QuantumBackupLocalVolumeRoot(L""));
    BOOST_CHECK(!QuantumBackupLocalVolumeRoot(L"\\\\?\\Volume{"));
    BOOST_CHECK(!QuantumBackupLocalVolumeRoot(root.substr(0, root.size() - 1)));
    BOOST_CHECK(!QuantumBackupLocalVolumeRoot(L"\\\\?\\C:\\Users\\x"));
    BOOST_CHECK(!QuantumBackupLocalVolumeRoot(L"C:\\Users\\x"));
    BOOST_CHECK(!QuantumBackupLocalVolumeRoot(L"\\\\.\\Volume{" + guid + L"}\\x"));
    BOOST_CHECK(!QuantumBackupLocalVolumeRoot(L"\\\\?\\GLOBALROOT\\Device\\HarddiskVolume1\\x"));
    // A network share (UNC), even one whose name looks like a volume.
    BOOST_CHECK(!QuantumBackupLocalVolumeRoot(L"\\\\?\\UNC\\server\\share\\wallet"));
    BOOST_CHECK(!QuantumBackupLocalVolumeRoot(L"\\\\?\\UNC\\Volume{" + guid + L"}\\x"));
    BOOST_CHECK(!QuantumBackupLocalVolumeRoot(L"\\\\server\\share\\wallet"));
    // A GUID that is not one: a wrong length, a wrong separator, a character that is not hexadecimal, no closing brace.
    BOOST_CHECK(!QuantumBackupLocalVolumeRoot(L"\\\\?\\Volume{" + guid.substr(1) + L"}\\x"));
    std::wstring bad = guid;
    bad[8] = L'_';
    BOOST_CHECK(!QuantumBackupLocalVolumeRoot(L"\\\\?\\Volume{" + bad + L"}\\x"));
    bad = guid;
    bad[0] = L'g';
    BOOST_CHECK(!QuantumBackupLocalVolumeRoot(L"\\\\?\\Volume{" + bad + L"}\\x"));
    BOOST_CHECK(!QuantumBackupLocalVolumeRoot(L"\\\\?\\Volume{" + guid + L"]\\x"));
    // Any path the locality check cannot tie to a local volume leaves no drive type to ask about, and a drive type that
    // is not a fixed disk is refused whatever the file system: both ends of the pair are needed.
    BOOST_CHECK(QuantumBackupVolumeRejection("NTFS", QUANTUM_BACKUP_DRIVE_UNKNOWN));
}

BOOST_AUTO_TEST_CASE(a_failed_commit_of_a_new_backup_directory_or_its_parent_entry_fails_the_preparation)
{
    const fs::path directory = m_path_root / "durable-base" / "level-one" / "wallet";
    std::string error;
    // The entry of each directory made, the wallet's own directory and the base above it: each commit failing stops it.
    for (const std::string name : {"durable-base", "level-one", "wallet"}) {
        error.clear();
        {
            ScopedDirectoryCommitFault fault{name};
            BOOST_CHECK_MESSAGE(!EnsureQuantumKeyBackupDirectory(directory, error), "commit of " << name << " did not fail the preparation");
            BOOST_CHECK_MESSAGE(error.find("durable") != std::string::npos, error);
            // The directories now exist (a failed attempt left them in the page cache), yet the next attempt does not
            // take them as durable: the same failure is seen again.
            error.clear();
            BOOST_CHECK_MESSAGE(!EnsureQuantumKeyBackupDirectory(directory, error), "retry skipped the commit of " << name);
            BOOST_CHECK(error.find("durable") != std::string::npos);
        }
    }
    // The fault is for a test chain only.
    SelectParams(ChainType::MAIN);
    gArgs.ForceSetArg("-quantumreturnfailcommit", "wallet");
    error.clear();
    BOOST_CHECK_MESSAGE(EnsureQuantumKeyBackupDirectory(directory, error), error);
    // And without it the directories are made and committed.
    gArgs.ForceSetArg("-quantumreturnfailcommit", "");
    const fs::path other = m_path_root / "durable-other" / "wallet";
    BOOST_CHECK_MESSAGE(EnsureQuantumKeyBackupDirectory(other, error), error);
    BOOST_CHECK(fs::is_directory(other));
}

namespace {
/** Records every directory the backup code commits, can make named ones fail, and restores the real commit. */
class ScopedCommitRecorder
{
public:
    ScopedCommitRecorder()
    {
        SetQuantumKeyBackupDirectoryCommitForTest([this](const fs::path& path) {
            committed.push_back(path);
            return failing.count(path) == 0;
        });
    }
    ~ScopedCommitRecorder() { SetQuantumKeyBackupDirectoryCommitForTest({}); }
    bool Committed(const fs::path& path) const { return std::find(committed.begin(), committed.end(), path) != committed.end(); }

    std::vector<fs::path> committed;
    std::set<fs::path> failing;
};
} // namespace

// A directory made by an earlier attempt that was interrupted between its creation and the commit of its parent's
// entry exists when the retry runs: only the new directories below it are made. The retry still commits the whole
// chain, the ancestor that holds the entry of the interrupted one included, up to the root of the file system for a
// directory outside the data directory.
BOOST_AUTO_TEST_CASE(a_retry_commits_every_ancestor_an_interrupted_attempt_may_have_left_uncommitted)
{
    const fs::path base = m_path_root / "retry-base";
    const fs::path first = base / "a";
    const fs::path directory = first / "b" / "wallet";
    // The earlier attempt made "a" and stopped before the entry of "a" in "retry-base" was committed.
    BOOST_REQUIRE(fs::create_directories(first));
    ScopedCommitRecorder recorder;
    std::string error;
    BOOST_REQUIRE_MESSAGE(EnsureQuantumKeyBackupDirectory(directory, error), error);
    BOOST_CHECK(fs::is_directory(directory));
    // The wallet's directory, every ancestor, and so the entry of each in the directory above it.
    for (const fs::path& path : std::vector<fs::path>{directory, directory.parent_path(), first, base, m_path_root}) {
        BOOST_CHECK_MESSAGE(recorder.Committed(path), "the retry did not commit " << fs::PathToString(path));
    }
    // Up to the data directory, which the node made, and no further for a directory below it.
    const fs::path datadir = gArgs.GetDataDirNet();
    BOOST_CHECK(recorder.Committed(datadir));
    BOOST_CHECK(!recorder.Committed(datadir.parent_path()));
}

// Below the data directory the walk ends at the data directory; for a directory outside it, there is nothing known
// that the node made, so it goes up to the root of the file system.
BOOST_AUTO_TEST_CASE(a_directory_outside_the_data_directory_is_committed_up_to_the_root)
{
    const fs::path outside = GetUniquePath(fs::temp_directory_path() / "quantum-backup-outside");
    const fs::path directory = outside / "inner" / "wallet";
    ScopedCommitRecorder recorder;
    std::string error;
    const bool made = EnsureQuantumKeyBackupDirectory(directory, error);
    std::error_code ignored;
    fs::remove_all(outside, ignored);
    BOOST_REQUIRE_MESSAGE(made, error);
    for (const fs::path& path : std::vector<fs::path>{directory, directory.parent_path(), outside, outside.parent_path(), outside.root_path()}) {
        BOOST_CHECK_MESSAGE(recorder.Committed(path), "not committed: " << fs::PathToString(path));
    }
}

// A failed commit leaves the directories it made (nothing relies on taking them away again, which can fail too), and
// the retry commits all of them.
BOOST_AUTO_TEST_CASE(a_failed_commit_leaves_its_directories_and_the_retry_commits_the_whole_chain)
{
    const fs::path base = m_path_root / "failed-removal-base";
    const fs::path directory = base / "a" / "wallet";
    ScopedCommitRecorder recorder;
    std::string error;
    // The commit of the directory that holds the entry of "a" fails: the preparation fails.
    recorder.failing.insert(base);
    BOOST_CHECK(!EnsureQuantumKeyBackupDirectory(directory, error));
    BOOST_CHECK_MESSAGE(error.find("durable") != std::string::npos, error);
    BOOST_CHECK(fs::is_directory(directory)); // left in place
    // The retry, with the disk working again, commits the wallet's directory, "a", the base and everything above it,
    // although every directory exists already and nothing has to be made.
    recorder.failing.clear();
    recorder.committed.clear();
    error.clear();
    BOOST_REQUIRE_MESSAGE(EnsureQuantumKeyBackupDirectory(directory, error), error);
    for (const fs::path& path : std::vector<fs::path>{directory, directory.parent_path(), base, m_path_root}) {
        BOOST_CHECK_MESSAGE(recorder.Committed(path), "the retry did not commit " << fs::PathToString(path));
    }
}

BOOST_AUTO_TEST_CASE(the_backup_directory_defaults_under_the_network_data_directory)
{
    ArgsManager& args = *Assert(m_node.args);
    BOOST_CHECK_EQUAL(QuantumKeyBackupBaseDirectory(), args.GetDataDirNet() / "quantum-key-backups");
    BOOST_CHECK_EQUAL(QuantumKeyBackupDirectory(""), args.GetDataDirNet() / "quantum-key-backups" / "default");
    args.ForceSetArg("-quantumkeybackupdir", "elsewhere");
    BOOST_CHECK_EQUAL(QuantumKeyBackupBaseDirectory(), args.GetDataDirNet() / "elsewhere");
    const fs::path absolute = m_path_root / "absolute-backups";
    args.ForceSetArg("-quantumkeybackupdir", fs::PathToString(absolute));
    BOOST_CHECK_EQUAL(QuantumKeyBackupDirectory("w"), absolute / "n_w");
    args.ForceSetArg("-quantumkeybackupdir", "");
    BOOST_CHECK_EQUAL(QuantumKeyBackupBaseDirectory(), args.GetDataDirNet() / "quantum-key-backups");
}

BOOST_AUTO_TEST_SUITE_END()
} // namespace wallet
