// Copyright (c) 2026 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <consensus/params.h>
#include <primitives/transaction.h>
#include <script/script.h>
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
    // N1: the first return (made at height 250 = M - maturity) can stake in the last Migration block (260);
    // a later one only from the first Final block (261). The notice must not say none can stake in the window.
    BOOST_CHECK(notice.find("can stake again when they are 10 blocks old: the first one (made at height 250) in the last Migration block (260), any later one from the first Final block (261) on") != std::string::npos);
    BOOST_CHECK(notice.find("so not inside the window") == std::string::npos);

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

// The independent guard of the coinstake constructor, fed shapes the constructor never makes. A legacy kernel in the
// return window must have exactly one output of value, paying exactly the saved quantum return script, and must have
// been built to return to quantum with a ready return address; every other shape is refused with its own reason.
BOOST_AUTO_TEST_CASE(the_independent_guard_refuses_every_malformed_window_shape)
{
    LegacyStakeQuantumReturn ready;
    ready.available = true;
    ready.script = CScript() << OP_1 << std::vector<unsigned char>(32, 0x51);
    const CScript other_script = CScript() << OP_1 << std::vector<unsigned char>(32, 0x52);
    const CScript legacy_script = CScript() << OP_DUP << OP_HASH160 << std::vector<unsigned char>(20, 0x53) << OP_EQUALVERIFY << OP_CHECKSIG;

    // vout[0] marks the coinstake, vout[1] is the value-0 legacy block-signing key, vout[2] the return.
    const auto shape = [&](std::vector<CTxOut> outputs) {
        CMutableTransaction tx;
        tx.vout.emplace_back(0, CScript());
        tx.vout.emplace_back(0, legacy_script);
        for (CTxOut& out : outputs) tx.vout.push_back(std::move(out));
        return tx;
    };

    // The one acceptable shape.
    BOOST_CHECK(LegacyReturnWindowCoinstakeProblem(shape({CTxOut{100, ready.script}}), true, ready).empty());
    // Extra outputs of no value (a notice, a marker) are not outputs of value.
    BOOST_CHECK(LegacyReturnWindowCoinstakeProblem(shape({CTxOut{100, ready.script}, CTxOut{0, other_script}}), true, ready).empty());

    // Not built to return to quantum, or no ready return address: refused outright.
    BOOST_CHECK(!LegacyReturnWindowCoinstakeProblem(shape({CTxOut{100, ready.script}}), false, ready).empty());
    LegacyStakeQuantumReturn not_ready;
    BOOST_CHECK(!LegacyReturnWindowCoinstakeProblem(shape({CTxOut{100, ready.script}}), true, not_ready).empty());
    BOOST_CHECK(LegacyReturnWindowCoinstakeProblem(shape({CTxOut{100, ready.script}}), false, ready).find("refusing") != std::string::npos);

    // A value to a legacy script (the very output this window exists to prevent), or to any other script.
    BOOST_CHECK(LegacyReturnWindowCoinstakeProblem(shape({CTxOut{100, legacy_script}}), true, ready).find("only its quantum return output") != std::string::npos);
    BOOST_CHECK(LegacyReturnWindowCoinstakeProblem(shape({CTxOut{100, other_script}}), true, ready).find("only its quantum return output") != std::string::npos);
    // A second output of value, even to the return script (a stake split or a donation).
    BOOST_CHECK(LegacyReturnWindowCoinstakeProblem(shape({CTxOut{60, ready.script}, CTxOut{40, ready.script}}), true, ready).find("exactly one output") != std::string::npos);
    BOOST_CHECK(LegacyReturnWindowCoinstakeProblem(shape({CTxOut{60, ready.script}, CTxOut{40, other_script}}), true, ready).find("only its quantum return output") != std::string::npos);
    // No output of value at all.
    BOOST_CHECK(LegacyReturnWindowCoinstakeProblem(shape({}), true, ready).find("exactly one output") != std::string::npos);
    BOOST_CHECK(LegacyReturnWindowCoinstakeProblem(shape({CTxOut{0, ready.script}}), true, ready).find("exactly one output") != std::string::npos);
}

BOOST_AUTO_TEST_SUITE_END()

} // namespace wallet
