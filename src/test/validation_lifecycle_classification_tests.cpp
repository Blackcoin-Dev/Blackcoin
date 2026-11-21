// Copyright (c) 2026 Blackcoin Core Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <addresstype.h>
#include <chain.h>
#include <coins.h>
#include <consensus/tx_verify.h>
#include <consensus/validation.h>
#include <primitives/transaction.h>
#include <script/interpreter.h>
#include <script/script.h>
#include <script/script_error.h>
#include <sync.h>
#include <test/util/setup_common.h>
#include <validation.h>

#include <boost/test/unit_test.hpp>

#include <tuple>
#include <string>
#include <utility>
#include <vector>

BOOST_FIXTURE_TEST_SUITE(validation_lifecycle_classification_tests, BasicTestingSetup)

namespace {

CTransaction OneInputTx(const COutPoint& prevout, CAmount value_out, const CScript& script_out, int version = 2, uint32_t time = 0)
{
    CMutableTransaction mtx;
    mtx.nVersion = version;
    mtx.nTime = time;
    mtx.vin.emplace_back(prevout);
    mtx.vout.emplace_back(value_out, script_out);
    return CTransaction{mtx};
}

CScript UnknownWitness(int version) { return GetScriptForDestination(WitnessUnknown{version, std::vector<unsigned char>(32, 0x42)}); }

} // namespace

// Mempool acceptance reports exactly the phase-gate rejections as a recent
// consensus change, which net_processing does not punish. Everything else that
// the Quantum Quasar rules reject stays an ordinary consensus failure.
BOOST_AUTO_TEST_CASE(lifecycle_gate_reasons_are_exactly_the_phase_gates)
{
    // The literal texts are the public reject reasons. They are written out here
    // on purpose: renaming a constant in validation.h fails this test.
    const std::vector<std::pair<std::string, const char*>> gates{
        {"legacy-spend-disabled", quantum_reject::LEGACY_SPEND_DISABLED},
        {"legacy-output-disabled", quantum_reject::LEGACY_OUTPUT_DISABLED},
        {"blackcoin-migration-spend-premature", quantum_reject::MIGRATION_SPEND_PREMATURE},
        {"goldrush-payout-spend-premature", quantum_reject::GOLDRUSH_PAYOUT_SPEND_PREMATURE},
        {"quantum-lineage-anchor-required", quantum_reject::LINEAGE_ANCHOR_REQUIRED},
        {"quantum-tier-output-premature", quantum_reject::TIER_OUTPUT_PREMATURE},
        {"unsupported-nested-witness-spend", quantum_reject::NESTED_WITNESS_SPEND},
        {"unsupported-witness-v1-spend", quantum_reject::WITNESS_V1_SPEND},
        {"unsupported-witness-v1-output", quantum_reject::WITNESS_V1_OUTPUT},
        {"unknown-quantum-witness-spend", quantum_reject::UNKNOWN_WITNESS_SPEND},
        {"unknown-quantum-witness-output", quantum_reject::UNKNOWN_WITNESS_OUTPUT},
        {"eutxo-spend-disabled", quantum_reject::EUTXO_SPEND_DISABLED},
        {"eutxo-output-disabled", quantum_reject::EUTXO_OUTPUT_DISABLED},
    };
    for (const auto& [text, constant] : gates) {
        BOOST_CHECK_EQUAL(text, std::string{constant});
        BOOST_CHECK_MESSAGE(IsQuantumLifecycleGateRejectReason(text), text);
    }

    const std::vector<std::string> punitive{
        "",
        "quantum-output-downgrade",
        "bad-goldrush-payout-marker",
        "bad-stake-tier-transition",
        "bad-txns-spends-locked-coin",
        "bad-txns-in-belowout",
        "bad-txns-fee-not-enough",
        "bad-txns-inputvalues-outofrange",
        "bad-txns-vout-negative",
        "bad-txns-duplicate-inputs",
        "mandatory-script-verify-flag-failed (Signature hash type missing or not understood)",
        "bad-eutxo-transition",
        "invalid-quantum-sighash-domain",
        "stale-demurrage-attestation-state",
        "demurrage-attestation-target-locked",
        "legacy-spend-disabled ",
        "Legacy-spend-disabled",
    };
    for (const std::string& reason : punitive) {
        BOOST_CHECK_MESSAGE(!IsQuantumLifecycleGateRejectReason(reason), reason);
    }
}

