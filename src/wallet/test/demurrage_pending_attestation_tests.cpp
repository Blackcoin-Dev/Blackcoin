// Copyright (c) 2026 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <addresstype.h>
#include <chainparams.h>
#include <coins.h>
#include <consensus/demurrage.h>
#include <crypto/mldsa.h>
#include <key.h>
#include <script/script.h>
#include <test/util/setup_common.h>
#include <uint256.h>
#include <validation.h>
#include <wallet/staking.h>
#include <wallet/test/util.h>
#include <wallet/wallet.h>

#include <boost/test/unit_test.hpp>

namespace wallet {
namespace {

constexpr int STATE_HEIGHT{4321};
constexpr uint32_t STATE_TIME{1700000000};
constexpr uint32_t STATE_COVERAGE{4300};

Consensus::DemurrageAttestationRecord Record(const uint256& block_hash, const uint256& txid, uint32_t output_index)
{
    Consensus::DemurrageAttestationRecord record;
    record.pubkey_hash = uint256::ONE;
    record.state.height = STATE_HEIGHT;
    record.state.time = STATE_TIME;
    record.state.coverage_start_height = STATE_COVERAGE;
    record.source_block_hash = block_hash;
    record.source_txid = txid;
    record.source_output_index = output_index;
    return record;
}

PendingWalletAttestation Pending(const uint256& key, const uint256& block_hash, const uint256& txid, uint32_t output_index)
{
    PendingWalletAttestation entry;
    entry.key_hash = key;
    entry.previous_height = STATE_HEIGHT;
    entry.previous_time = STATE_TIME;
    entry.previous_coverage_start_height = STATE_COVERAGE;
    entry.previous_source = Consensus::DemurrageAttestationSource{block_hash, txid, output_index};
    return entry;
}

} // namespace

BOOST_FIXTURE_TEST_SUITE(demurrage_pending_attestation_tests, TestChain100Setup)

BOOST_AUTO_TEST_CASE(a_pending_attestation_matches_only_the_complete_referenced_state)
{
    const uint256 block_a = uint256S("aa");
    const uint256 block_b = uint256S("bb");
    const uint256 tx_a = uint256S("1a");
    const uint256 tx_b = uint256S("1b");
    const std::optional<Consensus::DemurrageAttestationRecord> record = Record(block_a, tx_a, 2);

    BOOST_CHECK(PendingAttestationReferencesRecord(Pending(uint256::ONE, block_a, tx_a, 2), record));
    // Equal height, time and coverage on a competing history: a different referenced state.
    BOOST_CHECK(!PendingAttestationReferencesRecord(Pending(uint256::ONE, block_b, tx_a, 2), record));
    BOOST_CHECK(!PendingAttestationReferencesRecord(Pending(uint256::ONE, block_a, tx_b, 2), record));
    BOOST_CHECK(!PendingAttestationReferencesRecord(Pending(uint256::ONE, block_a, tx_a, 3), record));

    // The coordinates themselves still matter.
    PendingWalletAttestation shifted = Pending(uint256::ONE, block_a, tx_a, 2);
    shifted.previous_height = STATE_HEIGHT + 1;
    BOOST_CHECK(!PendingAttestationReferencesRecord(shifted, record));
    shifted = Pending(uint256::ONE, block_a, tx_a, 2);
    shifted.previous_time = STATE_TIME + 1;
    BOOST_CHECK(!PendingAttestationReferencesRecord(shifted, record));
    shifted = Pending(uint256::ONE, block_a, tx_a, 2);
    shifted.previous_coverage_start_height = STATE_COVERAGE + 1;
    BOOST_CHECK(!PendingAttestationReferencesRecord(shifted, record));

    // A key with no recorded state matches only an attestation that references none; a recorded state
    // never matches an attestation that names no source, nor the reverse.
    PendingWalletAttestation first_ever;
    first_ever.key_hash = uint256::ONE;
    BOOST_CHECK(PendingAttestationReferencesRecord(first_ever, std::nullopt));
    BOOST_CHECK(!PendingAttestationReferencesRecord(first_ever, record));
    BOOST_CHECK(!PendingAttestationReferencesRecord(Pending(uint256::ONE, block_a, tx_a, 2), std::nullopt));
    PendingWalletAttestation without_source = Pending(uint256::ONE, block_a, tx_a, 2);
    without_source.previous_source.reset();
    BOOST_CHECK(!PendingAttestationReferencesRecord(without_source, record));
    first_ever.previous_time = 1;
    BOOST_CHECK(!PendingAttestationReferencesRecord(first_ever, std::nullopt));
}

BOOST_AUTO_TEST_CASE(finding_a_pending_attestation_skips_a_different_source_and_other_keys)
{
    const uint256 block_a = uint256S("aa");
    const uint256 block_b = uint256S("bb");
    const uint256 tx_a = uint256S("1a");
    const uint256 other_key = uint256S("55");
    const std::optional<Consensus::DemurrageAttestationRecord> record = Record(block_a, tx_a, 0);

    std::vector<PendingWalletAttestation> pending;
    pending.push_back(Pending(uint256::ONE, block_b, tx_a, 0));  // same coordinates, other source
    pending.back().txid = uint256S("e1");
    pending.push_back(Pending(other_key, block_a, tx_a, 0));      // same state, other key
    pending.back().txid = uint256S("e2");
    BOOST_CHECK(FindPendingAttestationForState(pending, uint256::ONE, record) == nullptr);

    pending.push_back(Pending(uint256::ONE, block_a, tx_a, 0));
    pending.back().txid = uint256S("e3");
    const PendingWalletAttestation* found = FindPendingAttestationForState(pending, uint256::ONE, record);
    BOOST_REQUIRE(found != nullptr);
    BOOST_CHECK(found->txid == uint256S("e3"));
}

namespace {
struct PendingFixture {
    std::vector<unsigned char> public_key;
    std::vector<unsigned char> private_key;
    CScript key_script;
    uint256 key_hash;
};

PendingFixture MakeKey()
{
    PendingFixture f;
    BOOST_REQUIRE(ML_DSA::KeyGen(f.public_key, f.private_key));
    f.key_script = GetScriptForDestination(WitnessUnknown{QUANTUM_MIGRATION_WITNESS_VERSION,
                                                          QuantumMigrationProgramForPubkey(f.public_key)});
    const auto hash = Consensus::DemurrageControllingKeyHashForScript(f.key_script);
    BOOST_REQUIRE(hash.has_value());
    f.key_hash = *hash;
    return f;
}

//! A pending attestation transaction: spends `fee_input`, carries one attestation of `target` over the state
//! `record` names (none for a first attestation). The signature is not verified by anything under test.
CTransactionRef AttestationTransaction(const PendingFixture& f, const COutPoint& fee_input, const COutPoint& target,
                                       const std::optional<Consensus::DemurrageAttestationRecord>& record)
{
    std::optional<Consensus::DemurrageAttestationSource> source;
    if (record) source = Consensus::DemurrageAttestationSource{record->source_block_hash, record->source_txid, record->source_output_index};
    CMutableTransaction tx;
    tx.nVersion = 2;
    tx.vin.emplace_back(fee_input);
    tx.vout.emplace_back(COIN, CScript{} << OP_TRUE);
    tx.vout.emplace_back(0, Consensus::BuildDemurrageAttestationScript(
        fee_input, target, record ? std::optional<int>{record->state.height} : std::nullopt,
        record ? record->state.time : 0, record ? record->state.coverage_start_height : 0, source, f.public_key,
        std::vector<unsigned char>(ML_DSA::SIGNATURE_BYTES, 0x5a)));
    return MakeTransactionRef(std::move(tx));
}
} // namespace

BOOST_AUTO_TEST_CASE(pending_attestations_are_classified_by_state_target_inputs_and_broadcasting)
{
    const PendingFixture f = MakeKey();
    CKey wallet_key;
    wallet_key.MakeNewKey(true);
    auto wallet = CreateSyncedWallet(*m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), wallet_key);
    wallet->SetBroadcastTransactions(true);
    const Consensus::Params& consensus = Params().GetConsensus();
    const int height = 150;
    const int64_t time = 1700000000;

