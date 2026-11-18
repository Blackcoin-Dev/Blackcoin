// Copyright (c) 2026 Blackcoin Core Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <common/args.h>
#include <node/caches.h>
#include <txdb.h>
#include <util/string.h>

#include <boost/test/unit_test.hpp>

#include <algorithm>
#include <cstdint>
#include <optional>

using node::CacheSizes;
using node::CalculateCacheSizes;
using node::ChooseDbCache;
using node::DbCacheChoice;
using node::SystemRAM;

namespace {
constexpr uint64_t MIB{uint64_t{1} << 20};
constexpr uint64_t GIB{uint64_t{1} << 30};

//! A system with the given memory, nearly all of it available.
SystemRAM Ram(uint64_t total)
{
    return SystemRAM{.total = total, .available = total - total / 8};
}

int64_t Sum(const CacheSizes& sizes)
{
    return sizes.block_tree_db + sizes.coins_db + sizes.coins + sizes.tx_index + sizes.filter_index;
}
} // namespace

BOOST_AUTO_TEST_SUITE(caches_tests)

BOOST_AUTO_TEST_CASE(dbcache_follows_system_memory)
{
    ArgsManager args;
    struct Row {
        uint64_t ram;
        int64_t total_mib;
        int64_t coins_db_mib;
    };
    // One sixteenth of the memory between 100 and 1024 MiB, and one 256th of
    // it between 8 and 64 MiB for the chain state database.
    const Row rows[]{
        {512 * MIB, 100, 8},
        {1 * GIB, 100, 8},
        {2 * GIB, 128, 8},
        {4 * GIB, 256, 16},
        {8 * GIB, 512, 32},
        {16 * GIB, 1024, 64},
        {24 * GIB, 1024, 64},
        {256 * GIB, 1024, 64},
    };
    for (const Row& row : rows) {
        BOOST_TEST_CONTEXT("ram_mib=" << (row.ram >> 20)) {
            const DbCacheChoice choice{ChooseDbCache(args, Ram(row.ram))};
            BOOST_CHECK(choice.from_system_ram);
            BOOST_CHECK(!choice.halved);
            BOOST_CHECK_EQUAL(choice.total_mib, row.total_mib);
            BOOST_CHECK_EQUAL(choice.coins_db_max_mib, row.coins_db_mib);

            const CacheSizes sizes{CalculateCacheSizes(args, 0, Ram(row.ram))};
            BOOST_CHECK_EQUAL(sizes.coins_db, row.coins_db_mib << 20);
            BOOST_CHECK_EQUAL(Sum(sizes), row.total_mib << 20);
            BOOST_CHECK_GT(sizes.coins, 0);
        }
    }
}

BOOST_AUTO_TEST_CASE(dbcache_halved_when_little_memory_is_available)
{
    ArgsManager args;
    // 8 GiB machine: 512 MiB is chosen and needs 2048 MiB available.
    {
        const DbCacheChoice choice{ChooseDbCache(args, SystemRAM{.total = 8 * GIB, .available = 2048 * MIB})};
        BOOST_CHECK(!choice.halved);
        BOOST_CHECK_EQUAL(choice.total_mib, 512);
        BOOST_CHECK_EQUAL(choice.coins_db_max_mib, 32);
    }
    {
        const SystemRAM ram{.total = 8 * GIB, .available = 2047 * MIB};
        const DbCacheChoice choice{ChooseDbCache(args, ram)};
        BOOST_CHECK(choice.from_system_ram);
        BOOST_CHECK(choice.halved);
        BOOST_CHECK_EQUAL(choice.total_mib, 256);
        BOOST_CHECK_EQUAL(choice.coins_db_max_mib, 16);
        const CacheSizes sizes{CalculateCacheSizes(args, 0, ram)};
        BOOST_CHECK_EQUAL(sizes.coins_db, 16 << 20);
        BOOST_CHECK_EQUAL(Sum(sizes), 256 << 20);
    }
    // The chain state database cache is never chosen below 8 MiB.
    {
        const DbCacheChoice choice{ChooseDbCache(args, SystemRAM{.total = 2 * GIB, .available = 100 * MIB})};
        BOOST_CHECK(choice.halved);
        BOOST_CHECK_EQUAL(choice.total_mib, 64);
        BOOST_CHECK_EQUAL(choice.coins_db_max_mib, 8);
    }
    // Unknown available memory leaves the choice alone.
    {
        const DbCacheChoice choice{ChooseDbCache(args, SystemRAM{.total = 8 * GIB, .available = std::nullopt})};
        BOOST_CHECK(!choice.halved);
        BOOST_CHECK_EQUAL(choice.total_mib, 512);
    }
}

BOOST_AUTO_TEST_CASE(dbcache_default_when_memory_is_unknown)
{
    ArgsManager args;
    const SystemRAM unknown{};
    const DbCacheChoice choice{ChooseDbCache(args, unknown)};
    BOOST_CHECK(!choice.from_system_ram);
    BOOST_CHECK(!choice.halved);
    BOOST_CHECK_EQUAL(choice.total_mib, nDefaultDbCache);
    // 8 MiB used to be the ceiling of the chain state database cache.
    const CacheSizes sizes{CalculateCacheSizes(args, 0, unknown)};
    BOOST_CHECK_GT(sizes.coins_db, 8 << 20);
    BOOST_CHECK_EQUAL(sizes.coins_db, nUnknownRamCoinsDBCache << 20);
    BOOST_CHECK_EQUAL(Sum(sizes), nDefaultDbCache << 20);
}

BOOST_AUTO_TEST_CASE(explicit_dbcache_is_kept)
{
    for (const uint64_t ram_bytes : {2 * GIB, 8 * GIB, 64 * GIB}) {
        for (const int64_t dbcache : {int64_t{4}, int64_t{16}, int64_t{50}, int64_t{450}, int64_t{4000}}) {
            BOOST_TEST_CONTEXT("ram_mib=" << (ram_bytes >> 20) << ", dbcache=" << dbcache) {
                ArgsManager args;
                args.ForceSetArg("-dbcache", ToString(dbcache));
                // Little available memory must not change an explicit setting.
                const SystemRAM ram{.total = ram_bytes, .available = 64 * MIB};
                const DbCacheChoice choice{ChooseDbCache(args, ram)};
                BOOST_CHECK(!choice.from_system_ram);
                BOOST_CHECK(!choice.halved);
                BOOST_CHECK_EQUAL(choice.total_mib, std::min(dbcache, nMaxDbCache));
                const CacheSizes sizes{CalculateCacheSizes(args, 0, ram)};
                BOOST_CHECK_EQUAL(Sum(sizes), choice.total_mib << 20);
                BOOST_CHECK_GT(sizes.coins, 0);
                BOOST_CHECK_LE(sizes.coins_db, choice.coins_db_max_mib << 20);
                // 8 MiB is a floor once the cache is large enough to hold it
                // beside an in-memory cache of the same size.
                if (dbcache >= 50) BOOST_CHECK_GE(sizes.coins_db, 8 << 20);
            }
        }
    }
    // Out of range values are still clamped.
    ArgsManager args;
    args.ForceSetArg("-dbcache", "1");
    BOOST_CHECK_EQUAL(ChooseDbCache(args, Ram(8 * GIB)).total_mib, nMinDbCache);
    // An explicit -dbcache also wins when the memory is unknown.
    args.ForceSetArg("-dbcache", "200");
    BOOST_CHECK_EQUAL(ChooseDbCache(args, SystemRAM{}).total_mib, 200);
}

BOOST_AUTO_TEST_SUITE_END()
