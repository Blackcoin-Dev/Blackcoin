// Copyright (c) 2026 Blackcoin Core Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <coins.h>
#include <dbwrapper.h>
#include <primitives/transaction.h>
#include <random.h>
#include <test/util/rc14_gate.h>
#include <test/util/setup_common.h>
#include <txdb.h>
#include <uint256.h>
#include <util/fs.h>
#include <crypto/common.h>
#include <util/io_counters.h>
#include <util/time.h>

#include <boost/test/unit_test.hpp>

#include <algorithm>
#include <chrono>
#include <cstring>
#include <set>
#include <string>
#include <vector>

//! TODO(rc14-integration): set to true once the LevelDB options track is merged
//! (seek compaction off). The checks it guards fail on RC13.
static constexpr bool RC14_GATES_ENFORCED{false};

namespace {

//! Restore every test-only switch whatever a test did.
struct CountersReset {
    ~CountersReset()
    {
        iocounters::SetDbReadDelayUs(0);
        iocounters::SetWalletCommitDelayUs(0);
        iocounters::SetKeyRecorder(false);
        iocounters::ClearRecordedKeys();
    }
};

COutPoint Outpoint(uint32_t n)
{
    uint256 txid;
    WriteLE32(txid.begin(), n);
    return COutPoint{txid, n % 7};
}

} // namespace

BOOST_FIXTURE_TEST_SUITE(io_counters_tests, BasicTestingSetup)

BOOST_AUTO_TEST_CASE(counters_increase_by_exactly_the_calls_made)
{
    CountersReset reset;
    CCoinsViewDB db{{.path = "test", .cache_bytes = 1 << 20, .memory_only = true}, {}};
    constexpr uint32_t STORED{20};
    {
        CCoinsViewCache cache{&db};
        for (uint32_t n = 0; n < STORED; ++n) {
            cache.AddCoin(Outpoint(n), Coin{CTxOut{COIN, CScript{} << OP_TRUE}, 5, false, false, 0}, false);
        }
        cache.SetBestBlock(uint256{1});
        BOOST_REQUIRE(cache.Flush());
    }

    const iocounters::Snapshot before = iocounters::Read();
    Coin coin;
    for (uint32_t n = 0; n < STORED; ++n) BOOST_CHECK(db.GetCoin(Outpoint(n), coin));
    for (uint32_t n = 0; n < 7; ++n) BOOST_CHECK(!db.GetCoin(Outpoint(1000 + n), coin)); // misses count too
    for (uint32_t n = 0; n < 5; ++n) BOOST_CHECK(db.HaveCoin(Outpoint(n)));
    const iocounters::Snapshot after = iocounters::Read();

    BOOST_CHECK_EQUAL(after.chainstate_get_coin - before.chainstate_get_coin, STORED + 7);
    BOOST_CHECK_EQUAL(after.chainstate_have_coin - before.chainstate_have_coin, 5U);
    // GetCoin is one wrapper read, HaveCoin one existence check.
    BOOST_CHECK_EQUAL(after.db_reads - before.db_reads, STORED + 7);
    BOOST_CHECK_EQUAL(after.db_exists - before.db_exists, 5U);
    BOOST_CHECK_EQUAL(after.wallet_commits, before.wallet_commits);
}

