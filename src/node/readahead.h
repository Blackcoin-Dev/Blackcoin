// Copyright (c) 2026 Blackcoin Core Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_NODE_READAHEAD_H
#define BITCOIN_NODE_READAHEAD_H

#include <util/fs.h>

#include <cstddef>
#include <cstdint>
#include <functional>

namespace node {

//! Default read size when warming a directory.
static constexpr size_t READAHEAD_CHUNK_BYTES{size_t{8} << 20};
//! Default for -blockindexreadahead.
static constexpr bool DEFAULT_BLOCKINDEX_READAHEAD{true};

struct ReadAheadStats {
    uint64_t dir_bytes{0};   //!< total size of the regular files found
    uint64_t bytes_read{0};  //!< bytes actually read and discarded
    unsigned files_read{0};  //!< files read to the end
    unsigned files_failed{0}; //!< files that could not be opened or read to the end
    bool skipped_missing{false}; //!< the directory does not exist or cannot be listed
    bool skipped_too_large{false}; //!< dir_bytes is above max_bytes, nothing was read
    bool interrupted{false};
};

/**
 * Read every regular file in a directory once, front to back, in large chunks,
 * and throw the data away, so that a later reader that makes many small reads
 * (LevelDB) finds the files in the operating system's page cache. Where the
 * platform has the call it also hints sequential access. Nothing is read when
 * the files add up to more than max_bytes (the cache could not hold them).
 * Failures are counted, never thrown: this only warms a cache.
 */
ReadAheadStats ReadAheadDirectory(const fs::path& dir, uint64_t max_bytes, size_t chunk_bytes = READAHEAD_CHUNK_BYTES, const std::function<bool()>& interrupted = {});

/** A quarter of the machine's RAM, or 0 when it cannot be read. */
uint64_t ReadAheadMaxBytes();

} // namespace node

#endif // BITCOIN_NODE_READAHEAD_H
