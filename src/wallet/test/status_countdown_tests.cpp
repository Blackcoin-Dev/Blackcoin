// Copyright (c) 2026 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <addresstype.h>
#include <coins.h>
#include <consensus/demurrage.h>
#include <consensus/params.h>
#include <script/script.h>
#include <test/util/setup_common.h>
#include <wallet/staking.h>

#include <boost/test/unit_test.hpp>

namespace wallet {

BOOST_FIXTURE_TEST_SUITE(status_countdown_tests, BasicTestingSetup)

namespace {
CScript QuantumScript(unsigned char tag)
{
    return GetScriptForDestination(WitnessUnknown{QUANTUM_MIGRATION_WITNESS_VERSION, std::vector<unsigned char>(32, tag)});
}
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
    const CScript ordinary_quantum = QuantumScript(0x31);
    const int64_t curve = Consensus::DemurrageBlocksUntilFirstReduction(0, p);
    BOOST_CHECK(curve > p.DemurrageGraceBlocks());
    // Before activation: 60 blocks to activation, then the curve's own count.
    const auto before = DemurrageFirstReductionCountdown(p, ordinary_quantum, eval, 201, 0);
    BOOST_REQUIRE(before);
    BOOST_CHECK_EQUAL(*before, 60 + curve);
    // The block before activation is one block short of it.
    BOOST_CHECK_EQUAL(*DemurrageFirstReductionCountdown(p, ordinary_quantum, eval, 260, 0), 1 + curve);
}

BOOST_AUTO_TEST_CASE(first_reduction_countdown_is_absent_when_it_would_mislead)
{
    const Consensus::Params p = HeightSchedule();
    // An activation not given by a height has no block countdown.
    Consensus::Params time_only;
    time_only.nDemurrageBlocksPerMonth = 100;
    BOOST_CHECK(!DemurrageFirstReductionCountdown(time_only, QuantumScript(0x31), Consensus::DemurrageEvaluation{}, 5, 0));
    // A hand-made "exempt" evaluation of an ordinary quantum script is not a permanent exemption: the
    // script decides that, and an ordinary quantum script can decay.
    Consensus::DemurrageEvaluation grace;
    grace.exempt = true;
    BOOST_CHECK(DemurrageFirstReductionCountdown(p, QuantumScript(0x31), grace, 201, 0));
}

// The countdown, on evaluations of real coins at the heights that matter. EvaluateDemurrage marks an output
// exempt both for good (a treasury or non-quantum script) and for now (grace of a young output,
// protection by an attestation); only the first has no first reduction. Before activation it reports just
// "inactive", so the script has to say whether the exemption is permanent.
BOOST_AUTO_TEST_CASE(first_reduction_countdown_on_real_evaluations)
{
    Consensus::Params p = HeightSchedule();
    p.nProtocolV4Time = 0;
    p.nGoldRushEndTime = 1000;
    p.nQuantumMigrationDeadlineTime = 2000;
    p.nQuantumSighashChainId = 1;
    const int64_t time = 2001;
    const int activation = p.EffectiveDemurrageActivationHeight();
    BOOST_REQUIRE(p.IsDemurrageActive(activation, time));
    BOOST_REQUIRE(!p.IsDemurrageActive(activation - 1, time));
    const int grace = p.DemurrageGraceBlocks();

    const CScript quantum = QuantumScript(0x41);
    const CScript treasury = CScript() << OP_DUP << OP_HASH160 << std::vector<unsigned char>(20, 0x44) << OP_EQUALVERIFY << OP_CHECKSIG;
    p.m_demurrage_exempt_scripts.push_back(treasury);
    const CScript legacy = CScript() << OP_DUP << OP_HASH160 << std::vector<unsigned char>(20, 0x45) << OP_EQUALVERIFY << OP_CHECKSIG;
    const auto coin = [](const CScript& script, int height) { return Coin{CTxOut{COIN, script}, height, false, false, 0}; };
    const int64_t curve0 = Consensus::DemurrageBlocksUntilFirstReduction(0, p);

    // Before activation, 10 blocks short of it: a quantum output counts down the distance plus the whole curve;
    // a treasury output and a non-quantum output are exempt for good and have no countdown at all.
    const int before = activation - 10;
    for (const auto& [script, expect] : std::vector<std::pair<CScript, bool>>{{quantum, true}, {treasury, false}, {legacy, false}}) {
        const Consensus::DemurrageEvaluation eval = Consensus::EvaluateDemurrage(coin(script, 5), p, before, time);
        BOOST_CHECK_EQUAL(eval.exemption, "inactive"); // all three look alike to the evaluation
        const auto countdown = DemurrageFirstReductionCountdown(p, script, eval, before, time);
        BOOST_CHECK_EQUAL(countdown.has_value(), expect);
        if (expect) BOOST_CHECK_EQUAL(*countdown, 10 + curve0);
    }

    // Active, a young output (in grace): temporary exemption. Its countdown is what is left of grace plus the curve.
    const int age = 30;
    const Consensus::DemurrageEvaluation young = Consensus::EvaluateDemurrage(coin(quantum, activation + 5), p, activation + 5 + age, time);
    BOOST_REQUIRE(young.exempt);
    BOOST_CHECK_EQUAL(young.exemption, "young");
    BOOST_CHECK_EQUAL(young.inactive_blocks, age);
    const auto young_countdown = DemurrageFirstReductionCountdown(p, quantum, young, activation + 5 + age, time);
    BOOST_REQUIRE(young_countdown);
    BOOST_CHECK_EQUAL(*young_countdown, curve0 - age);
    BOOST_CHECK(*young_countdown > grace - age); // longer than the grace left: the curve adds its own first blocks

    // Active, protected by an attestation 20 blocks ago: temporary too, counted from the attestation.
    const int now = activation + grace + 100;
    const Consensus::DemurrageEvaluation attested = Consensus::EvaluateDemurrage(
        coin(quantum, 5), p, now, time, now - 20, now - 20);
    BOOST_REQUIRE(attested.exempt);
    BOOST_CHECK_EQUAL(attested.exemption, "attested");
    BOOST_CHECK_EQUAL(attested.inactive_blocks, 20);
    const auto attested_countdown = DemurrageFirstReductionCountdown(p, quantum, attested, now, time);
    BOOST_REQUIRE(attested_countdown);
    BOOST_CHECK_EQUAL(*attested_countdown, curve0 - 20);

    // Active, permanently exempt scripts: no countdown whatever their evaluation says.
    for (const CScript& script : {treasury, legacy}) {
        const Consensus::DemurrageEvaluation eval = Consensus::EvaluateDemurrage(coin(script, 5), p, now, time);
        BOOST_REQUIRE(eval.exempt);
        BOOST_CHECK(!DemurrageFirstReductionCountdown(p, script, eval, now, time));
        BOOST_CHECK(!Consensus::DemurragePermanentExemption(script, p).empty());
    }
    BOOST_CHECK(Consensus::DemurragePermanentExemption(quantum, p).empty());
    BOOST_CHECK_EQUAL(Consensus::DemurragePermanentExemption(treasury, p), "treasury");
    BOOST_CHECK_EQUAL(Consensus::DemurragePermanentExemption(legacy, p), "non_quantum");

    // Decaying and locked outputs: a decaying one has already been reduced (0), a locked one is past it (none).
    const Consensus::DemurrageEvaluation decaying = Consensus::EvaluateDemurrage(coin(quantum, 5), p, now, time);
    BOOST_REQUIRE(!decaying.exempt && !decaying.locked && decaying.burned_value > 0);
    BOOST_CHECK_EQUAL(DemurrageFirstReductionCountdown(p, quantum, decaying, now, time).value_or(-1), 0);
    const int late = activation + p.DemurrageZeroBlocks() + 50;
    const Consensus::DemurrageEvaluation locked = Consensus::EvaluateDemurrage(coin(quantum, 5), p, late, time);
    BOOST_REQUIRE(locked.locked);
    BOOST_CHECK(!DemurrageFirstReductionCountdown(p, quantum, locked, late, time));
}

BOOST_AUTO_TEST_SUITE_END()

} // namespace wallet
