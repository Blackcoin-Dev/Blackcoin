// Copyright (c) 2026 Blackcoin Core Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <node/readahead.h>
#include <test/util/setup_common.h>
#include <util/fs.h>

#include <boost/test/unit_test.hpp>

#include <algorithm>
#include <fstream>
#include <string>

#ifndef WIN32
#include <unistd.h>
#endif

using node::ReadAheadDirectory;
using node::ReadAheadStats;

namespace {
void MakeFile(const fs::path& path, size_t size)
{
    std::ofstream out{path, std::ios::binary};
    const std::string block(4096, 'x');
    for (size_t written{0}; written < size; written += block.size()) {
        out.write(block.data(), static_cast<std::streamsize>(std::min(block.size(), size - written)));
    }
}
} // namespace

BOOST_FIXTURE_TEST_SUITE(readahead_tests, BasicTestingSetup)

BOOST_AUTO_TEST_CASE(reads_every_file_once_in_chunks)
{
    const fs::path dir{m_path_root / "ra_basic"};
    fs::create_directories(dir);
    MakeFile(dir / "000001.ldb", 100000);
    MakeFile(dir / "000002.ldb", 5);
    MakeFile(dir / "MANIFEST-000003", 0);
    fs::create_directories(dir / "subdir"); // not a regular file: ignored

    // A chunk much smaller than the files forces several reads per file.
    const ReadAheadStats stats{ReadAheadDirectory(dir, uint64_t{1} << 30, /*chunk_bytes=*/4096)};
    BOOST_CHECK_EQUAL(stats.dir_bytes, 100005U);
    BOOST_CHECK_EQUAL(stats.bytes_read, 100005U);
    BOOST_CHECK_EQUAL(stats.files_read, 3U);
    BOOST_CHECK_EQUAL(stats.files_failed, 0U);
    BOOST_CHECK(!stats.skipped_too_large);
    BOOST_CHECK(!stats.skipped_missing);

    // The default chunk gives the same totals.
    const ReadAheadStats big{ReadAheadDirectory(dir, uint64_t{1} << 30)};
    BOOST_CHECK_EQUAL(big.bytes_read, 100005U);
}

BOOST_AUTO_TEST_CASE(respects_the_size_cap)
{
    const fs::path dir{m_path_root / "ra_cap"};
    fs::create_directories(dir);
    MakeFile(dir / "a.ldb", 10000);
    MakeFile(dir / "b.ldb", 10000);

    const ReadAheadStats over{ReadAheadDirectory(dir, 19999)};
    BOOST_CHECK(over.skipped_too_large);
    BOOST_CHECK_EQUAL(over.dir_bytes, 20000U);
    BOOST_CHECK_EQUAL(over.bytes_read, 0U);
    BOOST_CHECK_EQUAL(over.files_read, 0U);

    // Exactly at the cap is allowed.
    const ReadAheadStats at{ReadAheadDirectory(dir, 20000)};
    BOOST_CHECK(!at.skipped_too_large);
    BOOST_CHECK_EQUAL(at.bytes_read, 20000U);

    // A cap of zero (RAM unknown) reads nothing.
    BOOST_CHECK(ReadAheadDirectory(dir, 0).skipped_too_large);
}

BOOST_AUTO_TEST_CASE(missing_directory_is_skipped)
{
    const ReadAheadStats stats{ReadAheadDirectory(m_path_root / "ra_does_not_exist", uint64_t{1} << 30)};
    BOOST_CHECK(stats.skipped_missing);
    BOOST_CHECK_EQUAL(stats.bytes_read, 0U);
}

BOOST_AUTO_TEST_CASE(unreadable_file_is_counted_not_fatal)
{
#ifndef WIN32
    const fs::path dir{m_path_root / "ra_unreadable"};
    fs::create_directories(dir);
    MakeFile(dir / "good.ldb", 3000);
    MakeFile(dir / "locked.ldb", 2000);
    fs::permissions(dir / "locked.ldb", fs::perms::none);

    const ReadAheadStats stats{ReadAheadDirectory(dir, uint64_t{1} << 30)};
    BOOST_CHECK_EQUAL(stats.dir_bytes, 5000U);
    if (geteuid() == 0) {
        // root reads it anyway
        BOOST_CHECK_EQUAL(stats.bytes_read, 5000U);
    } else {
        BOOST_CHECK_EQUAL(stats.bytes_read, 3000U);
        BOOST_CHECK_EQUAL(stats.files_read, 1U);
        BOOST_CHECK_EQUAL(stats.files_failed, 1U);
    }
    fs::permissions(dir / "locked.ldb", fs::perms::owner_read | fs::perms::owner_write);
#endif
}

BOOST_AUTO_TEST_CASE(interrupt_stops_early)
{
    const fs::path dir{m_path_root / "ra_interrupt"};
    fs::create_directories(dir);
    MakeFile(dir / "a.ldb", 50000);
    MakeFile(dir / "b.ldb", 50000);
    const ReadAheadStats stats{ReadAheadDirectory(dir, uint64_t{1} << 30, 4096, [] { return true; })};
    BOOST_CHECK(stats.interrupted);
    BOOST_CHECK_EQUAL(stats.bytes_read, 0U);
}

BOOST_AUTO_TEST_CASE(max_bytes_is_a_quarter_of_ram_or_zero)
{
    const uint64_t max{node::ReadAheadMaxBytes()};
    // Any machine that runs the tests has more than 64 MiB of RAM.
    BOOST_CHECK_GT(max, uint64_t{16} << 20);
}

BOOST_AUTO_TEST_SUITE_END()