BOOST_AUTO_TEST_CASE(key_recorder_reports_order)
{
    CountersReset reset;
    CCoinsViewDB db{{.path = "test", .cache_bytes = 1 << 20, .memory_only = true}, {}};
    std::vector<COutPoint> outpoints;
    {
        CCoinsViewCache cache{&db};
        for (uint32_t n = 0; n < 50; ++n) {
            outpoints.push_back(Outpoint(n));
            cache.AddCoin(outpoints.back(), Coin{CTxOut{COIN, CScript{} << OP_TRUE}, 5, false, false, 0}, false);
        }
        cache.SetBestBlock(uint256{1});
        BOOST_REQUIRE(cache.Flush());
    }
    // Sort the way the database does: by transaction id bytes, then index.
    std::sort(outpoints.begin(), outpoints.end(), [](const COutPoint& a, const COutPoint& b) {
        const int c = std::memcmp(a.hash.begin(), b.hash.begin(), 32);
        return c != 0 ? c < 0 : a.n < b.n;
    });

    // Off by default: nothing recorded.
    Coin coin;
    for (const COutPoint& o : outpoints) BOOST_CHECK(db.GetCoin(o, coin));
    BOOST_CHECK_EQUAL(iocounters::RecordedKeyCount(), 0U);

    iocounters::SetKeyRecorder(true);
    for (const COutPoint& o : outpoints) BOOST_CHECK(db.GetCoin(o, coin));
    iocounters::KeyOrderReport sorted = iocounters::RecordedKeyOrder('C');
    BOOST_CHECK_EQUAL(sorted.keys, outpoints.size());
    BOOST_CHECK_EQUAL(sorted.inversions, 0U);

    // A different order shows up as inversions, and `first` skips what came before.
    const size_t mark = iocounters::RecordedKeyCount();
    std::vector<COutPoint> shuffled{outpoints};
    std::reverse(shuffled.begin(), shuffled.end());
    for (const COutPoint& o : shuffled) BOOST_CHECK(db.GetCoin(o, coin));
    const iocounters::KeyOrderReport reversed = iocounters::RecordedKeyOrder('C', mark);
    BOOST_CHECK_EQUAL(reversed.keys, shuffled.size());
    BOOST_CHECK_EQUAL(reversed.inversions, shuffled.size() - 1);
    BOOST_CHECK_EQUAL(iocounters::RecordedKeyOrder('C').keys, 2 * outpoints.size());
    // Existence checks are recorded as reads of the same keys.
    BOOST_CHECK(db.HaveCoin(outpoints.front()));
    BOOST_CHECK_EQUAL(iocounters::RecordedKeyCount(), 2 * outpoints.size() + 1);
}

BOOST_AUTO_TEST_CASE(key_order_ignores_other_prefixes)
{
    const std::vector<std::string> keys{"C\x02", "b\x01", "C\x03", "f\x00", "C\x03", "C\x01"};
    const iocounters::KeyOrderReport report = iocounters::KeyOrder(keys, 'C');
    BOOST_CHECK_EQUAL(report.keys, 4U);
    BOOST_CHECK_EQUAL(report.inversions, 1U); // only the last one drops below its predecessor
}

BOOST_AUTO_TEST_CASE(read_delay_sleeps_per_read_and_is_off_by_default)
{
    CountersReset reset;
    CCoinsViewDB db{{.path = "test", .cache_bytes = 1 << 20, .memory_only = true}, {}};
    BOOST_CHECK_EQUAL(iocounters::GetDbReadDelayUs(), 0);
    Coin coin;
    constexpr int READS{20};
    constexpr int64_t DELAY_US{2000};
    iocounters::SetDbReadDelayUs(DELAY_US);
    BOOST_CHECK_EQUAL(iocounters::GetDbReadDelayUs(), DELAY_US);
    const auto start = std::chrono::steady_clock::now();
    for (int n = 0; n < READS; ++n) BOOST_CHECK(!db.GetCoin(Outpoint(n), coin));
    for (int n = 0; n < READS; ++n) BOOST_CHECK(!db.HaveCoin(Outpoint(n)));
    const auto elapsed = std::chrono::steady_clock::now() - start;
    // A lower bound only: a loaded machine may take longer, never less.
    BOOST_CHECK_GE(std::chrono::duration_cast<std::chrono::microseconds>(elapsed).count(), 2 * READS * DELAY_US);

    iocounters::SetDbReadDelayUs(0);
    BOOST_CHECK_EQUAL(iocounters::GetDbReadDelayUs(), 0);
    iocounters::SetDbReadDelayUs(-5); // a negative value is no delay
    BOOST_CHECK_EQUAL(iocounters::GetDbReadDelayUs(), 0);
}

BOOST_AUTO_TEST_CASE(wallet_commit_delay_sleeps_per_commit)
{
    CountersReset reset;
    BOOST_CHECK_EQUAL(iocounters::GetWalletCommitDelayUs(), 0);
    iocounters::SetWalletCommitDelayUs(2000);
    BOOST_CHECK_EQUAL(iocounters::GetWalletCommitDelayUs(), 2000);
    const iocounters::Snapshot before = iocounters::Read();
    const auto start = std::chrono::steady_clock::now();
    for (int n = 0; n < 10; ++n) iocounters::OnWalletCommit(/*in_wallet_handler=*/n % 2 == 0);
    const auto elapsed = std::chrono::steady_clock::now() - start;
    const iocounters::Snapshot after = iocounters::Read();
    BOOST_CHECK_GE(std::chrono::duration_cast<std::chrono::microseconds>(elapsed).count(), 10 * 2000);
    BOOST_CHECK_EQUAL(after.wallet_commits - before.wallet_commits, 10U);
    BOOST_CHECK_EQUAL(after.wallet_commits_in_handler - before.wallet_commits_in_handler, 5U);
}