    const COutPoint target{uint256S("7a"), 0};
    const COutPoint fee_input{uint256S("7b"), 1};
    const COutPoint second_input{uint256S("7c"), 1};
    {
        LOCK(cs_main);
        CCoinsViewCache& view = m_node.chainman->ActiveChainstate().CoinsTip();
        view.AddCoin(target, Coin{CTxOut{5 * COIN, f.key_script}, 10, false, false, 0}, /*possible_overwrite=*/false);
        view.AddCoin(fee_input, Coin{CTxOut{2 * COIN, GetScriptForDestination(PKHash(wallet_key.GetPubKey()))}, 10, false, false, 0}, false);
    }

    const auto add_pending = [&](const COutPoint& input, const std::optional<Consensus::DemurrageAttestationRecord>& record, bool automatic) {
        const CTransactionRef tx = AttestationTransaction(f, input, target, record);
        LOCK(wallet->cs_wallet);
        BOOST_REQUIRE(wallet->AddToWallet(tx, TxStateInactive{}, [&](CWalletTx& wtx, bool) {
            if (automatic) wtx.mapValue["comment"] = "Quantum Quasar demurrage auto-attestation";
            return true;
        }));
        return tx->GetHash();
    };
    const uint256 auto_txid = add_pending(fee_input, std::nullopt, /*automatic=*/true);
    const uint256 manual_txid = add_pending(second_input, std::nullopt, /*automatic=*/false);

