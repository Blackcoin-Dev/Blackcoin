// Copyright (c) 2026 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <consensus/params.h>
#include <test/util/setup_common.h>
#include <wallet/staking.h>

#include <boost/test/unit_test.hpp>

#include <limits>

namespace wallet {
namespace {

Consensus::Params HeightSchedule(int goldrush_end, int migration_end, int maturity)
{
    Consensus::Params p;
    p.nQuantumLifecycleStartHeight = 1;
    p.nGoldRushEndHeight = goldrush_end;
    p.nQuantumMigrationEndHeight = migration_end;
    p.nCoinbaseMaturity = maturity;
    return p;
}

} // namespace

BOOST_FIXTURE_TEST_SUITE(legacy_stake_cutoff_tests, BasicTestingSetup)

BOOST_AUTO_TEST_CASE(cutoff_is_migration_end_minus_maturity_minus_margin)
{
    // Mainnet shape: M = 6,921,999 and maturity 500. A legacy coinstake at h
    // is first spendable at h + 500, which must be before M, and the wallet
    // keeps one more block of margin.
    const Consensus::Params mainnet = HeightSchedule(6192999, 6921999, 500);
    const std::optional<int64_t> last = LastLegacyStakeHeight(mainnet);
    BOOST_REQUIRE(last.has_value());
    BOOST_CHECK_EQUAL(*last, 6921999 - 500 - LEGACY_STAKE_MIGRATION_MARGIN_BLOCKS);
    BOOST_CHECK_EQUAL(*last, 6921498);
    // The last block consensus itself would allow is 6,921,499 (spendable at M).
    BOOST_CHECK(!IsLegacyStakeBarredByMigrationEnd(mainnet, 6921498));
    BOOST_CHECK(IsLegacyStakeBarredByMigrationEnd(mainnet, 6921499));
    BOOST_CHECK(IsLegacyStakeBarredByMigrationEnd(mainnet, 6921999));
    BOOST_CHECK(IsLegacyStakeBarredByMigrationEnd(mainnet, 6922000));
    BOOST_CHECK(!IsLegacyStakeBarredByMigrationEnd(mainnet, 6192999));
    BOOST_CHECK(!IsLegacyStakeBarredByMigrationEnd(mainnet, 1));

    // Regtest shape used by the functional test: G=200, M=260, maturity 10.
    const Consensus::Params regtest = HeightSchedule(200, 260, 10);
    BOOST_CHECK_EQUAL(*LastLegacyStakeHeight(regtest), 249);
    BOOST_CHECK(!IsLegacyStakeBarredByMigrationEnd(regtest, 249));
    BOOST_CHECK(IsLegacyStakeBarredByMigrationEnd(regtest, 250));
}

BOOST_AUTO_TEST_CASE(unscheduled_or_time_only_schedules_have_no_cutoff)
{
    Consensus::Params none;
    BOOST_CHECK(!LastLegacyStakeHeight(none).has_value());
    BOOST_CHECK(!IsLegacyStakeBarredByMigrationEnd(none, 1000000));
    BOOST_CHECK(LegacyStakingNotice(none, 5, {}).empty());

    Consensus::Params time_only;
    time_only.nGoldRushEndTime = 1000;
    time_only.nQuantumMigrationDeadlineTime = 2000;
    BOOST_CHECK(!LastLegacyStakeHeight(time_only).has_value());
    BOOST_CHECK(!IsLegacyStakeBarredByMigrationEnd(time_only, std::numeric_limits<int>::max()));

    // An unordered height schedule is invalid and gives no cutoff either.
    const Consensus::Params unordered = HeightSchedule(300, 260, 10);
    BOOST_CHECK(!LastLegacyStakeHeight(unordered).has_value());
}

BOOST_AUTO_TEST_CASE(cutoff_arithmetic_does_not_overflow)
{
    // Heights near the int limit must neither wrap nor be treated as barred early.
    const int big = std::numeric_limits<int>::max();
    const Consensus::Params p = HeightSchedule(big - 1000, big, 500);
    BOOST_CHECK_EQUAL(*LastLegacyStakeHeight(p), int64_t{big} - 500 - LEGACY_STAKE_MIGRATION_MARGIN_BLOCKS);
    BOOST_CHECK(!IsLegacyStakeBarredByMigrationEnd(p, big - 600));
    BOOST_CHECK(IsLegacyStakeBarredByMigrationEnd(p, big));
    // A maturity larger than the whole schedule bars every height.
    const Consensus::Params huge_maturity = HeightSchedule(200, 260, big);
    BOOST_CHECK(IsLegacyStakeBarredByMigrationEnd(huge_maturity, 1));
}

BOOST_AUTO_TEST_CASE(notice_names_the_window_the_return_address_and_the_migration_requirement)
{
    const Consensus::Params regtest = HeightSchedule(200, 260, 10);
    LegacyStakeQuantumReturn ready;
    ready.available = true;
    ready.address = "bcrt1exampleaddress";
    LegacyStakeQuantumReturn not_ready;
    not_ready.reason = "no quantum stake return address is set.";

    // Well before the window: the first quantum height is 250.
    std::string notice = LegacyStakingNotice(regtest, 201, ready);
    BOOST_CHECK(notice.find("From height 250") != std::string::npos);
    BOOST_CHECK(notice.find("paid to a quantum address") != std::string::npos);
    BOOST_CHECK(notice.find("READY: bcrt1exampleaddress") != std::string::npos);
    BOOST_CHECK(notice.find("height 261") != std::string::npos);
    BOOST_CHECK(notice.find("never win a stake stay legacy: migrate") != std::string::npos);
    BOOST_CHECK(notice.find("cannot stake again until they are 10 blocks old") != std::string::npos);

    // N1: the margin block is described as a margin, not as impossible. A stake at 250 (M - maturity)
    // matures in the last Migration block; only from 251 on can it not mature before Final.
    BOOST_CHECK(notice.find("starts one block early to keep a migration margin") != std::string::npos);
    BOOST_CHECK(notice.find("a legacy stake at height 250 would mature only in the last Migration block") != std::string::npos);
    BOOST_CHECK(notice.find("from height 251 on it could not mature before the Final phase at all") != std::string::npos);
    BOOST_CHECK(notice.find("would be lost") == std::string::npos);

    // Not ready: says exactly what to do and that no legacy stake happens.
    notice = LegacyStakingNotice(regtest, 201, not_ready);
    BOOST_CHECK(notice.find("NOT READY: no quantum stake return address is set.") != std::string::npos);
    BOOST_CHECK(notice.find("will not stake legacy coins from height 250") != std::string::npos);

    // Inside the window, still in Migration.
    notice = LegacyStakingNotice(regtest, 250, ready);
    BOOST_CHECK(notice.find("are now paid to a quantum address") != std::string::npos);
    BOOST_CHECK(notice.find("height 261") != std::string::npos);

    // In Final nothing is left to say.
    BOOST_CHECK(LegacyStakingNotice(regtest, 261, ready).empty());
}

BOOST_AUTO_TEST_SUITE_END()

} // namespace wallet
