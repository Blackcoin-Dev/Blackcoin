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
#include <map>
#include <optional>
#include <set>
#include <string>
#include <tuple>
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
        // when key 0 is no longer a live key, the oldest generation still holds a key this wallet does not know, which
        // another generation may be the only protector of for another process: it stays, and the redundant g2 goes
        doomed = SelectQuantumKeyBackupsToPrune(generations, Keys({1, 2, 3, 4, 5}), 3);
        BOOST_CHECK(doomed == std::set<std::string>{"g2"});
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

// Four processes share one directory and each makes generations that hold its own key and the others it has seen.
// A generation that holds a key this wallet does not know is never doomed on this wallet's word, so every
// generation holding another clone's unique key survives, and the generations this wallet alone covers still go.
BOOST_AUTO_TEST_CASE(a_generation_holding_a_key_the_wallet_does_not_know_survives_pruning)
{
    // this wallet holds key 1; clones 2, 3 and 4 made keys of their own
    std::vector<QuantumKeyBackupGeneration> generations{
        Generation("own1", 1, {1}),    Generation("clone2", 2, {1, 2}), Generation("clone3", 3, {1, 3}),
        Generation("clone4", 4, {1, 4}), Generation("own2", 5, {1}),      Generation("own3", 6, {1}),
        Generation("own4", 7, {1}),
    };
    auto doomed = SelectQuantumKeyBackupsToPrune(generations, Keys({1}), 3);
    // own4, own3 and own2 are the newest three; each clone generation holds a foreign key; own1 holds only key 1,
    // which the newer retained generations cover
    BOOST_CHECK(doomed == std::set<std::string>{"own1"});

    // a foreign key a newer retained generation already holds does not protect the older generation: only a key that
    // the newer retained generations do not hold, or that the wallet does not know, does. Here the foreign key 9 is
    // not live, so it is "unknown to the wallet" and keeps g2 anyway.
    generations = {Generation("g1", 1, {1, 9}), Generation("g2", 2, {1, 9}), Generation("g3", 3, {1, 9}),
                   Generation("g4", 4, {1, 9}), Generation("g5", 5, {1, 9})};
    doomed = SelectQuantumKeyBackupsToPrune(generations, Keys({1}), 3);
    BOOST_CHECK(doomed.empty());
    // the same generations when the wallet does know key 9 (both live): the redundant ones go
    doomed = SelectQuantumKeyBackupsToPrune(generations, Keys({1, 9}), 3);
    BOOST_CHECK((doomed == std::set<std::string>{"g1", "g2"}));

    // a key since removed from the wallet keeps only the generations that hold it
    generations = {Generation("old", 1, {1, 2}), Generation("a", 2, {1}), Generation("b", 3, {1}), Generation("c", 4, {1}),
                   Generation("d", 5, {1})};
    doomed = SelectQuantumKeyBackupsToPrune(generations, Keys({1}), 3);
    BOOST_CHECK(doomed == std::set<std::string>{"a"});

    // keep_newest of zero keeps nothing for its own sake: only the live-key and unknown-key rules protect
    generations = {Generation("g1", 1, {1}), Generation("g2", 2, {1}), Generation("g3", 3, {1, 2})};
    doomed = SelectQuantumKeyBackupsToPrune(generations, Keys({1, 2}), 0);
    // g3 holds live keys 1 and 2 that no newer generation holds: kept; g2 and g1 hold only key 1, covered by g3
    BOOST_CHECK((doomed == std::set<std::string>{"g1", "g2"}));
    generations = {Generation("g1", 1, {1}), Generation("g2", 2, {1})};
    doomed = SelectQuantumKeyBackupsToPrune(generations, Keys({1}), 0);
    // the newest holds a live key nothing newer holds, so it stays; the older one is covered by it
    BOOST_CHECK(doomed == std::set<std::string>{"g1"});

    // equal sequences are ordered by file name, descending; only retained generations cover
    generations = {Generation("a", 5, {1}), Generation("b", 5, {1}), Generation("c", 5, {1}), Generation("d", 5, {1}),
                   Generation("e", 5, {1, 2})};
    doomed = SelectQuantumKeyBackupsToPrune(generations, Keys({1, 2}), 3);
    // order: e, d, c, b, a; the newest three are e, d, c; b and a hold only key 1, covered by the retained ones
    BOOST_CHECK((doomed == std::set<std::string>{"a", "b"}));

    // an unverified generation neither protects nor is chosen, and a generation with no keys is covered by anything
    generations = {Generation("v1", 1, {}), Generation("v2", 2, {1}), Generation("v3", 3, {1}), Generation("v4", 4, {1}),
                   Generation("u", 5, {7}, /*verified=*/false)};
    doomed = SelectQuantumKeyBackupsToPrune(generations, Keys({1}), 3);
    BOOST_CHECK(doomed == std::set<std::string>{"v1"});
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

BOOST_AUTO_TEST_CASE(a_double_separator_prefix_is_recognised_in_every_spelling)
{
    for (const std::string value : {
             R"(\\host\share\dir)", "//host/share/dir", R"(\/host\share)", R"(/\host/share)", R"(\\?\C:\dir)",
             R"(\\?\UNC\host\share)", R"(\\.\)", R"(\\.\PhysicalDrive0)", R"(\\)", "//", R"(\\\host\share)", "///dir"}) {
        BOOST_CHECK_MESSAGE(QuantumBackupPathHasWindowsDoubleSeparatorPrefix(value), value);
    }
    for (const std::string value : {
             "", R"(\)", "/", "a", "elsewhere", R"(relative\dir)", "relative/dir", R"(C:\dir)", "C:/dir", "C:dir", "D:dir",
             R"(\dir)", "/dir", R"(C:\\dir)", R"(dir\\sub)", "dir//sub", R"(a\\)", R"(.\\host\share)"}) {
        BOOST_CHECK_MESSAGE(!QuantumBackupPathHasWindowsDoubleSeparatorPrefix(value), value);
    }
}

namespace {
/** The Windows rule for a double separator prefix on whatever platform runs the test, and the platform's own again. */
class ScopedWindowsPathRules
{
public:
    explicit ScopedWindowsPathRules(bool rules) { SetQuantumKeyBackupWindowsPathRulesForTest(rules); }
    ~ScopedWindowsPathRules() { SetQuantumKeyBackupWindowsPathRulesForTest(std::nullopt); }
};
} // namespace

// The Windows build's std::filesystem takes `\\host\share` for a relative path, so joining it to the data directory
// made a local folder on that drive. Under the Windows rule the value keeps its spelling.
BOOST_AUTO_TEST_CASE(a_network_or_device_backup_path_is_never_joined_to_the_data_directory)
{
    ArgsManager& args = *Assert(m_node.args);
    const ScopedWindowsPathRules windows{true};
    for (const std::string value : {R"(\\host\share\backups)", "//host/share/backups", R"(\\?\C:\backups)", R"(\\?\UNC\host\share)", R"(\\.\)"}) {
        args.ForceSetArg("-quantumkeybackupdir", value);
        BOOST_CHECK_EQUAL(fs::PathToString(QuantumKeyBackupBaseDirectory()), value);
        const std::string wallet_directory = fs::PathToString(QuantumKeyBackupDirectory("w"));
        BOOST_CHECK_MESSAGE(wallet_directory.compare(0, value.size(), value) == 0, wallet_directory);
        BOOST_CHECK_MESSAGE(QuantumBackupPathHasWindowsDoubleSeparatorPrefix(wallet_directory), wallet_directory);
    }
    // everything else resolves as before
    args.ForceSetArg("-quantumkeybackupdir", "elsewhere");
    BOOST_CHECK_EQUAL(QuantumKeyBackupBaseDirectory(), args.GetDataDirNet() / "elsewhere");
    const fs::path absolute = m_path_root / "absolute-backups";
    args.ForceSetArg("-quantumkeybackupdir", fs::PathToString(absolute));
    BOOST_CHECK_EQUAL(QuantumKeyBackupDirectory("w"), absolute / "n_w");
    args.ForceSetArg("-quantumkeybackupdir", "");
    BOOST_CHECK_EQUAL(QuantumKeyBackupBaseDirectory(), args.GetDataDirNet() / "quantum-key-backups");
}

#ifndef WIN32
// On POSIX `//dir` names the same directory as `/dir`, which lets these tests show on a real directory that the
// refusal comes before anything is looked up, created, committed or removed.
BOOST_AUTO_TEST_CASE(a_network_or_device_backup_path_is_refused_before_the_file_system_is_touched)
{
    const fs::path real = m_path_root / "share-root" / "backups" / "n_w";
    const fs::path spelled = fs::PathFromString("/" + fs::PathToString(real));
    BOOST_REQUIRE(QuantumBackupPathHasWindowsDoubleSeparatorPrefix(fs::PathToString(spelled)));
    ScopedCommitRecorder recorder;
    std::string error;
    {
        const ScopedWindowsPathRules windows{true};
        BOOST_CHECK(!EnsureQuantumKeyBackupDirectory(spelled, error));
        BOOST_CHECK_MESSAGE(error.find("cannot make the backup directory " + fs::PathToString(spelled) + " durable: a network or device path is not supported; use a folder on a local NTFS volume") == 0, error);
        BOOST_CHECK(recorder.committed.empty());
        BOOST_CHECK(!fs::exists(m_path_root / "share-root"));
    }
    // without the rule the same spelling is an ordinary directory, so the refusal above was the rule's
    error.clear();
    BOOST_REQUIRE_MESSAGE(EnsureQuantumKeyBackupDirectory(spelled, error), error);
    BOOST_CHECK(fs::is_directory(real));
    BOOST_CHECK(!recorder.committed.empty());
}

BOOST_AUTO_TEST_CASE(a_network_or_device_backup_path_is_never_pruned)
{
    const fs::path real = m_path_root / "share-prune";
    const fs::path spelled = fs::PathFromString("/" + fs::PathToString(real));
    std::string error;
    BOOST_REQUIRE_MESSAGE(EnsureQuantumKeyBackupDirectory(real, error), error);
    std::vector<std::string> names;
    for (int i = 1; i <= 5; ++i) {
        const std::string name = QuantumKeyBackupFileName(1'798'000'000 + i, 100 + i, NewQuantumKeyBackupSuffix());
        names.push_back(name);
        std::ofstream{real / fs::PathFromString(name), std::ios::binary} << "wallet";
        BOOST_REQUIRE_MESSAGE(WriteQuantumKeyBackupManifest(real, name, static_cast<uint64_t>(i), Keys({1, 2}), error), error);
    }
    {
        const ScopedWindowsPathRules windows{true};
        BOOST_CHECK_EQUAL(PruneQuantumKeyBackups(spelled, Keys({1, 2}), 3), size_t{0});
        for (const std::string& name : names) {
            BOOST_CHECK(fs::exists(real / fs::PathFromString(name)));
            BOOST_CHECK(fs::exists(real / fs::PathFromString(name + ".keys")));
        }
    }
    // without the rule the same call prunes, so the generations above were kept by the rule
    BOOST_CHECK_EQUAL(PruneQuantumKeyBackups(spelled, Keys({1, 2}), 3), size_t{2});
}
#endif

// A drive-relative path (`D:dir`) and a root-relative one (`\dir`) are resolved by Windows against the current directory
// of that drive or the drive of the current directory, never against the data directory.
BOOST_AUTO_TEST_CASE(a_drive_or_root_relative_path_is_recognised)
{
    for (const std::string value : {"D:", "d:", "Z:", "D:dir", "D:dir/sub", R"(D:dir\sub)", "D:.", "D:..", R"(\dir)", "/dir",
                                    R"(\)", "/", R"(\dir\sub)", "/dir/sub", R"(\x:)"}) {
        BOOST_CHECK_MESSAGE(QuantumBackupPathIsWindowsDriveOrRootRelative(value), value);
    }
    for (const std::string value : {R"(D:\dir)", "D:/dir", R"(D:\)", "D:/", R"(D:\\dir)", "d:/a/b", "", "dir", "relative/dir",
                                    R"(relative\dir)", "backups", ".", "..", "./dir", R"(.\dir)", "1:dir", "D", "DD:dir",
                                    R"(\\host\share)", "//host/share", R"(\\?\C:\dir)", "d"}) {
        BOOST_CHECK_MESSAGE(!QuantumBackupPathIsWindowsDriveOrRootRelative(value), value);
    }
    // the double separator rule is unchanged and separate: those values are caught by it, not by this one
    for (const std::string value : {R"(\\host\share)", "//host/share", R"(\\?\C:\dir)"}) {
        BOOST_CHECK(QuantumBackupPathHasWindowsDoubleSeparatorPrefix(value));
    }
}

BOOST_AUTO_TEST_CASE(a_drive_or_root_relative_backup_path_is_refused_with_its_own_message_and_never_joined)
{
    ArgsManager& args = *Assert(m_node.args);
    const std::string network = "a network or device path is not supported";
    const std::string relative = "relative to a drive or to the root of a drive";
    {
        // off Windows the spelling is not examined at all
        const ScopedWindowsPathRules posix{false};
        for (const std::string value : {"D:", "D:dir", R"(\dir)", "/dir", R"(\\host\share)"}) {
            BOOST_CHECK(!QuantumKeyBackupSpellingRejection(value));
        }
    }
    const ScopedWindowsPathRules windows{true};
    for (const std::string value : {"D:", "D:dir", R"(D:dir\sub)", R"(\dir)", "/dir", R"(\)", "/"}) {
        const auto rejection = QuantumKeyBackupSpellingRejection(value);
        BOOST_REQUIRE_MESSAGE(rejection, value);
        BOOST_CHECK_MESSAGE(rejection->find(relative) != std::string::npos, *rejection);
        BOOST_CHECK_MESSAGE(rejection->find(network) == std::string::npos, *rejection);
        // the spelling is kept, so the refusal is of what was written and the data directory is not prefixed
        args.ForceSetArg("-quantumkeybackupdir", value);
        BOOST_CHECK_EQUAL(fs::PathToString(QuantumKeyBackupBaseDirectory()), value);
    }
    for (const std::string value : {R"(\\host\share)", "//host/share", R"(\\?\C:\dir)"}) {
        const auto rejection = QuantumKeyBackupSpellingRejection(value);
        BOOST_REQUIRE_MESSAGE(rejection, value);
        BOOST_CHECK_MESSAGE(rejection->find(network) != std::string::npos, *rejection);
    }
    // valid spellings are accepted and resolve as before
    for (const std::string value : {R"(D:\dir)", "D:/dir", R"(D:\)", "elsewhere", "a/b", R"(a\b)"}) {
        BOOST_CHECK_MESSAGE(!QuantumKeyBackupSpellingRejection(value), value);
    }
    args.ForceSetArg("-quantumkeybackupdir", "elsewhere");
    BOOST_CHECK_EQUAL(QuantumKeyBackupBaseDirectory(), args.GetDataDirNet() / "elsewhere");
    args.ForceSetArg("-quantumkeybackupdir", "");
}

#ifndef WIN32
BOOST_AUTO_TEST_CASE(a_drive_or_root_relative_backup_path_is_refused_before_the_file_system_is_touched)
{
    ArgsManager& args = *Assert(m_node.args);
    const ScopedWindowsPathRules windows{true};
    ScopedCommitRecorder recorder;
    for (const std::string value : {"D:dir", R"(\dir)", "/dir-qkb-d7"}) {
        args.ForceSetArg("-quantumkeybackupdir", value);
        const fs::path directory = QuantumKeyBackupDirectory("w");
        std::string error;
        BOOST_CHECK(!EnsureQuantumKeyBackupDirectory(directory, error));
        BOOST_CHECK_MESSAGE(error.find("cannot make the backup directory " + fs::PathToString(directory) + " durable: a path that is relative to a drive") == 0, error);
        BOOST_CHECK(recorder.committed.empty());
        BOOST_CHECK(!fs::exists(directory));
        // never pruned either
        BOOST_CHECK_EQUAL(PruneQuantumKeyBackups(directory, Keys({1}), 3), size_t{0});
    }
    BOOST_CHECK(!fs::exists(fs::PathFromString("D:dir")));
    args.ForceSetArg("-quantumkeybackupdir", "");
}
#endif

// UTF-16 code units, which is what Windows counts: a character outside the Basic Multilingual Plane is two.
BOOST_AUTO_TEST_CASE(utf16_length_counts_code_units_not_bytes_or_characters)
{
    BOOST_CHECK_EQUAL(QuantumBackupUtf16Length(""), size_t{0});
    BOOST_CHECK_EQUAL(QuantumBackupUtf16Length("abc"), size_t{3});
    BOOST_CHECK_EQUAL(QuantumBackupUtf16Length("\xC3\xA9"), size_t{1});         // U+00E9, two bytes
    BOOST_CHECK_EQUAL(QuantumBackupUtf16Length("\xE2\x82\xAC"), size_t{1});     // U+20AC, three bytes
    BOOST_CHECK_EQUAL(QuantumBackupUtf16Length("\xF0\x9F\x98\x80"), size_t{2}); // U+1F600, four bytes: a surrogate pair
    BOOST_CHECK_EQUAL(QuantumBackupUtf16Length("a\xF0\x9F\x98\x80" "b\xC3\xA9"), size_t{5});
}

BOOST_AUTO_TEST_CASE(the_length_bound_ties_to_the_staging_and_verification_names)
{
    // `\.blackcoin-wallet-backup-stage-<16>` and `\.blackcoin-quantum-backup-verify-<16>` and `\wallet.dat`
    BOOST_CHECK_EQUAL(QUANTUM_BACKUP_STAGE_FOLDER_PREFIX.size(), size_t{31});
    BOOST_CHECK_EQUAL(QUANTUM_BACKUP_VERIFY_FOLDER_PREFIX.size(), size_t{33});
    BOOST_CHECK_EQUAL(QUANTUM_BACKUP_WORK_PATH_UNITS, size_t{109});
    BOOST_CHECK_EQUAL(QUANTUM_BACKUP_WINDOWS_MAX_DIRECTORY_UNITS, size_t{150});
    // the folders the backup code makes are exactly that long
    const fs::path unique = GetUniquePath(fs::path{});
    BOOST_CHECK_EQUAL(fs::PathToString(unique.filename()).size(), QUANTUM_BACKUP_UNIQUE_NAME_CHARS);
    // 98 units for the deepest directory below the wallet's directory, and the copy's file name inside it
    BOOST_CHECK_EQUAL(QUANTUM_BACKUP_WORK_PATH_UNITS - (1 + QUANTUM_BACKUP_COPY_FILE_NAME.size()), size_t{98});
}

BOOST_AUTO_TEST_CASE(a_wallet_backup_directory_longer_than_150_units_is_refused)
{
    const auto path_of = [](size_t length, const std::string& tail = "") {
        std::string value = "x";
        value.resize(length - tail.size(), 'x');
        return fs::PathFromString(value + tail);
    };
    {
        // off Windows the length is not limited
        const ScopedWindowsPathRules posix{false};
        BOOST_CHECK(!QuantumKeyBackupLengthRejection(path_of(500)));
    }
    const ScopedWindowsPathRules windows{true};
    BOOST_CHECK(!QuantumKeyBackupLengthRejection(path_of(1)));
    BOOST_CHECK(!QuantumKeyBackupLengthRejection(path_of(149)));
    BOOST_CHECK(!QuantumKeyBackupLengthRejection(path_of(150)));
    const auto rejection = QuantumKeyBackupLengthRejection(path_of(151));
    BOOST_REQUIRE(rejection);
    BOOST_CHECK_MESSAGE(rejection->find("the path is too long: it has 151 characters and at most 150 are allowed") == 0, *rejection);
    BOOST_CHECK(QuantumKeyBackupLengthRejection(path_of(152)));
    BOOST_CHECK(QuantumKeyBackupLengthRejection(path_of(1000)));
    // a character outside the Basic Multilingual Plane counts two: 148 + 2 = 150 passes, 149 + 2 = 151 does not
    const std::string pair = "\xF0\x9F\x98\x80";
    BOOST_CHECK(!QuantumKeyBackupLengthRejection(fs::PathFromString(std::string(148, 'x') + pair)));
    BOOST_CHECK(QuantumKeyBackupLengthRejection(fs::PathFromString(std::string(149, 'x') + pair)));
    // a character of two or three bytes counts one, however many bytes the path has
    BOOST_CHECK(!QuantumKeyBackupLengthRejection(fs::PathFromString(std::string(75, 'x') + "\xC3\xA9\xC3\xA9" + std::string(71, 'x'))));
}

namespace {
/** Resolve the backup directory against a data directory of the test's choosing, and the node's again afterwards. */
class ScopedBackupDataDirectory
{
public:
    explicit ScopedBackupDataDirectory(const std::string& data_directory)
    {
        SetQuantumKeyBackupDataDirectoryForTest(fs::PathFromString(data_directory));
    }
    ~ScopedBackupDataDirectory() { SetQuantumKeyBackupDataDirectoryForTest(std::nullopt); }
};

/** The units of the wallet's resolved backup directory. */
size_t DirectoryUnits(const std::string& wallet_name)
{
    return QuantumBackupUtf16Length(fs::PathToString(QuantumKeyBackupDirectory(wallet_name)));
}
} // namespace

// The bound is on the resolved per-wallet directory: the base (the data directory with a relative option), the wallet's
// component and the separators. The data directory is a short one chosen here, so the lengths 149, 150 and 151 are
// always built, whatever the length of the paths of the test run.
BOOST_AUTO_TEST_CASE(the_length_check_counts_the_resolved_wallet_directory)
{
    ArgsManager& args = *Assert(m_node.args);
    const ScopedWindowsPathRules windows{true};
    const ScopedBackupDataDirectory datadir{"/d"}; // 2 units; the resolved directory is /d/<option>/<component>
    const size_t fixed_units = 2 + 1 + 1; // the data directory and two separators
    BOOST_REQUIRE_EQUAL(QuantumKeyBackupWalletComponent("").size(), size_t{7});
    for (const size_t total : {size_t{149}, size_t{150}, size_t{151}}) {
        args.ForceSetArg("-quantumkeybackupdir", std::string(total - fixed_units - 7, 'r'));
        BOOST_REQUIRE_EQUAL(DirectoryUnits(""), total);
        const QuantumKeyBackupPathCheck check = CheckQuantumKeyBackupWalletPath("");
        BOOST_CHECK_MESSAGE(check.error.has_value() == (total > 150), total << ": " << (check.error ? *check.error : std::string{"accepted"}));
        BOOST_CHECK(!check.warning);
        BOOST_CHECK_EQUAL(QuantumKeyBackupWalletPathRejection("").has_value(), total > 150);
    }
    // a long wallet name has a component of 83 characters at most: it is that resolved directory that is counted
    const std::string long_name(200, 'W');
    BOOST_REQUIRE_EQUAL(QuantumKeyBackupWalletComponent(long_name).size(), size_t{83});
    for (const size_t total : {size_t{150}, size_t{151}}) {
        args.ForceSetArg("-quantumkeybackupdir", std::string(total - fixed_units - 83, 'r'));
        BOOST_REQUIRE_EQUAL(DirectoryUnits(long_name), total);
        const auto rejection = QuantumKeyBackupWalletPathRejection(long_name);
        BOOST_CHECK_MESSAGE(rejection.has_value() == (total > 150), total << ": " << (rejection ? *rejection : std::string{"accepted"}));
        // the same option for the unnamed wallet is 76 units shorter and fits
        BOOST_CHECK(!QuantumKeyBackupWalletPathRejection(""));
    }
    // a long name that fits: the component is 50 characters of the encoded name, "~" and 32 hex digits only above 80
    const std::string fitting_name(40, 'a'); // "n_" + 40 = 42 characters
    BOOST_REQUIRE_EQUAL(QuantumKeyBackupWalletComponent(fitting_name).size(), size_t{42});
    args.ForceSetArg("-quantumkeybackupdir", std::string(150 - fixed_units - 42, 'r'));
    BOOST_REQUIRE_EQUAL(DirectoryUnits(fitting_name), size_t{150});
    BOOST_CHECK(!QuantumKeyBackupWalletPathRejection(fitting_name));
    // a spelling the rules refuse is reported first
    args.ForceSetArg("-quantumkeybackupdir", "D:dir");
    const auto spelling = QuantumKeyBackupWalletPathRejection("w");
    BOOST_REQUIRE(spelling);
    BOOST_CHECK(spelling->find("-quantumkeybackupdir: ") == 0);
    args.ForceSetArg("-quantumkeybackupdir", "");
}

// A default path (the option unset or empty) is not a choice the user made, and ordinary wallet use does not need the
// room a backup does: too long, it only warns and the wallet loads; the automatic backup is refused when it is made.
BOOST_AUTO_TEST_CASE(an_overlong_default_backup_path_warns_and_an_overlong_chosen_one_refuses)
{
    ArgsManager& args = *Assert(m_node.args);
    const ScopedWindowsPathRules windows{true};
    // D:\<n characters>/quantum-key-backups/default is 150 or 151 units. The option is set to the empty string here, so the
    // test does not depend on what an earlier test left behind; the production check reads it with an empty fallback, so
    // an option that was never set gives the same answer.
    args.ForceSetArg("-quantumkeybackupdir", "");
    BOOST_REQUIRE(args.GetArg("-quantumkeybackupdir", "x").empty());
    for (const size_t total : {size_t{150}, size_t{151}}) {
        const ScopedBackupDataDirectory datadir{R"(D:\)" + std::string(total - 28 - 3, 'x')};
        BOOST_REQUIRE_EQUAL(DirectoryUnits(""), total);
        const QuantumKeyBackupPathCheck check = CheckQuantumKeyBackupWalletPath("");
        BOOST_CHECK_MESSAGE(!check.error, total << ": " << (check.error ? *check.error : ""));
        BOOST_CHECK_EQUAL(check.warning.has_value(), total > 150);
        if (check.warning) {
            BOOST_CHECK_MESSAGE(check.warning->find("The wallet loads") != std::string::npos &&
                                check.warning->find("-quantumkeybackupdir") != std::string::npos, *check.warning);
        }
        BOOST_CHECK(!QuantumKeyBackupWalletPathRejection(""));
        // the automatic backup itself is refused at runtime, before the file system is touched
        if (total > 150) {
            ScopedCommitRecorder recorder;
            std::string error;
            const fs::path directory = QuantumKeyBackupDirectory("");
            BOOST_CHECK(!EnsureQuantumKeyBackupDirectory(directory, error));
            BOOST_CHECK_MESSAGE(error.find("the path is too long") != std::string::npos &&
                                error.find("-quantumkeybackupdir") != std::string::npos, error);
            BOOST_CHECK(recorder.committed.empty());
        }
    }
    // the same length chosen with the option is a refusal
    const ScopedBackupDataDirectory datadir{"/d"};
    args.ForceSetArg("-quantumkeybackupdir", std::string(151 - 4 - 7, 'r'));
    BOOST_REQUIRE_EQUAL(DirectoryUnits(""), size_t{151});
    BOOST_CHECK(CheckQuantumKeyBackupWalletPath("").error);
    BOOST_CHECK(!CheckQuantumKeyBackupWalletPath("").warning);
    args.ForceSetArg("-quantumkeybackupdir", "");
}

// A migration publishes the wallet, and <name>_watchonly and <name>_solvables only when it needs them. Exactly the names of
// its plan are checked.
BOOST_AUTO_TEST_CASE(a_migration_is_checked_for_exactly_the_names_it_publishes)
{
    ArgsManager& args = *Assert(m_node.args);
    const ScopedWindowsPathRules windows{true};
    const ScopedBackupDataDirectory datadir{"/d"};
    BOOST_CHECK((QuantumKeyBackupMigrationNames("w", false, false) == std::vector<std::string>{"w"}));
    BOOST_CHECK((QuantumKeyBackupMigrationNames("w", true, false) == std::vector<std::string>{"w", "w_watchonly"}));
    BOOST_CHECK((QuantumKeyBackupMigrationNames("w", false, true) == std::vector<std::string>{"w", "w_solvables"}));
    BOOST_CHECK((QuantumKeyBackupMigrationNames("", true, true) == std::vector<std::string>{"", "default_wallet_watchonly", "default_wallet_solvables"}));
    const size_t fixed_units = 2 + 1 + 1;
    const size_t original = QuantumKeyBackupWalletComponent("w").size();
    const size_t auxiliary = QuantumKeyBackupWalletComponent("w_watchonly").size();
    BOOST_REQUIRE(auxiliary > original);
    // the original name fits exactly (150) and both auxiliary names (162) do not: a migration that needs neither is accepted
    args.ForceSetArg("-quantumkeybackupdir", std::string(150 - fixed_units - original, 'r'));
    BOOST_REQUIRE_EQUAL(DirectoryUnits("w"), size_t{150});
    QuantumKeyBackupPathCheck check = CheckQuantumKeyBackupMigrationPaths("w", false, false);
    BOOST_CHECK(!check.error && !check.warning);
    // and refused, naming the auxiliary wallet, as soon as the plan needs one of them
    for (const auto& [watchonly, solvables, named] : {std::tuple{true, false, "w_watchonly"}, std::tuple{false, true, "w_solvables"},
                                                      std::tuple{true, true, "w_watchonly"}}) {
        check = CheckQuantumKeyBackupMigrationPaths("w", watchonly, solvables);
        BOOST_REQUIRE_MESSAGE(check.error, named);
        BOOST_CHECK_MESSAGE(check.error->find(std::string{"wallet \""} + named + "\"") != std::string::npos, *check.error);
    }
    // the original name is too long: refused, naming it
    args.ForceSetArg("-quantumkeybackupdir", std::string(151 - fixed_units - original, 'r'));
    check = CheckQuantumKeyBackupMigrationPaths("w", false, false);
    BOOST_REQUIRE(check.error);
    BOOST_CHECK_MESSAGE(check.error->find("wallet \"w\"") != std::string::npos, *check.error);
    // a configured path that fits for every name of the plan
    args.ForceSetArg("-quantumkeybackupdir", std::string(150 - fixed_units - auxiliary, 'r'));
    check = CheckQuantumKeyBackupMigrationPaths("w", true, true);
    BOOST_CHECK(!check.error && !check.warning);
    // a default path that is too long only warns, and never refuses the migration
    args.ForceSetArg("-quantumkeybackupdir", "");
    SetQuantumKeyBackupDataDirectoryForTest(fs::PathFromString("/" + std::string(140, 'x')));
    check = CheckQuantumKeyBackupMigrationPaths("w", true, true);
    BOOST_CHECK(!check.error);
    BOOST_CHECK(check.warning);
}

// A default backup path can start with two separators because the data directory does (a redirected application data
// folder): the startup check reads only the option and does not see it, so the runtime check refuses it.
BOOST_AUTO_TEST_CASE(a_default_path_that_inherits_a_network_prefix_is_refused_at_runtime)
{
    ArgsManager& args = *Assert(m_node.args);
    const ScopedWindowsPathRules windows{true};
    const ScopedBackupDataDirectory datadir{R"(\\host\share\data)"};
    args.ForceSetArg("-quantumkeybackupdir", "");
    const fs::path directory = QuantumKeyBackupDirectory("w");
    BOOST_REQUIRE(QuantumBackupPathHasWindowsDoubleSeparatorPrefix(fs::PathToString(directory)));
    const QuantumKeyBackupPathCheck check = CheckQuantumKeyBackupWalletPath("w");
    BOOST_CHECK(!check.error && !check.warning);
    ScopedCommitRecorder recorder;
    std::string error;
    BOOST_CHECK(!EnsureQuantumKeyBackupDirectory(directory, error));
    BOOST_CHECK_MESSAGE(error.find("a network or device path is not supported") != std::string::npos, error);
    BOOST_CHECK(recorder.committed.empty());
    BOOST_CHECK(!fs::exists(directory));
    BOOST_CHECK_EQUAL(PruneQuantumKeyBackups(directory, Keys({1}), 3), size_t{0});
}

// A manifest with no key is not evidence of an empty wallet file: every generation this feature makes holds at least the
// key it protects, so such a file is not a verified generation and is never pruned as one.
BOOST_AUTO_TEST_CASE(a_manifest_with_no_key_is_not_a_verified_generation)
{
    const fs::path directory = m_path_root / "zero-key-manifest";
    std::string error;
    BOOST_REQUIRE_MESSAGE(EnsureQuantumKeyBackupDirectory(directory, error), error);
    std::vector<std::string> names;
    for (int i = 1; i <= 3; ++i) {
        const std::string name = QuantumKeyBackupFileName(1'798'000'000 + i, 100 + i, NewQuantumKeyBackupSuffix());
        names.push_back(name);
        std::ofstream{directory / fs::PathFromString(name), std::ios::binary} << "wallet";
        BOOST_REQUIRE_MESSAGE(WriteQuantumKeyBackupManifest(directory, name, static_cast<uint64_t>(i), i == 1 ? Keys({}) : Keys({1}), error), error);
    }
    for (const QuantumKeyBackupGeneration& generation : ListQuantumKeyBackupGenerations(directory)) {
        BOOST_CHECK_MESSAGE(generation.verified == (generation.file_name != names[0]), generation.file_name);
    }
    BOOST_CHECK_EQUAL(NextQuantumKeyBackupSequence(directory), uint64_t{4}); // the manifest with no key does not count
    // never pruned: not even with nothing to keep
    BOOST_CHECK_EQUAL(PruneQuantumKeyBackups(directory, Keys({1}), 0), size_t{1}); // only the verified duplicate of key 1 older than the newest
    BOOST_CHECK(fs::exists(directory / fs::PathFromString(names[0])));
}

#ifndef WIN32
BOOST_AUTO_TEST_CASE(a_backup_directory_that_is_too_long_is_refused_before_the_file_system_is_touched)
{
    const ScopedWindowsPathRules windows{true};
    ScopedCommitRecorder recorder;
    // a relative spelling passes the spelling rule, so it is the length that refuses it
    const std::string name(151, 'x');
    const fs::path directory = fs::PathFromString("qkb-d8-top/" + name.substr(11));
    BOOST_REQUIRE_EQUAL(QuantumBackupUtf16Length(fs::PathToString(directory)), size_t{151});
    std::string error;
    BOOST_CHECK(!EnsureQuantumKeyBackupDirectory(directory, error));
    BOOST_CHECK_MESSAGE(error.find("cannot make the backup directory " + fs::PathToString(directory) + " durable: the path is too long: it has 151 characters and at most 150 are allowed") == 0, error);
    BOOST_CHECK(recorder.committed.empty());
    BOOST_CHECK(!fs::exists(fs::PathFromString("qkb-d8-top")));
}
#endif

// The walk up from the wallet's directory stops at the data directory by its identity (volume and file index), so a
// spelling of the data directory that is not the lexical one still ends the walk there, and nothing above it is flushed.
BOOST_AUTO_TEST_CASE(the_walk_stops_at_the_data_directory_by_identity)
{
    const QuantumBackupDirectoryIdentity a{1, 2, 3};
    const QuantumBackupDirectoryIdentity same{1, 2, 3};
    const QuantumBackupDirectoryIdentity other_volume{9, 2, 3};
    const QuantumBackupDirectoryIdentity other_high{1, 9, 3};
    const QuantumBackupDirectoryIdentity other_low{1, 2, 9};
    BOOST_CHECK(a == same);
    BOOST_CHECK(!(a == other_volume));
    BOOST_CHECK(!(a == other_high));
    BOOST_CHECK(!(a == other_low));
    // both identities known: only equal identities stop the walk, whatever the paths say
    BOOST_CHECK(QuantumBackupWalkReachedDataDirectory(a, same, /*same_path=*/false));
    BOOST_CHECK(QuantumBackupWalkReachedDataDirectory(a, same, /*same_path=*/true));
    BOOST_CHECK(!QuantumBackupWalkReachedDataDirectory(a, other_volume, /*same_path=*/true));
    BOOST_CHECK(!QuantumBackupWalkReachedDataDirectory(a, other_high, /*same_path=*/false));
    BOOST_CHECK(!QuantumBackupWalkReachedDataDirectory(a, other_low, /*same_path=*/true));
    // either identity missing: the lexical comparison decides
    BOOST_CHECK(QuantumBackupWalkReachedDataDirectory(std::nullopt, a, /*same_path=*/true));
    BOOST_CHECK(!QuantumBackupWalkReachedDataDirectory(std::nullopt, a, /*same_path=*/false));
    BOOST_CHECK(QuantumBackupWalkReachedDataDirectory(a, std::nullopt, /*same_path=*/true));
    BOOST_CHECK(!QuantumBackupWalkReachedDataDirectory(a, std::nullopt, /*same_path=*/false));
    BOOST_CHECK(QuantumBackupWalkReachedDataDirectory(std::nullopt, std::nullopt, /*same_path=*/true));
    BOOST_CHECK(!QuantumBackupWalkReachedDataDirectory(std::nullopt, std::nullopt, /*same_path=*/false));
}

namespace {
/** Identities of directories by path, and the real commit restored afterwards. */
class ScopedDirectoryIdentities
{
public:
    explicit ScopedDirectoryIdentities(std::map<fs::path, QuantumBackupDirectoryIdentity> identities) : m_identities(std::move(identities))
    {
        SetQuantumKeyBackupDirectoryIdentityForTest([this](const fs::path& path) -> std::optional<QuantumBackupDirectoryIdentity> {
            const auto it = m_identities.find(path);
            if (it == m_identities.end()) return std::nullopt;
            return it->second;
        });
    }
    ~ScopedDirectoryIdentities() { SetQuantumKeyBackupDirectoryIdentityForTest({}); }

private:
    std::map<fs::path, QuantumBackupDirectoryIdentity> m_identities;
};
} // namespace

BOOST_AUTO_TEST_CASE(a_spelling_of_the_data_directory_ends_the_walk_by_identity)
{
    const fs::path datadir = gArgs.GetDataDirNet();
    // another spelling of the data directory (a different case, a short name): a different path to the same directory
    const fs::path spelled = m_path_root / "SPELLED-DATADIR";
    const fs::path directory = spelled / "backups" / "n_w";
    const QuantumBackupDirectoryIdentity identity{7, 8, 9};
    ScopedCommitRecorder recorder;
    {
        ScopedDirectoryIdentities identities{{{datadir, identity}, {spelled, identity}, {spelled / "backups", {7, 8, 10}}, {directory, {7, 8, 11}}}};
        std::string error;
        BOOST_REQUIRE_MESSAGE(EnsureQuantumKeyBackupDirectory(directory, error), error);
    }
    // the directory, its parent and the other spelling of the data directory were flushed, and nothing above it
    BOOST_CHECK(recorder.Committed(directory));
    BOOST_CHECK(recorder.Committed(spelled / "backups"));
    BOOST_CHECK(recorder.Committed(spelled));
    BOOST_CHECK(!recorder.Committed(m_path_root) || datadir == m_path_root);
    BOOST_CHECK(!recorder.Committed(spelled.parent_path()) || datadir == spelled.parent_path());
    BOOST_CHECK_EQUAL(recorder.committed.back(), spelled);
}

BOOST_AUTO_TEST_CASE(the_walk_does_not_stop_at_the_same_path_with_a_different_identity_and_falls_back_without_one)
{
    const fs::path datadir = gArgs.GetDataDirNet();
    {
        // two identities that differ override the lexical match: the walk goes on above the data directory. The
        // reference identity of the data directory is read once, first; the walk then reads the identity of the
        // same path and is given another one.
        const fs::path directory = datadir / "qkb-walk-a" / "n_w";
        ScopedCommitRecorder recorder;
        int datadir_reads{0};
        SetQuantumKeyBackupDirectoryIdentityForTest([&](const fs::path& path) -> std::optional<QuantumBackupDirectoryIdentity> {
            if (path == datadir) return QuantumBackupDirectoryIdentity{1, 1, ++datadir_reads == 1 ? 1U : 99U};
            return QuantumBackupDirectoryIdentity{1, 1, 3};
        });
        std::string error;
        const bool made = EnsureQuantumKeyBackupDirectory(directory, error);
        SetQuantumKeyBackupDirectoryIdentityForTest({});
        BOOST_REQUIRE_MESSAGE(made, error);
        BOOST_CHECK_EQUAL(datadir_reads, 2);
        BOOST_CHECK(recorder.Committed(datadir));
        BOOST_CHECK(recorder.Committed(datadir.parent_path()));
    }
    {
        // the data directory's identity is known but the walked directories give none: the path decides, as before, and
        // the walk ends at the data directory
        const fs::path directory = datadir / "qkb-walk-b" / "n_w";
        ScopedCommitRecorder recorder;
        int reads{0};
        SetQuantumKeyBackupDirectoryIdentityForTest([&](const fs::path&) -> std::optional<QuantumBackupDirectoryIdentity> {
            if (++reads == 1) return QuantumBackupDirectoryIdentity{1, 1, 1};
            return std::nullopt;
        });
        std::string error;
        const bool made = EnsureQuantumKeyBackupDirectory(directory, error);
        SetQuantumKeyBackupDirectoryIdentityForTest({});
        BOOST_REQUIRE_MESSAGE(made, error);
        BOOST_CHECK(recorder.Committed(datadir));
        BOOST_CHECK(!recorder.Committed(datadir.parent_path()));
    }
    {
        // no identity at all (the platform gives none): the same lexical walk
        const fs::path directory = datadir / "qkb-walk-c" / "n_w";
        ScopedCommitRecorder recorder;
        std::string error;
        BOOST_REQUIRE_MESSAGE(EnsureQuantumKeyBackupDirectory(directory, error), error);
        BOOST_CHECK(recorder.Committed(datadir));
        BOOST_CHECK(!recorder.Committed(datadir.parent_path()));
    }
}

// The manifest's rename and its directory commit are different failures with different messages, and the operating
// system's reason for a failed rename is kept.
#ifndef WIN32
BOOST_AUTO_TEST_CASE(a_manifest_that_cannot_be_installed_reports_the_systems_reason)
{
    const fs::path directory = m_path_root / "manifest-rename";
    std::string error;
    BOOST_REQUIRE_MESSAGE(EnsureQuantumKeyBackupDirectory(directory, error), error);
    const std::string name = QuantumKeyBackupFileName(1'798'000'000, 100, NewQuantumKeyBackupSuffix());
    // a directory with a file in it where the manifest goes: the rename of a file over it fails
    const fs::path blocker = directory / fs::PathFromString(name + ".keys");
    BOOST_REQUIRE(fs::create_directory(blocker));
    std::ofstream{blocker / "occupied", std::ios::binary} << "x";
    BOOST_CHECK(!WriteQuantumKeyBackupManifest(directory, name, 1, Keys({1}), error));
    BOOST_CHECK_MESSAGE(error.find("cannot install the backup manifest " + fs::PathToString(blocker) + ": ") == 0, error);
    BOOST_CHECK_MESSAGE(error.size() > std::string{"cannot install the backup manifest " + fs::PathToString(blocker) + ": "}.size(), error);
    // the temporary file is gone
    BOOST_CHECK(!fs::exists(directory / fs::PathFromString("." + name + ".keys.tmp")));
}
#endif

BOOST_AUTO_TEST_SUITE_END()
} // namespace wallet
