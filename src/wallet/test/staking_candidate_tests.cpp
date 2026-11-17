// Copyright (c) 2026 Blackcoin Core Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <chain.h>
#include <key.h>
#include <script/solver.h>
#include <shadow.h>
#include <test/util/random.h>
#include <test/util/setup_common.h>
#include <validation.h>
#include <wallet/coincontrol.h>
#include <wallet/staking.h>
#include <wallet/test/util.h>
#include <wallet/wallet.h>

#include <algorithm>
#include <chrono>
#include <hash.h>
#include <random.h>
#include <wallet/walletdb.h>
#include <set>

#include <boost/test/unit_test.hpp>

namespace wallet {
namespace {

using StakeCoins = std::vector<std::pair<const CWalletTx*, unsigned int>>;

std::set<COutPoint> AsOutpoints(const StakeCoins& coins)
{
    std::set<COutPoint> out;
    for (const auto& [wtx, n] : coins) out.insert(COutPoint{wtx->GetHash(), n});
    return out;
}

struct Fixture {
    std::unique_ptr<CWallet> wallet;
    std::vector<CScript> own_scripts;
    std::vector<COutPoint> spendable_own;
};

/** Add `count` wallet transactions with outputs of every kind the scan must tell apart. */
void Populate(CWallet& wallet, const CKey& key, ChainstateManager& chainman, size_t count)
{
    const CPubKey pubkey = key.GetPubKey();
    const CScript own_pkh = GetScriptForDestination(PKHash(pubkey));
    const CScript own_pk = GetScriptForRawPubKey(pubkey);
    const CScript own_wpkh = GetScriptForDestination(WitnessV0KeyHash(pubkey));
    const CScript quantum = GetScriptForDestination(WitnessUnknown{
        QUANTUM_MIGRATION_WITNESS_VERSION,
        std::vector<unsigned char>(QUANTUM_MIGRATION_PROGRAM_SIZE, 0x53)});

    std::vector<std::pair<uint256, int>> blocks;
    {
        LOCK(::cs_main);
        const CChain& chain = chainman.ActiveChain();
        for (int h = 1; h <= chain.Height(); ++h) blocks.emplace_back(chain[h]->GetBlockHash(), h);
    }

    std::vector<CTransactionRef> spendable;
    for (size_t i = 0; i < count; ++i) {
        CMutableTransaction tx;
        tx.vin.emplace_back(COutPoint{uint256{static_cast<uint8_t>(i % 251 + 1)}, static_cast<uint32_t>(i)});
        const CAmount amount = (i % 17 == 0) ? 1 : (10 + static_cast<CAmount>(i % 5)) * COIN; // dust or normal
        switch (i % 9) {
        case 0: tx.vout.emplace_back(amount, own_pkh); break;
        case 1: tx.vout.emplace_back(amount, own_pk); break;
        case 2: tx.vout.emplace_back(amount, own_wpkh); break;
        case 3: { // foreign key
            CKey other; other.MakeNewKey(true);
            tx.vout.emplace_back(amount, GetScriptForDestination(PKHash(other.GetPubKey())));
            break;
        }
        case 4: tx.vout.emplace_back(amount, CScript{} << OP_TRUE); break; // legacy claim style, not stakable
        case 5: tx.vout.emplace_back(0, CScript{} << OP_RETURN << std::vector<unsigned char>{1, 2, 3}); tx.vout.emplace_back(amount, own_pkh); break;
        case 6: tx.vout.emplace_back(amount, quantum); break;
        case 7: tx.vout.emplace_back(amount, own_pkh); tx.vout.emplace_back(amount, CScript{} << OP_TRUE); break;
        default: tx.vout.emplace_back(amount, own_pkh); break;
        }
        const CTransactionRef ref = MakeTransactionRef(std::move(tx));
        const auto& [hash, height] = blocks[i % blocks.size()];
        TxState state = TxStateConfirmed{hash, height, 0};
        if (i % 23 == 0) state = TxStateInMempool{};        // unconfirmed
        if (i % 29 == 0) state = TxStateInactive{};          // inactive
        BOOST_REQUIRE(wallet.AddToWallet(ref, state));
        spendable.push_back(ref);
        // Spend some of the outputs so the live index and the candidate subset shrink.
        if (i % 7 == 3) {
            CMutableTransaction spend;
            spend.vin.emplace_back(COutPoint{ref->GetHash(), 0});
            spend.vout.emplace_back(COIN, own_pkh);
            BOOST_REQUIRE(wallet.AddToWallet(MakeTransactionRef(std::move(spend)), TxStateInMempool{}));
        }
    }
    // A Gold Rush style synthetic payout record (confirmed, immature-style) and its stale twin.
    for (int j = 0; j < 4; ++j) {
        CMutableTransaction tx;
        tx.vin.emplace_back(COutPoint{uint256{static_cast<uint8_t>(200 + j)}, 0});
        tx.vout.emplace_back(5 * COIN, quantum);
        const auto& [hash, height] = blocks.back();
        BOOST_REQUIRE(wallet.AddToWallet(MakeTransactionRef(std::move(tx)), TxStateConfirmed{hash, height, 0},
            [](CWalletTx& wtx, bool) { wtx.mapValue["qq_synthetic_goldrush_payout"] = "1"; return true; }));
    }
}

BOOST_FIXTURE_TEST_SUITE(staking_candidate_tests, TestChain100Setup)

BOOST_AUTO_TEST_CASE(candidate_scan_selects_the_same_set_as_the_full_scan)
{
    auto wallet = CreateSyncedWallet(*m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), coinbaseKey);
    {
        LOCK(wallet->cs_wallet);
        Populate(*wallet, coinbaseKey, *m_node.chainman, 900);
    }