// The classifier reads the reason the producing functions return. Run the
// producers (not a copy of their list) and check each reason against the
// literal public text and the classifier, so a changed producer or a renamed
// reason fails here instead of silently turning a refusal punitive.
BOOST_AUTO_TEST_CASE(classifier_agrees_with_the_producing_functions)
{
    const unsigned int quantum = SCRIPT_VERIFY_QUANTUM_ML_DSA;
    const CScript op_true = CScript() << OP_TRUE;
    const CScript eutxo = GetScriptForEUTXO({}, op_true);

    // Output rules: CheckQuantumQuasarOutputs.
    const std::vector<std::tuple<std::string, unsigned int, CScript>> output_cases{
        {"legacy-output-disabled", SCRIPT_VERIFY_LEGACY_ECDSA_LOCKOUT, op_true},
        {"eutxo-output-disabled", quantum, eutxo},
        {"unsupported-witness-v1-output", quantum, UnknownWitness(1)},
        {"unknown-quantum-witness-output", quantum | SCRIPT_VERIFY_TAPROOT, UnknownWitness(2)},
    };
    for (const auto& [expected, flags, script] : output_cases) {
        const CTransaction tx = OneInputTx(COutPoint{uint256::ONE, 0}, 1000, script);
        std::string reason;
        BOOST_CHECK_MESSAGE(!CheckQuantumQuasarOutputs(tx, flags, reason), expected);
        BOOST_CHECK_EQUAL(reason, expected);
        BOOST_CHECK_MESSAGE(IsQuantumLifecycleGateRejectReason(reason), reason);
    }

    // Spend rules: CheckQuantumQuasarTransaction on a coin view.
    const std::vector<std::tuple<std::string, unsigned int, CScript>> spend_cases{
        {"legacy-spend-disabled", SCRIPT_VERIFY_LEGACY_ECDSA_LOCKOUT, op_true},
        {"eutxo-spend-disabled", quantum | SCRIPT_VERIFY_TAPROOT, eutxo},
        {"unsupported-witness-v1-spend", quantum, UnknownWitness(1)},
        {"unknown-quantum-witness-spend", quantum | SCRIPT_VERIFY_TAPROOT, UnknownWitness(2)},
    };
    for (const auto& [expected, flags, script] : spend_cases) {
        CCoinsView base;
        CCoinsViewCache view{&base};
        const COutPoint prevout{uint256{7}, 0};
        view.AddCoin(prevout, Coin{CTxOut{1000, script}, 1, false, false, 0}, false);
        // An empty output passes the output rules, so the spend rule is what refuses.
        const CTransaction tx = OneInputTx(prevout, 0, CScript());
        std::string reason;
        BOOST_CHECK_MESSAGE(!CheckQuantumQuasarTransaction(tx, view, flags, 1, Params().GetConsensus(), 0, reason), expected);
        BOOST_CHECK_EQUAL(reason, expected);
        BOOST_CHECK_MESSAGE(IsQuantumLifecycleGateRejectReason(reason), reason);
    }
    // The gate reasons that need a Gold Rush payout marker or a tier program
    // (blackcoin-migration-spend-premature, goldrush-payout-spend-premature,
    // quantum-tier-output-premature, quantum-lineage-anchor-required,
    // unsupported-nested-witness-spend) are covered by the literal pin above.
}

// The three reasons CheckTxInputs returns for the demurrage-sensitive checks
// keep their public text, and are produced by the real function.
BOOST_AUTO_TEST_CASE(input_value_reasons_match_the_producing_function)
{
    BOOST_CHECK_EQUAL(std::string{Consensus::REJECT_TX_IN_BELOW_OUT}, "bad-txns-in-belowout");
    BOOST_CHECK_EQUAL(std::string{Consensus::REJECT_TX_SPENDS_LOCKED_COIN}, "bad-txns-spends-locked-coin");
    BOOST_CHECK_EQUAL(std::string{Consensus::REJECT_TX_FEE_NOT_ENOUGH}, "bad-txns-fee-not-enough");

    CCoinsView base;
    CCoinsViewCache view{&base};
    const COutPoint prevout{uint256{9}, 0};
    view.AddCoin(prevout, Coin{CTxOut{1000, CScript() << OP_TRUE}, 1, false, false, 0}, false);
    const int64_t after_v3_1 = Params().GetConsensus().nProtocolV3_1Time + 1000;

    {
        TxValidationState state;
        CAmount fee{0};
        const CTransaction tx = OneInputTx(prevout, 2000, CScript() << OP_TRUE, 1, after_v3_1);
        BOOST_CHECK(!Consensus::CheckTxInputs(tx, state, view, 10, after_v3_1, after_v3_1, fee));
        BOOST_CHECK_EQUAL(state.GetRejectReason(), "bad-txns-in-belowout");
    }
    {
        TxValidationState state;
        CAmount fee{0};
        const CTransaction tx = OneInputTx(prevout, 1000, CScript() << OP_TRUE, 1, after_v3_1);
        BOOST_CHECK(!Consensus::CheckTxInputs(tx, state, view, 10, after_v3_1, after_v3_1, fee));
        BOOST_CHECK_EQUAL(state.GetRejectReason(), "bad-txns-fee-not-enough");
    }
}

