// Copyright (c) 2021 The Bitcoin Core developers
// Copyright (c) 2021 Blackcoin Core Developers
// Copyright (c) 2021 Blackcoin More Developers
// Copyright (c) 2021 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_NODE_CACHES_H
#define BITCOIN_NODE_CACHES_H

#include <cstddef>
#include <cstdint>
#include <optional>

class ArgsManager;

namespace node {
struct CacheSizes {
    int64_t block_tree_db;
    int64_t coins_db;
    int64_t coins;
    int64_t tx_index;
    int64_t filter_index;
};

//! Memory of the system as far as it could be detected, in bytes.
struct SystemRAM {
    std::optional<uint64_t> total;
    std::optional<uint64_t> available;
};

//! The total database cache and the ceiling of the chain state database's
//! own cache, before the total is split between the databases.
struct DbCacheChoice {
    //! Total database cache (MiB), within nMinDbCache and nMaxDbCache.
    int64_t total_mib;
    //! Most the chain state database cache may take of the total (MiB).
    int64_t coins_db_max_mib;
    //! True when -dbcache was not set and the total follows the system memory.
    bool from_system_ram;
    //! True when little available memory halved the choice.
    bool halved;
};

/**
 * Choose the database cache. An explicit -dbcache (command line, configuration
 * file or settings file) is used as given. Otherwise the total is one
 * sixteenth of the system memory, between 100 MiB and 1024 MiB, halved when
 * less than four times that much memory is available; when the system memory
 * is unknown it is nDefaultDbCache.
 */
DbCacheChoice ChooseDbCache(const ArgsManager& args, const SystemRAM& ram);

//! Split the database cache using the given system memory figures.
CacheSizes CalculateCacheSizes(const ArgsManager& args, size_t n_indexes, const SystemRAM& ram);
//! Detect the system memory, log it with the chosen sizes, and split the cache.
CacheSizes CalculateCacheSizes(const ArgsManager& args, size_t n_indexes = 0);
} // namespace node

#endif // BITCOIN_NODE_CACHES_H