    LOCK2(::cs_main, wallet->cs_wallet);
    const auto& live = wallet->GetLiveUnspentStakeOutpoints();
    const auto& candidates = wallet->GetLiveUnspentStakeCandidateOutpoints();

    // Index invariant: the candidate subset is exactly the live outpoints with a stakable script.
    std::set<COutPoint> expected;
    for (const COutPoint& outpoint : live) {
        const CWalletTx& wtx = wallet->mapWallet.at(outpoint.hash);
        if (IsStakeCandidateScript(wtx.tx->vout[outpoint.n].scriptPubKey)) expected.insert(outpoint);
    }
    BOOST_CHECK(expected == candidates);
    BOOST_CHECK_LT(candidates.size(), live.size());
    BOOST_CHECK(!candidates.empty());

    CCoinControl watch_control;
    watch_control.fAllowWatchOnly = true;
    CoinFilterParams min_amount_params;
    min_amount_params.min_amount = 11 * COIN;
    CoinFilterParams spendable_off;
    spendable_off.only_spendable = false;
    CoinFilterParams locked_ok;
    locked_ok.skip_locked = false;
    size_t compared{0};
    for (const CCoinControl* control : std::initializer_list<const CCoinControl*>{nullptr, &watch_control}) {
        for (const CoinFilterParams& params : {CoinFilterParams{}, min_amount_params, spendable_off, locked_ok}) {
            StakeCoins fast, reference;
            AvailableCoinsForStaking(*wallet, fast, control, params);
            AvailableCoinsForStakingReference(*wallet, reference, control, params);
            BOOST_CHECK(fast == reference);
            BOOST_CHECK(AsOutpoints(fast) == AsOutpoints(reference));
            compared += fast.size();
        }
    }
    BOOST_CHECK_GT(compared, 0U);

}

BOOST_AUTO_TEST_CASE(candidate_scan_cost_on_a_large_wallet)
{
    auto wallet = CreateSyncedWallet(*m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), coinbaseKey);
    const size_t count = 50000;
    {
        LOCK(wallet->cs_wallet);
        Populate(*wallet, coinbaseKey, *m_node.chainman, count);
    }
    LOCK2(::cs_main, wallet->cs_wallet);
    BOOST_TEST_MESSAGE("live outputs " << wallet->GetLiveUnspentStakeOutpoints().size()
                       << ", stakable-script subset " << wallet->GetLiveUnspentStakeCandidateOutpoints().size());
    StakeCoins fast, reference;
    using clock = std::chrono::steady_clock;
    const auto t0 = clock::now();
    AvailableCoinsForStakingReference(*wallet, reference);
    const auto t1 = clock::now();
    AvailableCoinsForStaking(*wallet, fast);
    const auto t2 = clock::now();
    BOOST_TEST_MESSAGE("per-slot scan, full live index (old): "
        << std::chrono::duration_cast<std::chrono::milliseconds>(t1 - t0).count() << " ms; stakable subset (new): "
        << std::chrono::duration_cast<std::chrono::milliseconds>(t2 - t1).count() << " ms; selected " << fast.size());
    BOOST_CHECK(fast == reference);
}

BOOST_AUTO_TEST_SUITE_END()
} // namespace
} // namespace wallet