    LOCK(cs_main);
    LOCK(wallet->cs_wallet);
    const CCoinsViewCache& view = m_node.chainman->ActiveChainstate().CoinsTip();
    const std::vector<PendingWalletAttestation> pending = PendingWalletDemurrageAttestations(*wallet);
    BOOST_REQUIRE_EQUAL(pending.size(), size_t{2});
    for (const PendingWalletAttestation& entry : pending) {
        BOOST_CHECK(entry.key_hash == f.key_hash);
        BOOST_CHECK(entry.target == target);
        BOOST_CHECK(!entry.previous_source.has_value());
        BOOST_CHECK_EQUAL(entry.automatic, entry.txid == auto_txid); // only the automatic path's own comment counts
    }
    const auto find = [&](const uint256& txid) -> const PendingWalletAttestation& {
        for (const PendingWalletAttestation& entry : pending) if (entry.txid == txid) return entry;
        BOOST_FAIL("pending attestation not listed");
        return pending.front();
    };
    const auto classify = [&](const PendingWalletAttestation& entry, const std::optional<Consensus::DemurrageAttestationRecord>& record) {
        return ClassifyPendingAttestation(*wallet, view, consensus, height, time, entry, record);
    };

    // Current state (none), live target controlled by the key, input present, broadcasting enabled: reusable.
    BOOST_CHECK(classify(find(auto_txid), std::nullopt) == PendingAttestationUse::REUSABLE);
    // Broadcasting disabled: still usable, only temporarily unavailable. Never "unusable".
    wallet->SetBroadcastTransactions(false);
    BOOST_CHECK(classify(find(auto_txid), std::nullopt) == PendingAttestationUse::TEMPORARILY_UNAVAILABLE);
    wallet->SetBroadcastTransactions(true);

