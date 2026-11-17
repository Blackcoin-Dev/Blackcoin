// Copyright (c) 2026 Blackcoin Core Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <wallet/shadow_pow_claim_recovery_types.h>
#include <wallet/test/util.h>
#include <wallet/wallet.h>

#include <boost/test/unit_test.hpp>

namespace wallet {
namespace {

CTransactionRef MakeTx(uint8_t seed, bool coinstake = false)
{
    CMutableTransaction tx;
    tx.vin.emplace_back(COutPoint{uint256{seed}, 0});
    if (coinstake) tx.vout.emplace_back(0, CScript{});
    tx.vout.emplace_back(COIN, CScript{} << OP_TRUE);
    return MakeTransactionRef(std::move(tx));
}

struct RetryWallet {
    CWallet wallet{/*chain=*/nullptr, "", CreateMockableWalletDatabase()};
    RetryWallet()
    {
        BOOST_REQUIRE(wallet.LoadWallet() == DBErrors::LOAD_OK);
        wallet.SetBroadcastTransactions(true);
    }
};

BOOST_AUTO_TEST_SUITE(resubmit_retry_tests)

BOOST_AUTO_TEST_CASE(tip_dependent_refusals_are_told_from_permanent_ones)
{
    for (const char* reason : {"non-final", "non-BIP68-final", "time-too-new", "bad-txns-inputs-missingorspent",
                               "quantum-output-premature", "demurrage-attestation-premature", "mempool full",
                               "too-long-mempool-chain", "wallet-broadcast-in-flight"}) {
        BOOST_CHECK_MESSAGE(CWallet::IsTipDependentRefusal(reason), reason);
    }
    for (const char* reason : {"", "txn-mempool-conflict", "insufficient fee", "bad-txns-in-belowout", "scriptsig-not-pushonly",
                               "shadow-marker-output", "txn-already-in-mempool", "dust"}) {
        BOOST_CHECK_MESSAGE(!CWallet::IsTipDependentRefusal(reason), reason);
    }
}

BOOST_AUTO_TEST_CASE(only_generic_unconfirmed_transactions_are_queued)
{
    RetryWallet fixture;
    CWallet& wallet = fixture.wallet;
    LOCK(wallet.cs_wallet);

    const CTransactionRef plain = MakeTx(1);
    BOOST_REQUIRE(wallet.AddToWallet(plain, TxStateInactive{}));
    BOOST_CHECK(wallet.QueueResubmitRetry(wallet.mapWallet.at(plain->GetHash())));
    BOOST_CHECK(wallet.IsInResubmitRetry(plain->GetHash()));
    // A second queueing is a no-op.
    BOOST_CHECK(wallet.QueueResubmitRetry(wallet.mapWallet.at(plain->GetHash())));
    BOOST_CHECK_EQUAL(wallet.GetResubmitRetryCount(), 1U);

    const CTransactionRef confirmed = MakeTx(2);
    BOOST_REQUIRE(wallet.AddToWallet(confirmed, TxStateConfirmed{uint256{9}, 5, 0}));
    BOOST_CHECK(!wallet.QueueResubmitRetry(wallet.mapWallet.at(confirmed->GetHash())));

    const CTransactionRef stake = MakeTx(3, /*coinstake=*/true);
    BOOST_REQUIRE(wallet.AddToWallet(stake, TxStateInactive{}));
    BOOST_CHECK(!wallet.QueueResubmitRetry(wallet.mapWallet.at(stake->GetHash())));

    // Transactions owned by the Gold Rush claim, recovery and reorg machinery.
    int claim_seed{0};
    for (const char* key : {SHADOW_POW_RESOLUTION_SCHEMA_KEY, SHADOW_POW_LEGACY_CLEANUP_FOR_KEY, SHADOW_POW_QUARANTINE_MARKER_KEY,
                            "qq_shadow_pow_legacy_cleanup_quarantine", "qq_reorg_shadow_resubmit", "qq_auto_shadow_stale",
                            "qq_manual_shadow_abandon"}) {
        const CTransactionRef claim = MakeTx(static_cast<uint8_t>(100 + (++claim_seed)));
        BOOST_REQUIRE(wallet.AddToWallet(claim, TxStateInactive{}, [&](CWalletTx& wtx, bool) {
            wtx.mapValue[key] = "1";
            return true;
        }));
        BOOST_CHECK_MESSAGE(!wallet.QueueResubmitRetry(wallet.mapWallet.at(claim->GetHash())), key);
        BOOST_CHECK(!wallet.IsInResubmitRetry(claim->GetHash()));
    }
    BOOST_CHECK_EQUAL(wallet.GetResubmitRetryCount(), 1U);

    // A wallet that does not broadcast queues nothing.
    wallet.SetBroadcastTransactions(false);
    const CTransactionRef quiet = MakeTx(4);
    BOOST_REQUIRE(wallet.AddToWallet(quiet, TxStateInactive{}));
    BOOST_CHECK(!wallet.QueueResubmitRetry(wallet.mapWallet.at(quiet->GetHash())));
}

BOOST_AUTO_TEST_CASE(entries_leave_when_accepted_confirmed_conflicted_or_abandoned)
{
    RetryWallet fixture;
    CWallet& wallet = fixture.wallet;
    LOCK(wallet.cs_wallet);

    const CTransactionRef accepted = MakeTx(20), confirmed = MakeTx(21), conflicted = MakeTx(22),
                          abandoned = MakeTx(23), gone = MakeTx(24), waiting = MakeTx(25), claim = MakeTx(26);
    for (const CTransactionRef& tx : {accepted, confirmed, conflicted, abandoned, gone, waiting, claim}) {
        BOOST_REQUIRE(wallet.AddToWallet(tx, TxStateInactive{}));
        BOOST_REQUIRE(wallet.QueueResubmitRetry(wallet.mapWallet.at(tx->GetHash())));
    }
    BOOST_CHECK_EQUAL(wallet.GetResubmitRetryCount(), 7U);

    wallet.mapWallet.at(accepted->GetHash()).m_state = TxStateInMempool{};
    wallet.mapWallet.at(confirmed->GetHash()).m_state = TxStateConfirmed{uint256{9}, 5, 0};
    wallet.mapWallet.at(conflicted->GetHash()).m_state = TxStateConflicted{uint256{9}, 5};
    wallet.mapWallet.at(abandoned->GetHash()).m_state = TxStateInactive{/*abandoned=*/true};
    wallet.mapWallet.at(claim->GetHash()).mapValue[SHADOW_POW_RESOLUTION_SCHEMA_KEY] = "1";
    {
        std::vector<uint256> to_erase{gone->GetHash()}, erased;
        BOOST_REQUIRE(wallet.ZapSelectTx(to_erase, erased) == DBErrors::LOAD_OK);
    }

    wallet.PruneResubmitRetry();
    BOOST_CHECK_EQUAL(wallet.GetResubmitRetryCount(), 1U);
    BOOST_CHECK(wallet.IsInResubmitRetry(waiting->GetHash()));
}

BOOST_AUTO_TEST_CASE(the_set_is_bounded)
{
    RetryWallet fixture;
    CWallet& wallet = fixture.wallet;
    LOCK(wallet.cs_wallet);
    size_t queued{0};
    for (uint32_t i = 0; i < CWallet::MAX_RESUBMIT_RETRY_TXS + 50; ++i) {
        CMutableTransaction tx;
        tx.vin.emplace_back(COutPoint{uint256{static_cast<uint8_t>(i % 250 + 1)}, i});
        tx.vout.emplace_back(COIN, CScript{} << OP_TRUE);
        const CTransactionRef ref = MakeTransactionRef(std::move(tx));
        BOOST_REQUIRE(wallet.AddToWallet(ref, TxStateInactive{}));
        if (wallet.QueueResubmitRetry(wallet.mapWallet.at(ref->GetHash()))) ++queued;
    }
    BOOST_CHECK_EQUAL(queued, CWallet::MAX_RESUBMIT_RETRY_TXS);
    BOOST_CHECK_EQUAL(wallet.GetResubmitRetryCount(), CWallet::MAX_RESUBMIT_RETRY_TXS);
}

BOOST_AUTO_TEST_CASE(refusals_back_off_and_missing_inputs_have_a_low_cap)
{
    RetryWallet fixture;
    CWallet& wallet = fixture.wallet;
    LOCK(wallet.cs_wallet);

    const CTransactionRef tx = MakeTx(40);
    BOOST_REQUIRE(wallet.AddToWallet(tx, TxStateInactive{}));
    BOOST_REQUIRE(wallet.QueueResubmitRetry(wallet.mapWallet.at(tx->GetHash())));
    const uint256 txid = tx->GetHash();
    // Queued with no refusal yet: due at any new tip.
    BOOST_CHECK(wallet.IsResubmitRetryDue(txid, uint256{1}, 100));

    // The gap doubles with every refusal, capped, and a tip inside the gap is
    // not retried. A repeated tip is never retried.
    int height{100};
    uint8_t tip_seed{1};
    std::vector<unsigned int> gaps;
    for (int refusal = 0; refusal < 10; ++refusal) {
        wallet.NoteResubmitRefusal(txid, uint256{tip_seed}, height, "non-final");
        const auto info = wallet.GetResubmitRetryInfo(txid);
        BOOST_REQUIRE(info);
        gaps.push_back(info->block_gap);
        BOOST_CHECK(!info->missing_inputs);
        BOOST_CHECK(!wallet.IsResubmitRetryDue(txid, uint256{tip_seed}, height)); // same tip
        if (info->block_gap > 1) {
            BOOST_CHECK(!wallet.IsResubmitRetryDue(txid, uint256{static_cast<uint8_t>(tip_seed + 1)},
                                                   height + static_cast<int>(info->block_gap) - 1));
        }
        height += static_cast<int>(info->block_gap);
        BOOST_CHECK(wallet.IsResubmitRetryDue(txid, uint256{static_cast<uint8_t>(tip_seed + 1)}, height));
        ++tip_seed;
    }
    BOOST_CHECK((gaps == std::vector<unsigned int>{1, 2, 4, 8, 16, 32, 64, 64, 64, 64}));
    BOOST_CHECK_EQUAL(gaps.back(), CWallet::MAX_RESUBMIT_RETRY_BLOCK_GAP);
    // A reorg to a lower height re-opens the entry.
    BOOST_CHECK(wallet.IsResubmitRetryDue(txid, uint256{200}, 50));

    // A refusal for a missing input leaves the set after a few attempts, not a thousand.
    const CTransactionRef spent = MakeTx(41);
    BOOST_REQUIRE(wallet.AddToWallet(spent, TxStateInactive{}));
    BOOST_REQUIRE(wallet.QueueResubmitRetry(wallet.mapWallet.at(spent->GetHash())));
    for (unsigned int attempt = 1; attempt <= CWallet::MAX_RESUBMIT_RETRY_MISSING_INPUT_ATTEMPTS; ++attempt) {
        wallet.PruneResubmitRetry();
        BOOST_REQUIRE(wallet.IsInResubmitRetry(spent->GetHash()));
        wallet.NoteResubmitRefusal(spent->GetHash(), uint256{static_cast<uint8_t>(attempt)},
                                   static_cast<int>(attempt), "bad-txns-inputs-missingorspent");
    }
    BOOST_CHECK(wallet.GetResubmitRetryInfo(spent->GetHash())->missing_inputs);
    wallet.PruneResubmitRetry();
    BOOST_CHECK(!wallet.IsInResubmitRetry(spent->GetHash()));
    // The other transaction, refused only for tip-dependent reasons, is still queued.
    BOOST_CHECK(wallet.IsInResubmitRetry(txid));
    BOOST_CHECK_LT(CWallet::MAX_RESUBMIT_RETRY_MISSING_INPUT_ATTEMPTS, CWallet::MAX_RESUBMIT_RETRY_ATTEMPTS);
}

BOOST_AUTO_TEST_SUITE_END()
} // namespace
} // namespace wallet
