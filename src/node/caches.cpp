// Copyright (c) 2021-2022 The Bitcoin Core developers
// Copyright (c) 2021-2022 Blackcoin Core Developers
// Copyright (c) 2021-2022 Blackcoin More Developers
// Copyright (c) 2021-2022 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <node/caches.h>

#include <common/args.h>
#include <common/system.h>
#include <index/txindex.h>
#include <logging.h>
#include <tinyformat.h>
#include <txdb.h>

#include <algorithm>
#include <string>

namespace node {
namespace {
std::string FormatMiB(const std::optional<uint64_t>& bytes)
{
    return bytes ? strprintf("%d MiB", *bytes >> 20) : std::string{"unknown"};
}
} // namespace

DbCacheChoice ChooseDbCache(const ArgsManager& args, const SystemRAM& ram)
{
    DbCacheChoice choice{};
    // The chain state database cache follows the system memory whether or not
    // -dbcache is set. It is only ever a ceiling on a share of the total.
    choice.coins_db_max_mib = nUnknownRamCoinsDBCache;
    std::optional<int64_t> ram_mib;
    if (ram.total) {
        ram_mib = static_cast<int64_t>(std::min<uint64_t>(*ram.total >> 20, uint64_t{1} << 40));
        choice.coins_db_max_mib = std::clamp<int64_t>(*ram_mib / 256, nMinCoinsDBCache, nMaxCoinsDBCache);
    }

    if (args.IsArgSet("-dbcache")) {
        choice.total_mib = args.GetIntArg("-dbcache", nDefaultDbCache);
    } else if (ram_mib) {
        choice.from_system_ram = true;
        choice.total_mib = std::clamp<int64_t>(*ram_mib / 16, nMinDynamicDbCache, nMaxDynamicDbCache);
        // The choice follows the total memory because several nodes can share
        // one machine. Available memory only ever lowers it.
        if (ram.available && (*ram.available >> 20) < static_cast<uint64_t>(choice.total_mib) * 4) {
            choice.halved = true;
            choice.total_mib /= 2;
            choice.coins_db_max_mib = std::max<int64_t>(choice.coins_db_max_mib / 2, nMinCoinsDBCache);
        }
    } else {
        choice.total_mib = nDefaultDbCache;
    }
    choice.total_mib = std::max(choice.total_mib, nMinDbCache); // total cache cannot be less than nMinDbCache
    choice.total_mib = std::min(choice.total_mib, nMaxDbCache); // total cache cannot be greater than nMaxDbcache
    return choice;
}

CacheSizes CalculateCacheSizes(const ArgsManager& args, size_t n_indexes, const SystemRAM& ram)
{
    const DbCacheChoice choice{ChooseDbCache(args, ram)};
    int64_t nTotalCache = choice.total_mib << 20;
    CacheSizes sizes;
    sizes.block_tree_db = std::min(nTotalCache / 8, nMaxBlockDBCache << 20);
    nTotalCache -= sizes.block_tree_db;
    sizes.tx_index = std::min(nTotalCache / 8, args.GetBoolArg("-txindex", DEFAULT_TXINDEX) ? nMaxTxIndexCache << 20 : 0);
    nTotalCache -= sizes.tx_index;
    sizes.filter_index = 0;
    if (n_indexes > 0) {
        int64_t max_cache = std::min(nTotalCache / 8, max_filter_index_cache << 20);
        sizes.filter_index = max_cache / n_indexes;
        nTotalCache -= sizes.filter_index * n_indexes;
    }
    // Use 25%-50% of the remainder for the chain state database cache, up to
    // the ceiling chosen above. The share is at least 8 MiB whenever the
    // remainder is 16 MiB or more, so only a very small explicit -dbcache
    // takes it below that.
    sizes.coins_db = std::min(nTotalCache / 2, (nTotalCache / 4) + (1 << 23));
    sizes.coins_db = std::min(sizes.coins_db, choice.coins_db_max_mib << 20);
    nTotalCache -= sizes.coins_db;
    sizes.coins = nTotalCache; // the rest goes to in-memory cache
    return sizes;
}

CacheSizes CalculateCacheSizes(const ArgsManager& args, size_t n_indexes)
{
    const SystemRAM ram{.total = GetTotalRAM(), .available = GetAvailableRAM()};
    const DbCacheChoice choice{ChooseDbCache(args, ram)};
    const CacheSizes sizes{CalculateCacheSizes(args, n_indexes, ram)};
    LogPrintf("System memory: total %s, available %s. Database cache %d MiB (%s%s), of which %.1f MiB for the chain state database\n",
              FormatMiB(ram.total), FormatMiB(ram.available), choice.total_mib,
              choice.from_system_ram ? "chosen from the system memory" : args.IsArgSet("-dbcache") ? "set with -dbcache" : "default",
              choice.halved ? ", halved because little memory is available" : "",
              sizes.coins_db * (1.0 / 1024 / 1024));
    return sizes;
}
} // namespace node
