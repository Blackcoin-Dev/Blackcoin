// Copyright (c) 2026 Blackcoin Core Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <util/readahead.h>

#include <logging.h>
#include <tinyformat.h>

#include <algorithm>
#include <chrono>
#include <system_error>
#include <vector>

#ifdef WIN32
#include <fstream>
#else
#include <fcntl.h>
#include <unistd.h>
#endif

namespace util {

#ifndef WIN32
/** Ask the system to start reading [offset, offset + len) ahead of the reader. */
static void HintWillNeed(int fd, uint64_t offset, size_t len)
{
#if defined(__APPLE__)
    struct radvisory advice;
    advice.ra_offset = static_cast<off_t>(offset);
    advice.ra_count = static_cast<int>(std::min<size_t>(len, size_t{1} << 30));
    (void)fcntl(fd, F_RDADVISE, &advice);
#elif defined(POSIX_FADV_WILLNEED)
    (void)posix_fadvise(fd, static_cast<off_t>(offset), static_cast<off_t>(len), POSIX_FADV_WILLNEED);
#else
    (void)fd; (void)offset; (void)len;
#endif
}

static void HintSequential(int fd)
{
#if defined(__APPLE__)
    (void)fcntl(fd, F_RDAHEAD, 1);
#elif defined(POSIX_FADV_SEQUENTIAL)
    (void)posix_fadvise(fd, 0, 0, POSIX_FADV_SEQUENTIAL);
#else
    (void)fd;
#endif
}
#endif

/** Read one file to the end. Returns false when it could not be read fully. */
static bool ReadWholeFileAndDiscard(const fs::path& path, uint64_t file_size, std::vector<char>& buf, ReadAheadStats& stats, const std::function<bool()>& interrupted)
{
#ifdef WIN32
    std::ifstream in{path, std::ios::binary};
    if (!in) return false;
    while (in) {
        if (interrupted && interrupted()) { stats.interrupted = true; return true; }
        in.read(buf.data(), static_cast<std::streamsize>(buf.size()));
        stats.bytes_read += static_cast<uint64_t>(in.gcount());
    }
    return in.eof();
#else
    const int fd{open(path.c_str(), O_RDONLY)};
    if (fd < 0) return false;
    HintSequential(fd);
    uint64_t offset{0};
    bool ok{true};
    while (true) {
        if (interrupted && interrupted()) { stats.interrupted = true; break; }
        // Let the kernel start on the next chunk while this one is copied.
        if (offset + buf.size() < file_size) HintWillNeed(fd, offset + buf.size(), buf.size());
        const ssize_t n{read(fd, buf.data(), buf.size())};
        if (n < 0) { ok = false; break; }
        if (n == 0) break;
        offset += static_cast<uint64_t>(n);
        stats.bytes_read += static_cast<uint64_t>(n);
    }
    close(fd);
    return ok;
#endif
}

static ReadAheadStats ReadAheadList(std::vector<std::pair<fs::path, uint64_t>>& files, ReadAheadStats stats, uint64_t max_bytes, size_t chunk_bytes, const std::function<bool()>& interrupted)
{
    if (stats.dir_bytes > max_bytes) {
        stats.skipped_too_large = true;
        return stats;
    }
    std::vector<char> buf(std::max<size_t>(chunk_bytes, 1));
    for (const auto& [path, size] : files) {
        if (interrupted && interrupted()) { stats.interrupted = true; break; }
        if (ReadWholeFileAndDiscard(path, size, buf, stats, interrupted)) {
            if (!stats.interrupted) ++stats.files_read;
        } else {
            ++stats.files_failed;
        }
        if (stats.interrupted) break;
    }
    return stats;
}

ReadAheadStats ReadAheadDirectory(const fs::path& dir, uint64_t max_bytes, size_t chunk_bytes, const std::function<bool()>& interrupted)
{
    ReadAheadStats stats;
    std::error_code ec;
    std::vector<std::pair<fs::path, uint64_t>> files;
    for (fs::directory_iterator it{dir, ec}, end; !ec && it != end; it.increment(ec)) {
        std::error_code entry_ec;
        if (!it->is_regular_file(entry_ec) || entry_ec) continue;
        const uint64_t size{it->file_size(entry_ec)};
        if (entry_ec) { ++stats.files_failed; continue; }
        files.emplace_back(it->path(), size);
        stats.dir_bytes += size;
    }
    if (ec) {
        // The listing itself failed (a missing directory lands here too).
        stats.skipped_missing = true;
        return stats;
    }
    // LevelDB's table files are numbered; read them in that order.
    std::sort(files.begin(), files.end());
    return ReadAheadList(files, stats, max_bytes, chunk_bytes, interrupted);
}

ReadAheadStats ReadAheadFiles(const std::vector<fs::path>& paths, uint64_t max_bytes, size_t chunk_bytes, const std::function<bool()>& interrupted)
{
    ReadAheadStats stats;
    std::vector<std::pair<fs::path, uint64_t>> files;
    for (const fs::path& path : paths) {
        std::error_code ec;
        if (!fs::is_regular_file(path, ec) || ec) continue;
        const uint64_t size{fs::file_size(path, ec)};
        if (ec) { ++stats.files_failed; continue; }
        files.emplace_back(path, size);
        stats.dir_bytes += size;
    }
    if (files.empty() && stats.files_failed == 0) {
        stats.skipped_missing = true;
        return stats;
    }
    return ReadAheadList(files, stats, max_bytes, chunk_bytes, interrupted);
}

} // namespace util
