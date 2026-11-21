// Copyright (c) 2026 Blackcoin Core Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <chain.h>
#include <coins.h>
#include <consensus/validation.h>
#include <primitives/transaction.h>
#include <test/util/setup_common.h>
#include <validation.h>

#include <boost/test/unit_test.hpp>

#include <string>
#include <vector>

BOOST_FIXTURE_TEST_SUITE(validation_lifecycle_classification_tests, BasicTestingSetup)

// Mempool acceptance reports exactly the phase-gate rejections as a recent
// consensus change, which net_processing does not punish. Everything else that
// the Quantum Quasar rules reject stays an ordinary consensus failure.
BOOST_AUTO_TEST_CASE(lifecycle_gate_reasons_are_exactly_the_phase_gates)
{
    const std::vector<std::string> gates{
        "legacy-spend-disabled",
        "legacy-output-disabled",
        "blackcoin-migration-spend-premature",
        "goldrush-payout-spend-premature",
        "quantum-lineage-anchor-required",
        "quantum-tier-output-premature",
        "unsupported-nested-witness-spend",
        "unsupported-witness-v1-spend",
        "unsupported-witness-v1-output",
        "unknown-quantum-witness-spend",
        "unknown-quantum-witness-output",
        "eutxo-spend-disabled",
        "eutxo-output-disabled",
    };
    for (const std::string& reason : gates) {
        BOOST_CHECK_MESSAGE(IsQuantumLifecycleGateRejectReason(reason), reason);
    }

    const std::vector<std::string> punitive{
        "",
        "quantum-output-downgrade",
        "bad-goldrush-payout-marker",
        "bad-stake-tier-transition",
        "bad-txns-spends-locked-coin",
        "bad-txns-in-belowout",
        "bad-txns-inputvalues-outofrange",
        "bad-txns-vout-negative",
        "bad-txns-duplicate-inputs",
        "mandatory-script-verify-flag-failed (Signature hash type missing or not understood)",
        "bad-eutxo-transition",
        "invalid-quantum-sighash-domain",
        "legacy-spend-disabled ",
        "Legacy-spend-disabled",
    };
    for (const std::string& reason : punitive) {
        BOOST_CHECK_MESSAGE(!IsQuantumLifecycleGateRejectReason(reason), reason);
    }
}

// The demurrage reclassification only applies to the two demurrage reasons and
// never to a coinbase or to a transaction whose inputs are missing.
BOOST_AUTO_TEST_CASE(demurrage_reclassification_needs_a_demurrage_reason)
{
    CCoinsView view_base;
    CCoinsViewCache view(&view_base);
    CBlockIndex parent;
    parent.nHeight = 9;
    CBlockIndex tip;
    tip.pprev = &parent;
    tip.nHeight = 10;

    CMutableTransaction mtx;
    mtx.vin.emplace_back(COutPoint(uint256{1}, 0));
    mtx.vout.emplace_back(1, CScript());
    const CTransaction tx{mtx};

    const Consensus::Params& consensus = Params().GetConsensus();
    for (const std::string reason : {"bad-txns-fee-not-enough", "legacy-spend-disabled", "", "bad-txns-premature-spend-of-coinbase"}) {
        BOOST_CHECK(!DemurrageRejectionDependsOnNextBlock(tx, view, tip, consensus, reason));
    }
    // The inputs are not in the view, so nothing can be said about demurrage.
    BOOST_CHECK(!DemurrageRejectionDependsOnNextBlock(tx, view, tip, consensus, "bad-txns-in-belowout"));
    BOOST_CHECK(!DemurrageRejectionDependsOnNextBlock(tx, view, tip, consensus, "bad-txns-spends-locked-coin"));
}

BOOST_AUTO_TEST_SUITE_END()
