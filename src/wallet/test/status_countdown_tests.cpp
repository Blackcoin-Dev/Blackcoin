// Copyright (c) 2026 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <consensus/demurrage.h>
#include <consensus/params.h>
#include <test/util/setup_common.h>
#include <wallet/staking.h>

#include <boost/test/unit_test.hpp>

namespace wallet {

BOOST_FIXTURE_TEST_SUITE(status_countdown_tests, BasicTestingSetup)

namespace {
Consensus::Params HeightSchedule()
{
    Consensus::Params p;
    p.nQuantumLifecycleStartHeight = 1;
    p.nGoldRushEndHeight = 200;
    p.nQuantumMigrationEndHeight = 260;
    p.nCoinbaseMaturity = 10;
    p.nDemurrageBlocksPerMonth = 100;
    return p;
}
} // namespace

BOOST_AUTO_TEST_CASE(first_reduction_countdown_includes_the_distance_to_activation)
{
    const Consensus::Params p = HeightSchedule();
    BOOST_REQUIRE_EQUAL(p.EffectiveDemurrageActivationHeight(), 261);
    Consensus::DemurrageEvaluation eval; // before Final every output reports no inactive blocks
    const int64_t curve = Consensus::DemurrageBlocksUntilFirstReduction(0, p);
    BOOST_CHECK(curve > p.DemurrageGraceBlocks());
    // Before activation: 60 blocks to activation, then the curve's own count.
    const auto before = DemurrageFirstReductionCountdown(p, eval, 201, 0);
    BOOST_REQUIRE(before);
    BOOST_CHECK_EQUAL(*before, 60 + curve);
    // The block before activation is one block short of it.
    BOOST_CHECK_EQUAL(*DemurrageFirstReductionCountdown(p, eval, 260, 0), 1 + curve);
}

BOOST_AUTO_TEST_CASE(first_reduction_countdown_is_absent_when_it_would_mislead)
{
    const Consensus::Params p = HeightSchedule();
    Consensus::DemurrageEvaluation exempt;
    exempt.exempt = true;
    BOOST_CHECK(!DemurrageFirstReductionCountdown(p, exempt, 201, 0));
    // An activation not given by a height has no block countdown.
    Consensus::Params time_only;
    time_only.nDemurrageBlocksPerMonth = 100;
    BOOST_CHECK(!DemurrageFirstReductionCountdown(time_only, Consensus::DemurrageEvaluation{}, 5, 0));
}

BOOST_AUTO_TEST_SUITE_END()

} // namespace wallet