// The typed missing-FORKID error: the public text is the same as for an
// undefined hash type, every other failure keeps its own value, and the block
// path (CheckInputScripts) returns exactly what the mempool variant returns.
BOOST_AUTO_TEST_CASE(missing_forkid_is_typed_and_block_result_is_unchanged)
{
    BOOST_CHECK_EQUAL(ScriptErrorString(SCRIPT_ERR_SIG_FORKID_MISSING), ScriptErrorString(SCRIPT_ERR_SIG_HASHTYPE));

    ScriptError err{SCRIPT_ERR_OK};
    const std::vector<unsigned char> no_forkid{0x30, 0x00, 0x01};
    const std::vector<unsigned char> with_forkid{0x30, 0x00, 0x41};
    BOOST_CHECK(!CheckSignatureEncoding(no_forkid, SCRIPT_ENABLE_SIGHASH_FORKID, &err));
    BOOST_CHECK_EQUAL(err, SCRIPT_ERR_SIG_FORKID_MISSING);
    BOOST_CHECK(CheckSignatureEncoding(with_forkid, SCRIPT_ENABLE_SIGHASH_FORKID, &err));
    // An undefined hash type under STRICTENC keeps its own error.
    const std::vector<unsigned char> undefined_type{0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x01, 0x05};
    err = SCRIPT_ERR_OK;
    BOOST_CHECK(!CheckSignatureEncoding(undefined_type, SCRIPT_VERIFY_STRICTENC | SCRIPT_ENABLE_SIGHASH_FORKID, &err));
    BOOST_CHECK_EQUAL(err, SCRIPT_ERR_SIG_HASHTYPE);

    // Whole-transaction path: a pay-to-pubkey input whose signature push ends in
    // 0x01. The encoding check runs before any signature verification.
    const CScript script_pub_key = CScript() << std::vector<unsigned char>(33, 0x02) << OP_CHECKSIG;
    CCoinsView base;
    CCoinsViewCache view{&base};
    const COutPoint prevout{uint256{5}, 0};
    view.AddCoin(prevout, Coin{CTxOut{1000, script_pub_key}, 1, false, false, 0}, false);
    BOOST_REQUIRE(Params().GetConsensus().nQuantumSighashChainId != 0);

    auto make_tx = [&](const std::vector<unsigned char>& sig) {
        CMutableTransaction mtx;
        mtx.nVersion = 2;
        mtx.vin.emplace_back(prevout);
        mtx.vin[0].scriptSig = CScript() << sig;
        mtx.vout.emplace_back(900, CScript() << OP_TRUE);
        return CTransaction{mtx};
    };
    const unsigned int flags = SCRIPT_VERIFY_P2SH | SCRIPT_ENABLE_SIGHASH_FORKID;

    LOCK(cs_main);
    {
        const CTransaction tx = make_tx(no_forkid);
        TxValidationState plain_state, typed_state;
        PrecomputedTransactionData plain_txdata, typed_txdata;
        ScriptError typed_error{SCRIPT_ERR_OK};
        const bool plain = CheckInputScripts(tx, plain_state, view, flags, false, false, plain_txdata);
        const bool typed = CheckInputScriptsWithError(tx, typed_state, view, flags, false, false, typed_txdata, &typed_error);
        BOOST_CHECK(!plain);
        BOOST_CHECK(!typed);
        BOOST_CHECK_EQUAL(typed_error, SCRIPT_ERR_SIG_FORKID_MISSING);
        // Same result class and the same public reason string as before.
        BOOST_CHECK(plain_state.GetResult() == TxValidationResult::TX_CONSENSUS);
        BOOST_CHECK(typed_state.GetResult() == TxValidationResult::TX_CONSENSUS);
        BOOST_CHECK_EQUAL(plain_state.GetRejectReason(), typed_state.GetRejectReason());
        BOOST_CHECK_EQUAL(plain_state.GetRejectReason(),
                          "mandatory-script-verify-flag-failed (Signature hash type missing or not understood)");
    }
    {
        // A signature that carries FORKID but is not valid fails with another error.
        const CTransaction tx = make_tx(with_forkid);
        TxValidationState state;
        PrecomputedTransactionData txdata;
        ScriptError error{SCRIPT_ERR_OK};
        BOOST_CHECK(!CheckInputScriptsWithError(tx, state, view, flags, false, false, txdata, &error));
        BOOST_CHECK(error != SCRIPT_ERR_OK);
        BOOST_CHECK(error != SCRIPT_ERR_SIG_FORKID_MISSING);
    }
}

