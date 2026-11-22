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
#include <map>
#include <optional>
#include <set>
#include <system_error>

#ifndef WIN32
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
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

/** Make a directory and its entry in the directory above it durable. Without the second step a power loss can
 *  keep the files below while the directory's own name is lost. On a test chain,
 *  -quantumreturnfailcommit=<name> makes the commit of the entry of the directory called <name> fail, which is
 *  how the tests show that a failure here keeps the key pending. Never reachable on a production chain. */
bool CommitDirectoryEntry(const fs::path& directory)
{
    if (!DirectoryCommit(directory)) return false;
    if (Params().IsTestChain() && gArgs.GetArg("-quantumreturnfailcommit", "") == fs::PathToString(directory.filename())) return false;
    const fs::path parent = directory.parent_path();
    return DirectoryCommit(parent.empty() ? fs::path{"."} : parent);
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
    if (!sequence_value || !count_value || lines.size() != 4 + *count_value + 2) return std::nullopt;
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
    for (const unsigned char c : wallet_name) {
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

fs::path QuantumKeyBackupBaseDirectory()
{
    const std::string configured = gArgs.GetArg("-quantumkeybackupdir", "");
    if (!configured.empty()) {
        fs::path path = fs::PathFromString(configured);
        if (path.is_relative()) path = gArgs.GetDataDirNet() / path;
        return path;
    }
    return gArgs.GetDataDirNet() / "quantum-key-backups";
}

fs::path QuantumKeyBackupDirectory(const std::string& wallet_name)
{
    return QuantumKeyBackupBaseDirectory() / fs::PathFromString(QuantumKeyBackupWalletComponent(wallet_name));
}

bool EnsureQuantumKeyBackupDirectory(const fs::path& directory, std::string& error)
{
    try {
        // Create what is missing from the top down, each with mode 0700, so no part of the path is ever
        // readable by others, and tighten the wallet's own directory when it already exists and is wider.
        std::vector<fs::path> missing;
        for (fs::path path = directory; !path.empty() && !fs::exists(path); path = path.parent_path()) {
            missing.push_back(path);
            if (path == path.parent_path()) break;
        }
        std::set<fs::path> committed;
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
            // Each directory made here is made durable, with its entry in the directory above it, before the next
            // one and before the backup and the activation of the key it protects. When that fails the directory
            // is taken away again (it is empty), so that the next attempt makes and commits it anew instead of
            // finding it and taking it as durable.
            if (!CommitDirectoryEntry(*it)) {
                std::error_code ignored;
                fs::remove(*it, ignored);
                error = strprintf("cannot make the new backup directory %s durable", fs::PathToString(*it));
                return false;
            }
            committed.insert(*it);
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
        // The wallet's directory and the base above it are committed on every call as well: one a failed or
        // interrupted earlier attempt left only in the page cache is not taken as durable.
        for (const fs::path& path : std::array<fs::path, 2>{directory, directory.parent_path()}) {
            if (path.empty() || committed.count(path)) continue;
            if (!CommitDirectoryEntry(path)) {
                error = strprintf("cannot make the backup directory %s durable", fs::PathToString(path));
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
            // An older generation that is the only one holding a live key stays.
            for (const auto& key : generation.keys) {
                if (live_keys.count(key) && !covered.count(key)) {
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
    if (!RenameOver(temporary, final_path) || !DirectoryCommit(directory)) {
        error = strprintf("cannot install the backup manifest %s", fs::PathToString(final_path));
        std::error_code ec;
        fs::remove(temporary, ec);
        return false;
    }
    return true;
}

size_t PruneQuantumKeyBackups(const fs::path& directory, const QuantumKeyBackupKeySet& live_keys, size_t keep_newest)
{
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