BOOST_AUTO_TEST_CASE(test_delay_options_are_refused_outside_regtest)
{
    BOOST_CHECK(!iocounters::CheckTestDelayOption("-testdbreaddelayus", 0, /*is_regtest=*/true));
    BOOST_CHECK(!iocounters::CheckTestDelayOption("-testdbreaddelayus", 1000, true));
    BOOST_CHECK(!iocounters::CheckTestDelayOption("-testwalletsyncdelayus", iocounters::MAX_TEST_DELAY_US, true));
    const auto mainnet = iocounters::CheckTestDelayOption("-testdbreaddelayus", 1000, /*is_regtest=*/false);
    BOOST_REQUIRE(mainnet);
    BOOST_CHECK_EQUAL(*mainnet, "-testdbreaddelayus is only supported on regtest.");
    // Refused outside regtest even when the value is zero: the option itself is the mistake.
    BOOST_CHECK(iocounters::CheckTestDelayOption("-testwalletsyncdelayus", 0, false));
    BOOST_CHECK(iocounters::CheckTestDelayOption("-testwalletsyncdelayus", -1, true));
    BOOST_CHECK(iocounters::CheckTestDelayOption("-testwalletsyncdelayus", iocounters::MAX_TEST_DELAY_US + 1, true));
}

namespace {
std::set<std::string> TableFiles(const fs::path& dir)
{
    std::set<std::string> files;
    for (const auto& entry : fs::directory_iterator(dir)) {
        const std::string name = fs::PathToString(entry.path().filename());
        if (name.size() > 4 && name.substr(name.size() - 4) == ".ldb") files.insert(name);
    }
    return files;
}

//! Wait until the table file set has not changed for `quiet` consecutive polls.
std::set<std::string> SettledTableFiles(const fs::path& dir, int quiet, int max_polls)
{
    std::set<std::string> last = TableFiles(dir);
    int stable{0};
    for (int poll = 0; poll < max_polls && stable < quiet; ++poll) {
        UninterruptibleSleep(std::chrono::milliseconds{100});
        std::set<std::string> now = TableFiles(dir);
        stable = now == last ? stable + 1 : 0;
        last = std::move(now);
    }
    return last;
}
} // namespace

BOOST_AUTO_TEST_CASE(random_gets_on_a_multi_level_db_do_not_compact)
{
    CountersReset reset;
    const fs::path path = m_args.GetDataDirBase() / "seek_compaction_db";
    // A small write buffer makes many level-0 files, which compact into deeper levels.
    CDBWrapper db{{.path = path, .cache_bytes = 2 << 20, .memory_only = false, .wipe_data = true, .obfuscate = false}};
    constexpr uint32_t KEYS{300'000};
    const std::string value(100, 'v');
    for (uint32_t base = 0; base < KEYS; base += 1000) {
        CDBBatch batch{db};
        for (uint32_t n = base; n < base + 1000; ++n) batch.Write(std::make_pair(uint8_t{'k'}, uint64_t{n} * 2654435761ULL), value);
        BOOST_REQUIRE(db.WriteBatch(batch));
    }
    const std::set<std::string> built = SettledTableFiles(path, /*quiet=*/10, /*max_polls=*/300);
    BOOST_REQUIRE_GE(built.size(), 4U);

    FastRandomContext rng{/*fDeterministic=*/true};
    std::string out;
    for (int n = 0; n < 200'000; ++n) {
        // Half present, half absent: both walk several files.
        const uint64_t key = uint64_t{rng.randrange(KEYS)} * 2654435761ULL + static_cast<uint64_t>(n % 2);
        (void)db.Read(std::make_pair(uint8_t{'k'}, key), out);
    }
    // Seek compaction runs in the background after the reads; give it ample time to show.
    const std::set<std::string> after = SettledTableFiles(path, /*quiet=*/10, /*max_polls=*/300);
    RC14_GATE_CHECK(RC14_GATES_ENFORCED, after == built,
                    "200,000 random Gets leave the table file set unchanged (LevelDB seek compaction off)");
}

BOOST_AUTO_TEST_SUITE_END()