    // The key has since attested (a state exists that this attestation does not reference): unusable,
    // and equal coordinates on a different source do not rescue it.
    const Consensus::DemurrageAttestationRecord later = Record(uint256S("aa"), uint256S("1a"), 0);
    BOOST_CHECK(classify(find(auto_txid), later) == PendingAttestationUse::UNUSABLE);
    const COutPoint referencing_input{uint256S("7d"), 1};
    {
        LOCK(cs_main);
        m_node.chainman->ActiveChainstate().CoinsTip().AddCoin(
            referencing_input, Coin{CTxOut{2 * COIN, GetScriptForDestination(PKHash(wallet_key.GetPubKey()))}, 10, false, false, 0}, false);
    }
    // (A pending attestation that does reference `later` is reusable; the same coordinates with another
    // source block are not.)
    const uint256 same_source_txid = [&] {
        const CTransactionRef tx = AttestationTransaction(f, referencing_input, target, later);
        BOOST_REQUIRE(wallet->AddToWallet(tx, TxStateInactive{}));
        return tx->GetHash();
    }();
    const std::vector<PendingWalletAttestation> pending_later = PendingWalletDemurrageAttestations(*wallet);
    const PendingWalletAttestation* referencing = nullptr;
    for (const PendingWalletAttestation& entry : pending_later) if (entry.txid == same_source_txid) referencing = &entry;
    BOOST_REQUIRE(referencing != nullptr);
    BOOST_CHECK(ClassifyPendingAttestation(*wallet, view, consensus, height, time, *referencing, later) == PendingAttestationUse::REUSABLE);
    Consensus::DemurrageAttestationRecord other_source = later;
    other_source.source_block_hash = uint256S("bb");
    BOOST_CHECK(ClassifyPendingAttestation(*wallet, view, consensus, height, time, *referencing, other_source) == PendingAttestationUse::UNUSABLE);

    // The target is gone: unusable.
    {
        LOCK(cs_main);
        CCoinsViewCache& mutable_view = m_node.chainman->ActiveChainstate().CoinsTip();
        BOOST_REQUIRE(mutable_view.SpendCoin(target));
    }
    BOOST_CHECK(classify(find(auto_txid), std::nullopt) == PendingAttestationUse::UNUSABLE);
    BOOST_CHECK(classify(find(manual_txid), std::nullopt) == PendingAttestationUse::UNUSABLE);
    {
        LOCK(cs_main);
        m_node.chainman->ActiveChainstate().CoinsTip().AddCoin(
            target, Coin{CTxOut{5 * COIN, f.key_script}, 10, false, false, 0}, /*possible_overwrite=*/true);
        // The target now belongs to another key.
    }
    BOOST_CHECK(classify(find(auto_txid), std::nullopt) == PendingAttestationUse::REUSABLE);
    PendingFixture stranger = MakeKey();
    {
        LOCK(cs_main);
        m_node.chainman->ActiveChainstate().CoinsTip().AddCoin(
            target, Coin{CTxOut{5 * COIN, stranger.key_script}, 10, false, false, 0}, /*possible_overwrite=*/true);
    }
    BOOST_CHECK(classify(find(auto_txid), std::nullopt) == PendingAttestationUse::UNUSABLE);
    {
        LOCK(cs_main);
        m_node.chainman->ActiveChainstate().CoinsTip().AddCoin(
            target, Coin{CTxOut{5 * COIN, f.key_script}, 10, false, false, 0}, /*possible_overwrite=*/true);
    }

    // An input that is neither a chain coin nor the output of another unconfirmed transaction of the wallet:
    // unusable. (second_input was never added to the chain view; manual_txid spends it.)
    BOOST_CHECK(classify(find(manual_txid), std::nullopt) == PendingAttestationUse::UNUSABLE);
    // The chain coin spent: unusable.
    {
        LOCK(cs_main);
        BOOST_REQUIRE(m_node.chainman->ActiveChainstate().CoinsTip().SpendCoin(fee_input));
    }
    BOOST_CHECK(classify(find(auto_txid), std::nullopt) == PendingAttestationUse::UNUSABLE);
}

BOOST_AUTO_TEST_SUITE_END()

} // namespace wallet