// The demurrage reclassification only applies to the three demurrage reasons and
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
    for (const std::string reason : {"legacy-spend-disabled", "", "bad-txns-premature-spend-of-coinbase", "stale-demurrage-attestation-state"}) {
        BOOST_CHECK(!DemurrageRejectionDependsOnNextBlock(tx, view, tip, consensus, reason, 0));
    }
    // The inputs are not in the view, so nothing can be said about demurrage.
    for (const std::string reason : {"bad-txns-in-belowout", "bad-txns-spends-locked-coin", "bad-txns-fee-not-enough"}) {
        BOOST_CHECK(!DemurrageRejectionDependsOnNextBlock(tx, view, tip, consensus, reason, 0));
    }
}

// Negative controls for the contract: the requirements must have held at the
// preceding point. Demurrage is inactive on this chain at these heights, so the
// preceding point equals the current one and nothing that fails now passed then.
BOOST_AUTO_TEST_CASE(demurrage_reclassification_requires_the_previous_point_to_pass)
{
    CCoinsView view_base;
    CCoinsViewCache view(&view_base);
    const COutPoint prevout{uint256{3}, 0};
    view.AddCoin(prevout, Coin{CTxOut{100 * COIN, CScript() << OP_TRUE}, 1, false, false, 0}, false);
    CBlockIndex parent;
    parent.nHeight = 9;
    CBlockIndex tip;
    tip.pprev = &parent;
    tip.nHeight = 10;
    const Consensus::Params& consensus = Params().GetConsensus();
    const int64_t after_v3_1 = consensus.nProtocolV3_1Time + 1000;

    // More output than input: already short at the preceding point.
    const CTransaction inflating = OneInputTx(prevout, 100 * COIN + 1, CScript() << OP_TRUE, 1, after_v3_1);
    BOOST_CHECK(!DemurrageRejectionDependsOnNextBlock(inflating, view, tip, consensus, "bad-txns-in-belowout", after_v3_1));
    // A locked-coin reason on a coin that was unlocked, but the transaction also
    // creates more value than the input had: not a next-block effect.
    BOOST_CHECK(!DemurrageRejectionDependsOnNextBlock(inflating, view, tip, consensus, "bad-txns-spends-locked-coin", after_v3_1));
    // A fee below the minimum at the preceding point.
    const CTransaction zero_fee = OneInputTx(prevout, 100 * COIN, CScript() << OP_TRUE, 1, after_v3_1);
    BOOST_CHECK(!DemurrageRejectionDependsOnNextBlock(zero_fee, view, tip, consensus, "bad-txns-fee-not-enough", after_v3_1));
    // A fee at the minimum at the preceding point passes the helper (the caller
    // only asks it after the real check failed for a changed value).
    const CAmount min_fee = GetMinFee(zero_fee, after_v3_1);
    const CTransaction at_minimum = OneInputTx(prevout, 100 * COIN - min_fee, CScript() << OP_TRUE, 1, after_v3_1);
    BOOST_CHECK_EQUAL(GetMinFee(at_minimum, after_v3_1), min_fee);
    BOOST_CHECK(DemurrageRejectionDependsOnNextBlock(at_minimum, view, tip, consensus, "bad-txns-fee-not-enough", after_v3_1));
}

BOOST_AUTO_TEST_SUITE_END()
