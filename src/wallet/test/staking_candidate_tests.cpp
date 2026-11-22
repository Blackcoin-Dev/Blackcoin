// Copyright (c) 2026 Blackcoin Core Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <chain.h>
#include <chainparams.h>
#include <univalue.h>
#include <common/settings.h>
#include <coins.h>
#include <consensus/validation.h>
#include <key.h>
#include <key_io.h>
#include <pos.h>
#include <script/descriptor.h>
#include <script/solver.h>
#include <shadow.h>
#include <test/util/random.h>
#include <test/util/setup_common.h>
#include <validation.h>
#include <wallet/coincontrol.h>
#include <wallet/spend.h>
#include <wallet/staking.h>
#include <wallet/quantum_return_backup.h>
#include <wallet/test/util.h>
#include <wallet/wallet.h>

#include <algorithm>
#include <chrono>
#include <hash.h>
#include <random.h>
#include <wallet/walletdb.h>
#include <fstream>
#include <set>
#include <thread>

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
        LOCK2(::cs_main, wallet->cs_wallet); // Populate reads the chain
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
        LOCK2(::cs_main, wallet->cs_wallet); // Populate reads the chain
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


using KernelHits = std::vector<std::pair<COutPoint, uint32_t>>;

KernelHits AsPairs(const std::vector<StakeKernelHit>& hits)
{
    KernelHits out;
    for (const StakeKernelHit& hit : hits) out.emplace_back(hit.prevout, hit.time);
    return out;
}

constexpr unsigned int EASY_BITS = 0x207fffff;  // every kernel hash passes
constexpr unsigned int MIDDLE_BITS = 0x2000ffff; // some pass
constexpr unsigned int NEVER_BITS = 0x0300ffff;  // no kernel passes
constexpr unsigned int HARD_BITS = 0x1c00ffff;   // very few pass

/** Run the cached and the uncached search over the same wallet at a few
 * difficulties and times and require identical hits. Returns the number of hits. */
size_t CompareSearches(CWallet& wallet, const std::string& step, bool expect_rebuild)
{
    LOCK2(::cs_main, wallet.cs_wallet);
    CBlockIndex* tip = wallet.chain().getTip();
    BOOST_REQUIRE(tip);
    const StakeSlotCacheStats before = wallet.GetStakeSlotCacheStateLocked().stats;
    size_t hit_count{0};
    for (const unsigned int bits : {EASY_BITS, MIDDLE_BITS, HARD_BITS}) {
        for (const uint32_t time : {tip->nTime + 16, tip->nTime + 32, tip->nTime + 997}) {
            bool uncached_rejected{true}, cached_rejected{true};
            const KernelHits uncached = AsPairs(ScanStakeKernels(wallet, bits, time, 60, /*use_cache=*/false, &uncached_rejected));
            const KernelHits cached = AsPairs(ScanStakeKernels(wallet, bits, time, 60, /*use_cache=*/true, &cached_rejected));
            BOOST_CHECK_MESSAGE(uncached == cached, step << ": cached and uncached kernel search differ at bits " << bits << " time " << time);
            BOOST_CHECK(!uncached_rejected);
            BOOST_CHECK_MESSAGE(!cached_rejected, step << ": the cached search was rejected with no poisoning");
            hit_count += cached.size();
        }
    }
    const StakeSlotCacheStats after = wallet.GetStakeSlotCacheStateLocked().stats;
    BOOST_CHECK_MESSAGE(after.rebuilds - before.rebuilds == (expect_rebuild ? 1U : 0U),
                        step << ": expected " << (expect_rebuild ? 1 : 0) << " rebuild(s), saw " << (after.rebuilds - before.rebuilds));
    BOOST_CHECK_EQUAL(after.rejections, before.rejections);
    if (!expect_rebuild) BOOST_CHECK_GT(after.hits - before.hits, 0U);
    return hit_count;
}

/** The easiest target at which no honest kernel passes but one inflated kernel input does. */
unsigned int PickPoisonBits(const CBlockIndex* tip, uint32_t time, const std::map<COutPoint, CStakeCache>& kernels)
{
    for (unsigned int exponent = 0x20; exponent >= 0x10; --exponent) {
        const unsigned int bits = (exponent << 24) | 0x00ffff;
        bool honest{false}, poisoned{false};
        for (const auto& [outpoint, entry] : kernels) {
            honest |= CheckStakeKernelHash(tip, bits, entry.blockFromTime, entry.amount, outpoint, entry.scriptPubKey, time, false);
            poisoned |= CheckStakeKernelHash(tip, bits, 0, MAX_MONEY / 2, outpoint, entry.scriptPubKey, time, false);
        }
        if (!honest && poisoned) return bits;
    }
    return 0;
}

void Poison(std::map<COutPoint, CStakeCache>& kernels)
{
    for (auto& [outpoint, entry] : kernels) {
        entry.amount = MAX_MONEY / 2;
        entry.blockFromTime = 0;
    }
}

size_t CachedCoinCount(CWallet& wallet)
{
    LOCK(wallet.cs_wallet);
    const auto& state = wallet.GetStakeSlotCacheStateLocked();
    return state.cache ? state.cache->coins.size() : 0;
}

BOOST_AUTO_TEST_CASE(cached_stake_search_equals_the_uncached_search_across_wallet_and_chain_changes)
{
    auto wallet = CreateSyncedWallet(*m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), coinbaseKey);
    const CScript own_pk = GetScriptForRawPubKey(coinbaseKey.GetPubKey());
    size_t total_hits{0};

    // Cold, then warm: nothing changes between the second and the third.
    total_hits += CompareSearches(*wallet, "cold", /*expect_rebuild=*/true);
    const size_t base_coins = CachedCoinCount(*wallet);
    BOOST_REQUIRE_GT(base_coins, 10U);
    total_hits += CompareSearches(*wallet, "warm", /*expect_rebuild=*/false);
    BOOST_CHECK_GT(total_hits, 0U);

    // A block connects.
    CreateAndProcessBlock({}, own_pk);
    total_hits += CompareSearches(*wallet, "block connect", true);
    total_hits += CompareSearches(*wallet, "block connect, warm", false);

    // A new output of the wallet's own, in an existing block.
    CTransactionRef received;
    {
        CMutableTransaction tx;
        tx.vin.emplace_back(COutPoint{uint256{77}, 0});
        tx.vout.emplace_back(25 * COIN, own_pk);
        received = MakeTransactionRef(std::move(tx));
        LOCK2(::cs_main, wallet->cs_wallet);
        const CChain& chain = m_node.chainman->ActiveChain();
        BOOST_REQUIRE(wallet->AddToWallet(received, TxStateConfirmed{chain[5]->GetBlockHash(), 5, 0}));
    }
    total_hits += CompareSearches(*wallet, "new output", true);
    BOOST_CHECK_EQUAL(CachedCoinCount(*wallet), base_coins + 1);

    // Spend one of the coinbase outputs in the wallet's mempool state.
    COutPoint spent_outpoint;
    {
        LOCK2(::cs_main, wallet->cs_wallet);
        spent_outpoint = COutPoint{m_coinbase_txns[0]->GetHash(), 0};
        CMutableTransaction spend;
        spend.vin.emplace_back(spent_outpoint);
        spend.vout.emplace_back(COIN, own_pk);
        BOOST_REQUIRE(wallet->AddToWallet(MakeTransactionRef(std::move(spend)), TxStateInMempool{}));
    }
    total_hits += CompareSearches(*wallet, "spend", true);
    BOOST_CHECK_EQUAL(CachedCoinCount(*wallet), base_coins);

    // Lock and unlock a coin.
    const COutPoint locked{m_coinbase_txns[1]->GetHash(), 0};
    {
        LOCK(wallet->cs_wallet);
        BOOST_REQUIRE(wallet->LockCoin(locked));
    }
    total_hits += CompareSearches(*wallet, "lock coin", true);
    BOOST_CHECK_EQUAL(CachedCoinCount(*wallet), base_coins - 1);
    {
        LOCK(wallet->cs_wallet);
        BOOST_REQUIRE(wallet->UnlockCoin(locked));
    }
    total_hits += CompareSearches(*wallet, "unlock coin", true);
    BOOST_CHECK_EQUAL(CachedCoinCount(*wallet), base_coins);

    // Encrypt, unlock for staking, lock, unlock.
    BOOST_REQUIRE(wallet->EncryptWallet("pass"));
    total_hits += CompareSearches(*wallet, "encrypt", true);
    BOOST_REQUIRE(wallet->Unlock("pass"));
    total_hits += CompareSearches(*wallet, "unlock", true);
    total_hits += CompareSearches(*wallet, "unlock, warm", false);
    BOOST_REQUIRE(wallet->Lock());
    total_hits += CompareSearches(*wallet, "lock", true);
    BOOST_REQUIRE(wallet->Unlock("pass", /*accept_no_keys=*/false, /*staking_only=*/true));
    total_hits += CompareSearches(*wallet, "unlock for staking only", true);

    // A block is disconnected and a different one connects in its place.
    {
        BlockValidationState state;
        CBlockIndex* tip = WITH_LOCK(::cs_main, return m_node.chainman->ActiveChain().Tip());
        BOOST_REQUIRE(m_node.chainman->ActiveChainstate().InvalidateBlock(state, tip));
    }
    total_hits += CompareSearches(*wallet, "block disconnect", true);
    SetMockTime(GetTime() + 600);
    CreateAndProcessBlock({}, own_pk);
    total_hits += CompareSearches(*wallet, "reorg replacement block", true);
    total_hits += CompareSearches(*wallet, "reorg replacement block, warm", false);

    // A cache older than its bound is rebuilt.
    {
        LOCK(wallet->cs_wallet);
        wallet->GetStakeSlotCacheStateLocked().cache->built_at -= STAKE_SLOT_CACHE_MAX_AGE + std::chrono::seconds{1};
    }
    total_hits += CompareSearches(*wallet, "aged cache", true);

    BOOST_CHECK_GT(total_hits, 100U); // the comparison is not vacuous
    BOOST_TEST_MESSAGE("compared " << total_hits << " kernel hits");
}

BOOST_AUTO_TEST_CASE(a_poisoned_cache_cannot_produce_a_stake)
{
    auto wallet = CreateSyncedWallet(*m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), coinbaseKey);
    LOCK2(::cs_main, wallet->cs_wallet);
    CBlockIndex* tip = wallet->chain().getTip();
    const uint32_t time = tip->nTime + 16;

    // Honest baseline: an easy kernel is found.
    BOOST_REQUIRE(!ScanStakeKernels(*wallet, EASY_BITS, time, 1, true).empty());

    // 1. Every kernel input inflated so that the cached hash alone passes at a
    //    target no honest kernel meets.
    StakeSlotCacheState& state = wallet->GetStakeSlotCacheStateLocked();
    BOOST_REQUIRE(state.cache && !state.cache->kernels.empty());
    const unsigned int poison_bits = PickPoisonBits(tip, time, state.cache->kernels);
    BOOST_REQUIRE(poison_bits != 0);
    BOOST_REQUIRE(ScanStakeKernels(*wallet, poison_bits, time, 1, true).empty());
    Poison(state.cache->kernels);
    size_t cache_says_kernel{0};
    for (auto& [outpoint, entry] : state.cache->kernels) {
        if (CheckStakeKernelHash(tip, poison_bits, entry.blockFromTime, entry.amount, outpoint, entry.scriptPubKey, time, false)) ++cache_says_kernel;
    }
    BOOST_CHECK_GT(cache_says_kernel, 0U); // the poison is effective on the cached inputs alone
    bool rejected{false};
    BOOST_CHECK(ScanStakeKernels(*wallet, poison_bits, time, 1, true, &rejected).empty());
    BOOST_CHECK(!rejected); // the uncached confirmation said no, which is the correct answer

    // 2. A coin that is not eligible slipped into the cached selection, with a
    //    kernel entry that passes at the easy target.
    DropStakeSlotCache(*wallet);
    const auto honest = ScanStakeKernels(*wallet, EASY_BITS, time, 1, true);
    CKey other;
    other.MakeNewKey(true);
    CMutableTransaction foreign_tx;
    foreign_tx.vin.emplace_back(COutPoint{uint256{88}, 0});
    foreign_tx.vout.emplace_back(40 * COIN, GetScriptForRawPubKey(other.GetPubKey()));
    const CTransactionRef foreign = MakeTransactionRef(std::move(foreign_tx));
    const CWalletTx* foreign_wtx{nullptr};
    {
        BOOST_REQUIRE(wallet->AddToWallet(foreign, TxStateConfirmed{m_node.chainman->ActiveChain()[4]->GetBlockHash(), 4, 0}));
        foreign_wtx = &wallet->mapWallet.at(foreign->GetHash());
    }
    const COutPoint foreign_outpoint{foreign->GetHash(), 0};
    CCoinsViewCache& view = wallet->chain().getCoinsTip();
    view.AddCoin(foreign_outpoint, Coin(foreign->vout[0], 4, false, false, tip->GetAncestor(4)->nTime), true);
    // Rebuild honestly, then poison.
    BOOST_REQUIRE(ScanStakeKernels(*wallet, EASY_BITS, time, 1, true).size() == honest.size());
    StakeSlotCache& cache = *wallet->GetStakeSlotCacheStateLocked().cache;
    BOOST_REQUIRE(cache.coins.insert({foreign_wtx, 0}).second);
    CacheKernel(cache.kernels, foreign_outpoint, tip, view);
    BOOST_REQUIRE(cache.kernels.count(foreign_outpoint));
    const uint64_t rejections_before = wallet->GetStakeSlotCacheStateLocked().stats.rejections;
    const KernelHits poisoned = AsPairs(ScanStakeKernels(*wallet, EASY_BITS, time, 1, true, &rejected));
    BOOST_CHECK(rejected);
    for (const auto& hit : poisoned) BOOST_CHECK(hit.first != foreign_outpoint);
    BOOST_CHECK_EQUAL(wallet->GetStakeSlotCacheStateLocked().stats.rejections, rejections_before + 1);
    BOOST_CHECK(!wallet->GetStakeSlotCacheStateLocked().cache); // dropped

    // The next slot rebuilds from scratch and no longer carries the foreign coin.
    const KernelHits recovered = AsPairs(ScanStakeKernels(*wallet, EASY_BITS, time, 1, true, &rejected));
    BOOST_CHECK(!rejected);
    BOOST_CHECK(recovered == AsPairs(honest));

    // 3. The same ineligible coin in the cached selection with no kernel entry
    //    at all (every output once demurrage is active, any CacheKernel miss):
    //    the kernel is read from the coins view, and the fresh selection must
    //    still be compared before it is reported.
    StakeSlotCache& entryless = *wallet->GetStakeSlotCacheStateLocked().cache;
    BOOST_REQUIRE(entryless.coins.insert({foreign_wtx, 0}).second);
    BOOST_REQUIRE(entryless.kernels.count(foreign_outpoint) == 0);
    const uint64_t entryless_rejections = wallet->GetStakeSlotCacheStateLocked().stats.rejections;
    const KernelHits entryless_hits = AsPairs(ScanStakeKernels(*wallet, EASY_BITS, time, 1, true, &rejected));
    BOOST_CHECK(rejected);
    for (const auto& hit : entryless_hits) BOOST_CHECK(hit.first != foreign_outpoint);
    BOOST_CHECK_EQUAL(wallet->GetStakeSlotCacheStateLocked().stats.rejections, entryless_rejections + 1);
    BOOST_CHECK(!wallet->GetStakeSlotCacheStateLocked().cache);
}

BOOST_AUTO_TEST_CASE(create_coinstake_with_a_poisoned_cache_makes_no_coinstake)
{
    auto wallet = CreateSyncedWallet(*m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), coinbaseKey);
    const CTxDestination destination = PKHash(coinbaseKey.GetPubKey());
    CBlockIndex* tip = WITH_LOCK(::cs_main, return m_node.chainman->ActiveChain().Tip());
    const uint32_t time = tip->nTime + 16;
    auto make = [&](unsigned int bits, bool& ok) {
        CMutableTransaction coinstake;
        coinstake.nTime = time;
        CAmount fees{0};
        ok = CreateCoinStake(*wallet, bits, 1, coinstake, fees, destination);
        return coinstake;
    };
    bool ok{false};
    const CMutableTransaction honest = make(EASY_BITS, ok);
    BOOST_REQUIRE_MESSAGE(ok, "an honest coinstake is made at the easy target");
    BOOST_CHECK(!honest.vin.empty());

    // Poison the warm cache with kernel inputs that pass at a target no honest kernel meets.
    unsigned int poison_bits{0};
    {
        LOCK(wallet->cs_wallet);
        StakeSlotCache& cache = *wallet->GetStakeSlotCacheStateLocked().cache;
        poison_bits = PickPoisonBits(tip, time, cache.kernels);
        BOOST_REQUIRE(poison_bits != 0);
        Poison(cache.kernels);
    }
    make(poison_bits, ok);
    BOOST_CHECK(!ok);

    // The same with the cache switched off: the same answer.
    g_stake_slot_cache_enabled = false;
    make(poison_bits, ok);
    BOOST_CHECK(!ok);
    const CMutableTransaction uncached = make(EASY_BITS, ok);
    g_stake_slot_cache_enabled = true;
    BOOST_CHECK(ok);
    BOOST_CHECK(uncached.vin == honest.vin);
}

BOOST_AUTO_TEST_CASE(stake_slot_cost_on_a_large_wallet)
{
    auto wallet = CreateSyncedWallet(*m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), coinbaseKey);
    {
        LOCK2(::cs_main, wallet->cs_wallet); // Populate reads the chain
        Populate(*wallet, coinbaseKey, *m_node.chainman, 50000);
    }
    LOCK2(::cs_main, wallet->cs_wallet);
    CBlockIndex* tip = wallet->chain().getTip();
    CCoinsViewCache& view = wallet->chain().getCoinsTip();
    // Give every candidate output a coin in the view so that a slot has real
    // kernel inputs to read, as on a staking node.
    StakeCoins candidates;
    AvailableCoinsForStakingReference(*wallet, candidates);
    for (const auto& [wtx, n] : candidates) {
        const auto* confirmed = wtx->state<TxStateConfirmed>();
        if (!confirmed) continue;
        view.AddCoin(COutPoint{wtx->GetHash(), n},
                     Coin(wtx->tx->vout[n], confirmed->confirmed_block_height, false, false, tip->GetAncestor(confirmed->confirmed_block_height)->nTime), true);
    }
    using clock = std::chrono::steady_clock;
    auto ms = [](clock::duration d) { return std::chrono::duration<double, std::milli>(d).count(); };
    const uint32_t time = tip->nTime + 16;

    auto t0 = clock::now();
    const auto uncached = ScanStakeKernels(*wallet, NEVER_BITS, time, 1, /*use_cache=*/false);
    const double uncached_ms = ms(clock::now() - t0);
    t0 = clock::now();
    const auto cold = ScanStakeKernels(*wallet, NEVER_BITS, time, 1, /*use_cache=*/true);
    const double cold_ms = ms(clock::now() - t0);
    t0 = clock::now();
    const auto warm = ScanStakeKernels(*wallet, NEVER_BITS, time + 16, 1, /*use_cache=*/true);
    const double warm_ms = ms(clock::now() - t0);
    const auto uncached_next = ScanStakeKernels(*wallet, NEVER_BITS, time + 16, 1, /*use_cache=*/false);
    BOOST_CHECK(AsPairs(uncached) == AsPairs(cold));
    BOOST_CHECK(AsPairs(uncached_next) == AsPairs(warm));
    const StakeSlotCacheStats stats = wallet->GetStakeSlotCacheStateLocked().stats;
    BOOST_CHECK_EQUAL(stats.rebuilds, 1U);
    BOOST_CHECK_EQUAL(stats.hits, 1U);
    BOOST_TEST_MESSAGE("candidates " << wallet->GetStakeSlotCacheStateLocked().cache->coins.size()
                       << ", kernel inputs cached " << wallet->GetStakeSlotCacheStateLocked().cache->kernels.size());
    BOOST_TEST_MESSAGE("per-slot cost, uncached (before): " << uncached_ms << " ms; cached cold: " << cold_ms
                       << " ms; cached warm: " << warm_ms << " ms");
}

/** Regtest chain of 100 blocks whose Migration end sits at a chosen height; the
 *  next block (101) is still in Gold Rush, so legacy staking is otherwise open. */
class LegacyStakeScheduleSetup : public TestChain100Setup
{
public:
    explicit LegacyStakeScheduleSetup(const char* migration_end_arg)
        : TestChain100Setup{ChainType::REGTEST, {
              "-shadowwhitelistheight=99",
              "-shadowgoldrushstartheight=100",
              "-shadowgoldrushendheight=102",
              "-qqgoldrushendheight=102",
              migration_end_arg,
          }}
    {
    }
};

class LegacyStakeOpenSetup : public LegacyStakeScheduleSetup
{
public:
    LegacyStakeOpenSetup() : LegacyStakeScheduleSetup{"-qqmigrationendheight=300"} {}
};

class LegacyStakeBarredSetup : public LegacyStakeScheduleSetup
{
public:
    // Last allowed legacy stake height is 105 - 10 - 1 = 94, below the next height 101.
    LegacyStakeBarredSetup() : LegacyStakeScheduleSetup{"-qqmigrationendheight=105"} {}
};

/** The same chain but the next block (101) is in Migration, so quantum outputs are
 *  allowed, and inside the quantum return window (last legacy-return height 94). */
class LegacyStakeWindowSetup : public TestChain100Setup
{
public:
    LegacyStakeWindowSetup()
        : TestChain100Setup{ChainType::REGTEST, {
              "-shadowwhitelistheight=20",
              "-shadowgoldrushstartheight=30",
              "-shadowgoldrushendheight=60",
              "-qqgoldrushendheight=60",
              "-qqmigrationendheight=105",
          }}
    {
    }
};

/** A synced wallet on a real SQLite file, so that a wallet backup (the new key's backup before it becomes the
 *  return address) can be made. The backups go below the fixture's own directory. */
std::unique_ptr<CWallet> CreateSyncedDiskWallet(TestChain100Setup& setup, const CKey& key, const std::string& name)
{
    DatabaseOptions options;
    options.require_create = true;
    options.require_format = DatabaseFormat::SQLITE;
    options.create_flags = WALLET_FLAG_DESCRIPTORS;
    DatabaseStatus status;
    bilingual_str error;
    auto database = MakeWalletDatabase(name, options, status, error);
    BOOST_REQUIRE_MESSAGE(database, error.original);
    CChain& cchain = WITH_LOCK(Assert(setup.m_node.chainman)->GetMutex(), return setup.m_node.chainman->ActiveChain());
    auto wallet = std::make_unique<CWallet>(setup.m_node.chain.get(), name, std::move(database));
    {
        LOCK2(::cs_main, wallet->cs_wallet);
        wallet->SetLastBlockProcessed(cchain.Height(), cchain.Tip()->GetBlockHash());
    }
    BOOST_REQUIRE_EQUAL(wallet->LoadWallet(), DBErrors::LOAD_OK);
    {
        LOCK(wallet->cs_wallet);
        wallet->SetWalletFlag(WALLET_FLAG_DESCRIPTORS);
        wallet->SetupDescriptorScriptPubKeyMans();
        FlatSigningProvider provider;
        std::string desc_error;
        std::unique_ptr<Descriptor> desc = Parse("combo(" + EncodeSecret(key) + ")", provider, desc_error, /*require_checksum=*/false);
        BOOST_REQUIRE(desc);
        WalletDescriptor w_desc(std::move(desc), 0, 0, 1, 1);
        BOOST_REQUIRE(wallet->AddWalletDescriptor(w_desc, provider, "", false));
    }
    WalletRescanReserver reserver(*wallet);
    reserver.reserve();
    CWallet::ScanResult result = wallet->ScanForWalletTransactions(cchain.Genesis()->GetBlockHash(), /*start_height=*/0, /*max_height=*/{}, reserver, /*fUpdate=*/false, /*save_progress=*/false);
    BOOST_REQUIRE(result.status == CWallet::ScanResult::SUCCESS);
    return wallet;
}

/** Restores every command line setting when the test ends. */
class ScopedArgsRestore
{
public:
    ScopedArgsRestore() { gArgs.LockSettings([&](common::Settings& settings) { m_saved = settings; }); }
    ~ScopedArgsRestore() { gArgs.LockSettings([&](common::Settings& settings) { settings = m_saved; }); }

private:
    common::Settings m_saved;
};

/** Points the new-key backups at a directory below the fixture's own, for the length of a test. */
class ScopedQuantumBackupDir
{
public:
    explicit ScopedQuantumBackupDir(const fs::path& dir) { gArgs.ForceSetArg("-quantumkeybackupdir", fs::PathToString(dir)); }
    ~ScopedQuantumBackupDir() { gArgs.ForceSetArg("-quantumkeybackupdir", ""); }
};

StakeCoins LegacyCandidatesAtTip(TestChain100Setup& setup, CWallet& wallet)
{
    LOCK2(::cs_main, wallet.cs_wallet);
    BOOST_REQUIRE(setup.m_node.chainman);
    StakeCoins fast, reference;
    AvailableCoinsForStaking(wallet, fast);
    AvailableCoinsForStakingReference(wallet, reference);
    // The status weight and the kernel search read the same set as the reference scan.
    BOOST_CHECK(fast == reference);
    return fast;
}

BOOST_FIXTURE_TEST_CASE(legacy_kernels_are_candidates_before_the_cutoff, LegacyStakeOpenSetup)
{
    auto wallet = CreateSyncedWallet(*m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), coinbaseKey);
    BOOST_CHECK_EQUAL(m_node.chainman->ActiveChain().Height(), 100);
    BOOST_CHECK(!LegacyCandidatesAtTip(*this, *wallet).empty());
}

BOOST_FIXTURE_TEST_CASE(legacy_kernels_are_not_candidates_past_the_cutoff, LegacyStakeBarredSetup)
{
    auto wallet = CreateSyncedWallet(*m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), coinbaseKey);
    BOOST_CHECK_EQUAL(m_node.chainman->ActiveChain().Height(), 100);
    const Consensus::Params& consensus = Params().GetConsensus();
    BOOST_CHECK(IsLegacyStakeBarredByMigrationEnd(consensus, 101));
    // The same wallet and coins as the open schedule, but none may stake: a
    // legacy coinstake made now could not mature before Final.
    BOOST_CHECK(LegacyCandidatesAtTip(*this, *wallet).empty());
}

BOOST_FIXTURE_TEST_CASE(a_legacy_kernel_in_the_window_without_a_return_address_is_refused, LegacyStakeWindowSetup)
{
    auto wallet = CreateSyncedWallet(*m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), coinbaseKey);
    {
        LOCK(wallet->cs_wallet);
        const LegacyStakeQuantumReturn status = ResolveLegacyStakeQuantumReturn(*wallet);
        BOOST_CHECK(!status.available);
        BOOST_CHECK(status.reason.find("setquantumstakereturn") != std::string::npos);
    }
    BOOST_CHECK(LegacyCandidatesAtTip(*this, *wallet).empty());
    CBlockIndex* tip = WITH_LOCK(::cs_main, return m_node.chainman->ActiveChain().Tip());
    CMutableTransaction coinstake;
    coinstake.nTime = tip->nTime + 16;
    CAmount fees{0};
    BOOST_CHECK(!CreateCoinStake(*wallet, EASY_BITS, 1, coinstake, fees, PKHash(coinbaseKey.GetPubKey())));
}

BOOST_FIXTURE_TEST_CASE(a_legacy_kernel_in_the_window_pays_one_quantum_output, LegacyStakeWindowSetup)
{
    auto wallet = CreateSyncedWallet(*m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), coinbaseKey);
    const auto quantum = wallet->GetNewQuantumDestination("PoS - Quantum Stake Address");
    BOOST_REQUIRE(quantum);
    bilingual_str error;
    BOOST_REQUIRE_MESSAGE(SetQuantumStakeReturn(*wallet, *quantum, error), error.original);
    CScript quantum_script;
    {
        LOCK(wallet->cs_wallet);
        const LegacyStakeQuantumReturn status = ResolveLegacyStakeQuantumReturn(*wallet);
        BOOST_REQUIRE(status.available);
        BOOST_CHECK_EQUAL(status.address, EncodeDestination(*quantum));
        quantum_script = status.script;
    }
    BOOST_CHECK(!LegacyCandidatesAtTip(*this, *wallet).empty());

    CBlockIndex* tip = WITH_LOCK(::cs_main, return m_node.chainman->ActiveChain().Tip());
    CMutableTransaction coinstake;
    coinstake.nTime = tip->nTime + 16;
    CAmount fees{0};
    BOOST_REQUIRE(CreateCoinStake(*wallet, EASY_BITS, 1, coinstake, fees, PKHash(coinbaseKey.GetPubKey())));
    // vout[0] marks the coinstake, vout[1] is the value-0 legacy block-signing key,
    // and exactly one output carries value: the wallet's quantum address.
    BOOST_REQUIRE(coinstake.vout.size() >= 3);
    BOOST_CHECK(coinstake.vout[0].IsEmpty());
    BOOST_CHECK_EQUAL(coinstake.vout[1].nValue, 0);
    std::vector<std::vector<unsigned char>> solutions;
    BOOST_CHECK(Solver(coinstake.vout[1].scriptPubKey, solutions) == TxoutType::PUBKEY);
    size_t valued{0};
    CAmount paid{0};
    for (const CTxOut& out : coinstake.vout) {
        if (out.nValue == 0) continue;
        ++valued;
        paid += out.nValue;
        BOOST_CHECK(out.scriptPubKey == quantum_script);
    }
    BOOST_CHECK_EQUAL(valued, 1U);
    // Principal plus the scheduled reward, never more: coinstake input value is the
    // spent coinbase outputs of the kernel(s).
    CAmount in{0};
    for (const CTxIn& txin : coinstake.vin) {
        const CWalletTx* wtx = WITH_LOCK(wallet->cs_wallet, return wallet->GetWalletTx(txin.prevout.hash));
        BOOST_REQUIRE(wtx);
        in += wtx->tx->vout[txin.prevout.n].nValue;
    }
    BOOST_CHECK_EQUAL(paid - in, GetProofOfStakeSubsidy());
}

BOOST_FIXTURE_TEST_CASE(a_return_address_is_refused_unless_its_key_and_record_are_in_the_database, LegacyStakeWindowSetup)
{
    // A wallet with a database whose writes can be made to fail.
    CWallet wallet(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
    BOOST_REQUIRE_EQUAL(wallet.LoadWallet(), DBErrors::LOAD_OK);
    MockableDatabase& database = GetMockableDatabase(wallet);
    wallet.SetWalletFlag(WALLET_FLAG_DESCRIPTORS);

    // The key write fails: there is no key, so there is nothing to use as the return address.
    database.m_pass = false;
    BOOST_CHECK(!wallet.GetNewQuantumDestination("PoS - Quantum Stake Address"));
    database.m_pass = true;
    BOOST_CHECK(WITH_LOCK(wallet.cs_wallet, return wallet.ListQuantumKeyInfos().empty()));

    // The key is written; the record naming it is then not: the address is not set, and no
    // legacy stake is paid to it.
    const auto quantum = wallet.GetNewQuantumDestination("PoS - Quantum Stake Address");
    BOOST_REQUIRE(quantum);
    bilingual_str error;
    database.m_pass = false;
    BOOST_CHECK(!SetQuantumStakeReturn(wallet, *quantum, error));
    BOOST_CHECK(!error.original.empty());
    database.m_pass = true;
    {
        LOCK(wallet.cs_wallet);
        BOOST_CHECK(wallet.m_quantum_stake_return.empty());
        const LegacyStakeQuantumReturn status = ResolveLegacyStakeQuantumReturn(wallet);
        BOOST_CHECK(!status.available);
        BOOST_CHECK(status.reason.find("setquantumstakereturn") != std::string::npos);
    }

    // With both written the address is ready; the key is durably stored but in no verified backup,
    // and the notice says so.
    BOOST_REQUIRE_MESSAGE(SetQuantumStakeReturn(wallet, *quantum, error), error.original);
    LOCK(wallet.cs_wallet);
    const LegacyStakeQuantumReturn ready = ResolveLegacyStakeQuantumReturn(wallet);
    BOOST_CHECK(ready.available);
    BOOST_CHECK(!ready.backup_verified);
    BOOST_CHECK(wallet.GetQuantumKeyInfo(*quantum)->durably_stored);
    const std::string notice = LegacyStakingNotice(Params().GetConsensus(), 101, ready);
    BOOST_CHECK(notice.find("fresh wallet backup") != std::string::npos);
    BOOST_CHECK(notice.find("cannot recover coins paid to it") != std::string::npos);
}

BOOST_FIXTURE_TEST_CASE(a_saved_return_address_that_is_not_ours_is_not_ready, LegacyStakeWindowSetup)
{
    auto wallet = CreateSyncedWallet(*m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), coinbaseKey);
    // A legacy address and an unknown quantum address are both refused.
    bilingual_str error;
    BOOST_CHECK(!SetQuantumStakeReturn(*wallet, PKHash(coinbaseKey.GetPubKey()), error));
    BOOST_CHECK(!error.original.empty());
    CKey other;
    other.MakeNewKey(true);
    BOOST_CHECK(!SetQuantumStakeReturn(*wallet, PKHash(other.GetPubKey()), error));
    LOCK(wallet->cs_wallet);
    wallet->m_quantum_stake_return = "not an address";
    const LegacyStakeQuantumReturn status = ResolveLegacyStakeQuantumReturn(*wallet);
    BOOST_CHECK(!status.available);
    BOOST_CHECK(status.reason.find("cannot be used") != std::string::npos);
}

BOOST_FIXTURE_TEST_CASE(the_return_address_is_set_automatically_only_when_fully_unlocked, LegacyStakeWindowSetup)
{
    auto wallet = CreateSyncedWallet(*m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), coinbaseKey);
    // No quantum address yet and key creation not allowed: nothing is created or set.
    BOOST_CHECK(!MaybeAutoSetQuantumStakeReturn(*wallet));
    BOOST_CHECK(WITH_LOCK(wallet->cs_wallet, return wallet->m_quantum_stake_return.empty()));
    // An existing quantum address is reused.
    const auto quantum = wallet->GetNewQuantumDestination("receive");
    BOOST_REQUIRE(quantum);
    wallet->m_wallet_unlock_staking_only = true;
    BOOST_CHECK(!MaybeAutoSetQuantumStakeReturn(*wallet)); // staking-only unlock never sets
    wallet->m_wallet_unlock_staking_only = false;
    BOOST_CHECK(MaybeAutoSetQuantumStakeReturn(*wallet));
    BOOST_CHECK_EQUAL(WITH_LOCK(wallet->cs_wallet, return wallet->m_quantum_stake_return), EncodeDestination(*quantum));
    BOOST_CHECK(!MaybeAutoSetQuantumStakeReturn(*wallet)); // already set
}

// The preparation says what it did: nothing, reuse, creation or failure, and whether a key was made.
BOOST_FIXTURE_TEST_CASE(the_return_address_preparation_distinguishes_reuse_creation_no_action_and_failure, LegacyStakeWindowSetup)
{
    using Outcome = QuantumStakeReturnPreparation::Outcome;
    ScopedQuantumBackupDir backups{m_path_root / "qkb"};
    auto wallet = CreateSyncedDiskWallet(*this, coinbaseKey, "prepare-outcomes");
    // No quantum address and key creation not allowed: no action, no key, and it says why.
    QuantumStakeReturnPreparation prep = PrepareQuantumStakeReturn(*wallet, QuantumStakeReturnTrigger::AUTOMATIC);
    BOOST_CHECK(prep.outcome == Outcome::NO_ACTION);
    BOOST_CHECK(!prep.key_created);
    BOOST_CHECK(!prep.Saved());
    BOOST_CHECK(!prep.detail.empty());

    // Key creation allowed: a key is created, backed up, saved, and reported as created.
    gArgs.ForceSetArg("-qqallowautokeycreation", "1");
    prep = PrepareQuantumStakeReturn(*wallet, QuantumStakeReturnTrigger::AUTOMATIC);
    gArgs.ForceSetArg("-qqallowautokeycreation", "0");
    BOOST_CHECK(prep.outcome == Outcome::CREATED_ADDRESS);
    BOOST_CHECK(prep.key_created);
    BOOST_CHECK(prep.Saved());
    BOOST_CHECK_EQUAL(WITH_LOCK(wallet->cs_wallet, return wallet->m_quantum_stake_return), prep.address);
    BOOST_CHECK(!WITH_LOCK(wallet->cs_wallet, return wallet->m_quantum_return_pending.has_value()));
    BOOST_CHECK(WITH_LOCK(wallet->cs_wallet, return ResolveLegacyStakeQuantumReturn(*wallet).backup_verified));

    // Set already: no action, the saved address is reported, nothing created.
    const std::string saved = prep.address;
    prep = PrepareQuantumStakeReturn(*wallet, QuantumStakeReturnTrigger::AUTOMATIC);
    BOOST_CHECK(prep.outcome == Outcome::NO_ACTION);
    BOOST_CHECK(!prep.key_created);
    BOOST_CHECK_EQUAL(prep.address, saved);

    // A second wallet with an existing quantum address reuses it: reused, nothing created.
    auto other = CreateSyncedWallet(*m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), coinbaseKey);
    const auto quantum = other->GetNewQuantumDestination("receive");
    BOOST_REQUIRE(quantum);
    prep = PrepareQuantumStakeReturn(*other, QuantumStakeReturnTrigger::AUTOMATIC);
    BOOST_CHECK(prep.outcome == Outcome::REUSED_ADDRESS);
    BOOST_CHECK(!prep.key_created);
    BOOST_CHECK_EQUAL(prep.address, EncodeDestination(*quantum));

    // A staking-only unlock: no action.
    auto limited = CreateSyncedWallet(*m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), coinbaseKey);
    limited->m_wallet_unlock_staking_only = true;
    BOOST_CHECK(PrepareQuantumStakeReturn(*limited, QuantumStakeReturnTrigger::AUTOMATIC).outcome == Outcome::NO_ACTION);
}

// The automatic preparation waits for the end of Gold Rush and for legacy coins to return; the explicit command does
// not. A pre-end chain, or a wallet with nothing to stake, sees no key, record or backup prompt appear by itself.
BOOST_FIXTURE_TEST_CASE(the_automatic_return_address_waits_for_the_end_of_gold_rush_and_for_legacy_coins, LegacyStakeOpenSetup)
{
    using Outcome = QuantumStakeReturnPreparation::Outcome;
    // Tip 100: the next block (101) is still in Gold Rush (it ends at 102); the Migration end is far away.
    ScopedQuantumBackupDir backups{m_path_root / "qkb"};
    auto wallet = CreateSyncedDiskWallet(*this, coinbaseKey, "prepare-waits");
    BOOST_REQUIRE(wallet);
    gArgs.ForceSetArg("-qqallowautokeycreation", "1");
    const QuantumStakeReturnPreparation automatic = PrepareQuantumStakeReturn(*wallet, QuantumStakeReturnTrigger::AUTOMATIC);
    BOOST_CHECK(automatic.outcome == Outcome::NO_ACTION);
    BOOST_CHECK(!automatic.key_created);
    BOOST_CHECK(WITH_LOCK(wallet->cs_wallet, return wallet->m_quantum_stake_return.empty()));
    BOOST_CHECK_EQUAL(WITH_LOCK(wallet->cs_wallet, return wallet->ListQuantumKeyInfos().size()), size_t{0});
    // The same wallet, asked explicitly, creates the key and saves the address.
    const QuantumStakeReturnPreparation explicit_request = PrepareQuantumStakeReturn(*wallet, QuantumStakeReturnTrigger::EXPLICIT);
    gArgs.ForceSetArg("-qqallowautokeycreation", "0");
    BOOST_CHECK(explicit_request.outcome == Outcome::CREATED_ADDRESS);
    BOOST_CHECK(explicit_request.key_created);
    BOOST_CHECK_EQUAL(WITH_LOCK(wallet->cs_wallet, return wallet->ListQuantumKeyInfos().size()), size_t{1});
}

BOOST_FIXTURE_TEST_CASE(the_automatic_return_address_needs_a_legacy_coin_to_return, LegacyStakeWindowSetup)
{
    using Outcome = QuantumStakeReturnPreparation::Outcome;
    // Tip 100 is past the Gold Rush end (60) and inside the Migration window: the phase allows it.
    CKey nobody;
    nobody.MakeNewKey(/*fCompressed=*/true);
    auto empty = CreateSyncedWallet(*m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), nobody);
    BOOST_REQUIRE(empty);
    BOOST_REQUIRE(WITH_LOCK(empty->cs_wallet, return empty->GetLiveUnspentStakeCandidateOutpoints().empty()));
    gArgs.ForceSetArg("-qqallowautokeycreation", "1");
    QuantumStakeReturnPreparation prep = PrepareQuantumStakeReturn(*empty, QuantumStakeReturnTrigger::AUTOMATIC);
    BOOST_CHECK(prep.outcome == Outcome::NO_ACTION);
    BOOST_CHECK(!prep.key_created);
    BOOST_CHECK(WITH_LOCK(empty->cs_wallet, return empty->m_quantum_stake_return.empty()));
    BOOST_CHECK_EQUAL(WITH_LOCK(empty->cs_wallet, return empty->ListQuantumKeyInfos().size()), size_t{0});
    // A wallet that does hold legacy stakable coins gets its key.
    ScopedQuantumBackupDir backups{m_path_root / "qkb"};
    auto holder = CreateSyncedDiskWallet(*this, coinbaseKey, "prepare-holder");
    prep = PrepareQuantumStakeReturn(*holder, QuantumStakeReturnTrigger::AUTOMATIC);
    gArgs.ForceSetArg("-qqallowautokeycreation", "0");
    BOOST_CHECK(prep.outcome == Outcome::CREATED_ADDRESS);
    BOOST_CHECK(prep.key_created);
}

BOOST_FIXTURE_TEST_CASE(a_coinbase_exactly_maturity_deep_is_a_candidate_for_the_next_block, LegacyStakeOpenSetup)
{
    auto wallet = CreateSyncedWallet(*m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), coinbaseKey);
    BOOST_CHECK_EQUAL(m_node.chainman->ActiveChain().Height(), 100);
    const int maturity = Params().GetConsensus().nCoinbaseMaturity;
    const int next_height = 101;

    // Consensus accepts a kernel when next_height - output height >= maturity, so the coinbase
    // of height 101 - maturity (exactly `maturity` deep at tip 100) is a candidate and the
    // one above it is not. The wallet's generic immaturity (one block more) still applies to
    // balances.
    const auto heights_of = [&](const StakeCoins& coins) {
        std::set<int> heights;
        LOCK(wallet->cs_wallet);
        for (const auto& [wtx, n] : coins) {
            const TxStateConfirmed* confirmed = wtx->state<TxStateConfirmed>();
            BOOST_REQUIRE(confirmed);
            heights.insert(confirmed->confirmed_block_height);
        }
        return heights;
    };
    const std::set<int> heights = heights_of(LegacyCandidatesAtTip(*this, *wallet)); // also fast == reference
    BOOST_REQUIRE(!heights.empty());
    BOOST_CHECK_EQUAL(*heights.rbegin(), next_height - maturity);
    BOOST_CHECK(!heights.count(next_height - maturity + 1));

    {
        LOCK(wallet->cs_wallet);
        for (const auto& [hash, wtx] : wallet->mapWallet) {
            const TxStateConfirmed* confirmed = wtx.state<TxStateConfirmed>();
            BOOST_REQUIRE(confirmed);
            const bool consensus_mature = next_height - confirmed->confirmed_block_height >= maturity;
            BOOST_CHECK_EQUAL(IsStakeSourceImmatureForNextBlock(*wallet, wtx, next_height), !consensus_mature);
            // The wallet's own generic formula is one block stricter at exactly the boundary.
            if (next_height - confirmed->confirmed_block_height == maturity) BOOST_CHECK(wallet->IsTxImmature(wtx));
        }
    }

    // The readiness scan: one block ahead the next coinbase qualifies; before it, the reason is IMMATURE.
    std::map<int, StakeExclusion> reasons;
    std::set<int> eligible_ahead;
    {
        LOCK2(::cs_main, wallet->cs_wallet);
        StakeCoins coins;
        CCoinControl coin_control;
        const StakeScanObserver observer = [&](const COutPoint& outpoint, const CWalletTx& wtx, bool eligible, StakeExclusion why) {
            const int height = wtx.state<TxStateConfirmed>()->confirmed_block_height;
            if (eligible) eligible_ahead.insert(height); else reasons[height] = why;
        };
        AvailableCoinsForStakingAhead(*wallet, coins, &coin_control, CoinFilterParams{}, /*blocks_ahead=*/1, observer);
        BOOST_CHECK_EQUAL(coins.size(), eligible_ahead.size());
    }
    BOOST_CHECK_EQUAL(*eligible_ahead.rbegin(), next_height + 1 - maturity);
    BOOST_CHECK(reasons.at(next_height + 2 - maturity) == StakeExclusion::IMMATURE);
    // And with no look-ahead the staker itself selects exactly the first set.
    BOOST_CHECK(heights_of(LegacyCandidatesAtTip(*this, *wallet)) == heights);

    // The staker's complete selection (SelectCoinsForStaking, which the slot cache and the weight status
    // are built from) holds the boundary coinbase too, and the weight it publishes is exactly its value
    // (no reserve here), tagged with the tip it was scanned at.
    {
        LOCK2(::cs_main, wallet->cs_wallet);
        CAmount target{MAX_MONEY};
        CAmount value_in{0};
        std::set<std::pair<const CWalletTx*, unsigned int>> selection;
        BOOST_REQUIRE(SelectCoinsForStaking(*wallet, target, selection, value_in));
        StakeCoins coins;
        AvailableCoinsForStaking(*wallet, coins);
        CAmount expected{0};
        for (const auto& [wtx, n] : coins) expected += wtx->tx->vout[n].nValue;
        BOOST_CHECK_GT(expected, 0);
        BOOST_CHECK_EQUAL(selection.size(), coins.size());
        BOOST_CHECK_EQUAL(value_in, expected);
        BOOST_CHECK(heights_of(coins) == heights);
        BOOST_CHECK_EQUAL(wallet->m_cached_stake_weight.load(), static_cast<uint64_t>(value_in));
        BOOST_CHECK_EQUAL(wallet->m_cached_stake_weight_height.load(), 100);
    }
}

// The claim miner's stake reserve is built from GetBoundedLegacyStakeCandidates and decides which legacy coins stay out
// of claim fee-input selection. That selection must stay exactly what v30.1.6 did before Gold Rush ends, so the
// reserve list keeps the wallet's own maturity rule (a coinbase is mature one block after consensus would accept it
// as a kernel) while the staker itself uses the kernel rule. The one coin that differs is the coinbase exactly
// `maturity` deep: the staker may stake it, the claim selector cannot spend it (the wallet calls it immature), so
// it cannot be contended for, and the reserve must not give it a protected slot that frees another coin for claims.
BOOST_FIXTURE_TEST_CASE(the_claim_reserve_keeps_the_wallet_maturity_rule_while_the_staker_uses_the_kernel_rule, LegacyStakeOpenSetup)
{
    auto wallet = CreateSyncedWallet(*m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), coinbaseKey);
    BOOST_CHECK_EQUAL(m_node.chainman->ActiveChain().Height(), 100);
    const int maturity = Params().GetConsensus().nCoinbaseMaturity;
    const int boundary_height = 101 - maturity; // exactly `maturity` deep at tip 100: a kernel for block 101
    const int64_t mtp = WITH_LOCK(::cs_main, return m_node.chainman->ActiveChain().Tip()->GetMedianTimePast());

    const auto height_of = [&](const COutPoint& outpoint) EXCLUSIVE_LOCKS_REQUIRED(wallet->cs_wallet) {
        const auto it = wallet->mapWallet.find(outpoint.hash);
        BOOST_REQUIRE(it != wallet->mapWallet.end());
        const TxStateConfirmed* confirmed = it->second.state<TxStateConfirmed>();
        BOOST_REQUIRE(confirmed);
        return confirmed->confirmed_block_height;
    };

    std::set<int> staker_heights;
    {
        const StakeCoins coins = LegacyCandidatesAtTip(*this, *wallet);
        LOCK(wallet->cs_wallet);
        for (const auto& [wtx, n] : coins) staker_heights.insert(height_of(COutPoint{wtx->GetHash(), n}));
    }
    BOOST_CHECK(staker_heights.count(boundary_height) == 1); // the staker stakes it

    std::set<int> reserve_heights;
    {
        LOCK(wallet->cs_wallet);
        std::vector<BoundedLegacyStakeSource> sources;
        for (const auto& [txid, wtx] : wallet->mapWallet) {
            for (unsigned int n = 0; n < wtx.tx->vout.size(); ++n) {
                if (!wallet->IsSpent(COutPoint{txid, n})) sources.push_back({COutPoint{txid, n}, &wtx});
            }
        }
        const BoundedLegacyStakeCandidates reserve = GetBoundedLegacyStakeCandidates(*wallet, sources, {}, 100, mtp);
        BOOST_CHECK(!reserve.capacity_exceeded);
        for (const BoundedLegacyStakeCandidate& candidate : reserve.candidates) {
            reserve_heights.insert(height_of(candidate.outpoint));
        }
    }
    // The reserve sees the staker's set less the exact-maturity coinbase: the coinbase one block older is in both.
    std::set<int> expected = staker_heights;
    expected.erase(boundary_height);
    BOOST_CHECK(reserve_heights == expected);
    BOOST_CHECK(reserve_heights.count(boundary_height - 1) == 1);
    BOOST_CHECK(reserve_heights.count(boundary_height) == 0);
}

namespace {
/** A watch-only wallet: it knows the public key (a combo descriptor without the private key) and has
 *  private keys disabled, the way the wallet itself represents watch-only. */
std::unique_ptr<CWallet> CreateWatchOnlyKeyWallet(interfaces::Chain& chain, CChain& cchain, const CPubKey& pubkey)
{
    auto wallet = std::make_unique<CWallet>(&chain, "", CreateMockableWalletDatabase());
    {
        LOCK2(::cs_main, wallet->cs_wallet);
        wallet->SetLastBlockProcessed(cchain.Height(), cchain.Tip()->GetBlockHash());
    }
    wallet->LoadWallet();
    LOCK(wallet->cs_wallet);
    wallet->SetWalletFlag(WALLET_FLAG_DESCRIPTORS);
    wallet->SetupDescriptorScriptPubKeyMans();
    FlatSigningProvider provider;
    std::string error;
    std::unique_ptr<Descriptor> desc = Parse("combo(" + HexStr(pubkey) + ")", provider, error, /*require_checksum=*/false);
    assert(desc);
    WalletDescriptor w_desc(std::move(desc), 0, 0, 1, 1);
    if (!wallet->AddWalletDescriptor(w_desc, provider, "", false)) assert(false);
    wallet->SetWalletFlag(WALLET_FLAG_DISABLE_PRIVATE_KEYS);
    return wallet;
}

CTransactionRef PayTo(const CScript& script, CAmount amount, uint8_t seed)
{
    CMutableTransaction tx;
    tx.vin.emplace_back(COutPoint{uint256{seed}, 0});
    tx.vout.emplace_back(amount, script);
    return MakeTransactionRef(std::move(tx));
}
} // namespace

BOOST_FIXTURE_TEST_CASE(automatic_return_gate_needs_an_owned_signable_legacy_coin, LegacyStakeWindowSetup)
{
    CKey own_key;
    own_key.MakeNewKey(true);
    CKey stranger;
    stranger.MakeNewKey(true);
    const CScript own_pkh = GetScriptForDestination(PKHash(own_key.GetPubKey()));
    const CScript own_pk = GetScriptForRawPubKey(own_key.GetPubKey());
    const CScript foreign_pkh = GetScriptForDestination(PKHash(stranger.GetPubKey()));
    const CScript foreign_pk = GetScriptForRawPubKey(stranger.GetPubKey());
    const CScript foreign_wpkh = GetScriptForDestination(WitnessV0KeyHash(stranger.GetPubKey()));
    const uint256 block_hash = WITH_LOCK(::cs_main, return m_node.chainman->ActiveChain()[1]->GetBlockHash());
    const TxState confirmed = TxStateConfirmed{block_hash, 1, 0};
    const CAmount amount = 100 * COIN;

    auto wallet = CreateSyncedWallet(*m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), own_key);

    // Foreign legacy outputs sit in the wallet's transaction history (an outgoing payment's recipient
    // output, for one) and in its candidate index, but the wallet owns no legacy coin: no gate opens.
    {
        LOCK2(::cs_main, wallet->cs_wallet);
        BOOST_REQUIRE(wallet->AddToWallet(PayTo(foreign_pkh, amount, 1), confirmed));
        BOOST_REQUIRE(wallet->AddToWallet(PayTo(foreign_pk, amount, 2), confirmed));
        BOOST_REQUIRE(wallet->AddToWallet(PayTo(foreign_wpkh, amount, 3), confirmed));
        // The candidate index holds them: the shape alone would have opened the gate.
        BOOST_CHECK(!wallet->GetLiveUnspentStakeCandidateOutpoints().empty());
        BOOST_CHECK(!WalletHoldsLegacyStakableCoin(*wallet));
    }
    {
        // The automatic preparation, with key creation allowed, in the Migration window: no key, no
        // saved record, no prompt for a wallet that holds only other people's legacy outputs.
        using Outcome = QuantumStakeReturnPreparation::Outcome;
        gArgs.ForceSetArg("-qqallowautokeycreation", "1");
        const QuantumStakeReturnPreparation prep = PrepareQuantumStakeReturn(*wallet, QuantumStakeReturnTrigger::AUTOMATIC);
        gArgs.ForceSetArg("-qqallowautokeycreation", "0");
        BOOST_CHECK(prep.outcome == Outcome::NO_ACTION);
        BOOST_CHECK(!prep.key_created);
        BOOST_CHECK(WITH_LOCK(wallet->cs_wallet, return wallet->m_quantum_stake_return.empty()));
        BOOST_CHECK_EQUAL(WITH_LOCK(wallet->cs_wallet, return wallet->ListQuantumKeyInfos().size()), size_t{0});
    }

    // An owned output below the staking minimum does not count either.
    {
        LOCK2(::cs_main, wallet->cs_wallet);
        BOOST_REQUIRE(wallet->AddToWallet(PayTo(own_pkh, 1, 4), confirmed));
        BOOST_CHECK(!WalletHoldsLegacyStakableCoin(*wallet));
    }

    // An owned, signable legacy output of a stakable class opens it.
    {
        LOCK2(::cs_main, wallet->cs_wallet);
        BOOST_REQUIRE(wallet->AddToWallet(PayTo(own_pkh, amount, 5), confirmed));
        BOOST_CHECK(WalletHoldsLegacyStakableCoin(*wallet));
    }
    auto pk_wallet = CreateSyncedWallet(*m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), own_key);
    {
        LOCK2(::cs_main, pk_wallet->cs_wallet);
        BOOST_REQUIRE(pk_wallet->AddToWallet(PayTo(foreign_pkh, amount, 6), confirmed));
        BOOST_CHECK(!WalletHoldsLegacyStakableCoin(*pk_wallet));
        BOOST_REQUIRE(pk_wallet->AddToWallet(PayTo(own_pk, amount, 7), confirmed));
        BOOST_CHECK(WalletHoldsLegacyStakableCoin(*pk_wallet));
    }

    // Watch-only: the wallet knows the public key of the output's script but holds no private key for it.
    auto watch = CreateWatchOnlyKeyWallet(*m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), own_key.GetPubKey());
    {
        LOCK2(::cs_main, watch->cs_wallet);
        BOOST_REQUIRE(watch->AddToWallet(PayTo(own_pkh, amount, 8), confirmed));
        BOOST_CHECK(!watch->GetLiveUnspentStakeCandidateOutpoints().empty());
        BOOST_CHECK(!WalletHoldsLegacyStakableCoin(*watch));
    }

    // A protected asset: an owned legacy output of a stakable class, above the minimum and signable, that
    // carries a live RGB assignment. Spending it as ordinary coin would burn the asset, so the automatic
    // preparation must not treat it as a legacy stake; once the protection is gone, the same output qualifies.
    {
        auto holder = CreateSyncedWallet(*m_node.chain,
            WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), own_key);
        const CTransactionRef protected_tx = PayTo(own_pkh, amount, 9);
        const COutPoint protected_out{protected_tx->GetHash(), 0};
        const uint256 contract_id = uint256S("c0");
        RGBContractRecord contract;
        contract.ticker = "TST";
        contract.name = "Protected test asset";
        contract.total_supply = 1000;
        contract.creation_time = 1;
        BOOST_REQUIRE(holder->AddRGBContract(contract_id, contract));
        RGBOwnedAssignmentRecord assignment;
        assignment.amount = 1000;
        assignment.creation_time = 1;
        BOOST_REQUIRE(holder->AddRGBAssignment(contract_id, protected_out, assignment));
        {
            LOCK2(::cs_main, holder->cs_wallet);
            BOOST_REQUIRE(holder->AddToWallet(protected_tx, confirmed));
            BOOST_CHECK(holder->GetProtectedRGBSeals().count(protected_out) == 1);
            // Otherwise qualifying: it is in the candidate index and nothing but the protection excludes it.
            BOOST_CHECK(!holder->GetLiveUnspentStakeCandidateOutpoints().empty());
            BOOST_CHECK(!WalletHoldsLegacyStakableCoin(*holder));
        }
        using Outcome = QuantumStakeReturnPreparation::Outcome;
        gArgs.ForceSetArg("-qqallowautokeycreation", "1");
        const QuantumStakeReturnPreparation protected_prep = PrepareQuantumStakeReturn(*holder, QuantumStakeReturnTrigger::AUTOMATIC);
        BOOST_CHECK(protected_prep.outcome == Outcome::NO_ACTION);
        BOOST_CHECK(!protected_prep.key_created);
        BOOST_CHECK(WITH_LOCK(holder->cs_wallet, return holder->m_quantum_stake_return.empty()));
        BOOST_CHECK_EQUAL(WITH_LOCK(holder->cs_wallet, return holder->ListQuantumKeyInfos().size()), size_t{0});

        // The protection removed (the assignment is spent): the same output qualifies, and the same call acts.
        bool changed{false};
        BOOST_REQUIRE(holder->SetRGBAssignmentSpent(contract_id, protected_out, /*spent=*/true, changed));
        BOOST_CHECK(changed);
        {
            LOCK2(::cs_main, holder->cs_wallet);
            BOOST_CHECK(holder->GetProtectedRGBSeals().empty());
            BOOST_CHECK(WalletHoldsLegacyStakableCoin(*holder));
        }
        const QuantumStakeReturnPreparation open_prep = PrepareQuantumStakeReturn(*holder, QuantumStakeReturnTrigger::AUTOMATIC);
        gArgs.ForceSetArg("-qqallowautokeycreation", "0");
        BOOST_CHECK(open_prep.outcome != Outcome::NO_ACTION);
    }
}

// The order in which a return destination is taken, rank by rank (pure).
BOOST_FIXTURE_TEST_CASE(the_return_destination_is_chosen_saved_then_configured_then_claim_key_then_ranked, LegacyStakeWindowSetup)
{
    auto wallet = CreateSyncedWallet(*m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), coinbaseKey);
    std::vector<CTxDestination> dests;
    for (int i = 0; i < 4; ++i) {
        const auto dest = wallet->GetNewQuantumDestination("k" + ToString(i));
        BOOST_REQUIRE(dest);
        dests.push_back(*dest);
    }
    const CTxDestination none;
    const std::vector<QuantumReturnCandidate> candidates{
        {dests[3], "", false, 100}, {dests[2], "PoS - Quantum Stake Address", false, 300}};
    using Source = QuantumReturnSource;
    auto choice = ChooseQuantumStakeReturn(dests[0], dests[1], dests[2], candidates);
    BOOST_CHECK(choice.source == Source::SAVED && choice.destination == dests[0]);
    choice = ChooseQuantumStakeReturn(none, dests[1], dests[2], candidates);
    BOOST_CHECK(choice.source == Source::CONFIGURED && choice.destination == dests[1]);
    choice = ChooseQuantumStakeReturn(none, none, dests[0], candidates);
    BOOST_CHECK(choice.source == Source::CLAIM_KEY && choice.destination == dests[0]);
    // the ranking: the PoS label beats an older key with no label
    choice = ChooseQuantumStakeReturn(none, none, none, candidates);
    BOOST_CHECK(choice.source == Source::RANKED && choice.destination == dests[2]);
    // equal rank: the older key, then the smaller address
    choice = ChooseQuantumStakeReturn(none, none, none, {{dests[3], "", false, 200}, {dests[1], "", false, 100}});
    BOOST_CHECK(choice.source == Source::RANKED && choice.destination == dests[1]);
    const bool first_is_smaller = EncodeDestination(dests[0]) < EncodeDestination(dests[3]);
    choice = ChooseQuantumStakeReturn(none, none, none, {{dests[3], "", false, 100}, {dests[0], "", false, 100}});
    BOOST_CHECK(choice.destination == (first_is_smaller ? dests[0] : dests[3]));
    // nothing usable: the caller needs a new key
    choice = ChooseQuantumStakeReturn(none, none, none, {});
    BOOST_CHECK(choice.source == Source::NONE);
}

BOOST_FIXTURE_TEST_CASE(the_wallet_takes_the_configured_key_then_its_recorded_claim_key_before_other_quantum_addresses, LegacyStakeWindowSetup)
{
    const auto fresh = [&] {
        return CreateSyncedWallet(*m_node.chain,
            WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), coinbaseKey);
    };
    // A claim-labelled key that nothing records is just another key: the label ranking and age decide.
    {
        auto wallet = fresh();
        const auto older = wallet->GetNewQuantumDestination("some older key");
        const auto labelled = wallet->GetNewQuantumDestination("PoW - Quantum Claim Address");
        BOOST_REQUIRE(older && labelled);
        BOOST_CHECK(WITH_LOCK(wallet->cs_wallet, return !IsValidDestination(wallet->GetRecordedPowPayoutKey())));
        const QuantumStakeReturnPreparation prep = PrepareQuantumStakeReturn(*wallet, QuantumStakeReturnTrigger::EXPLICIT);
        BOOST_CHECK(prep.outcome == QuantumStakeReturnPreparation::Outcome::REUSED_ADDRESS);
        BOOST_CHECK_MESSAGE(prep.address == EncodeDestination(*older) || prep.address == EncodeDestination(*labelled), prep.address);
    }
    // The key the claim miner is bound to is taken before a PoS-labelled key and an older key.
    {
        auto wallet = fresh();
        const auto older = wallet->GetNewQuantumDestination("some older key");
        const auto pos = wallet->GetNewQuantumDestination("PoS - Quantum Stake Address");
        const auto claim = wallet->GetNewQuantumDestination("PoW - Quantum Claim Address");
        BOOST_REQUIRE(older && pos && claim);
        WITH_LOCK(wallet->cs_wallet, wallet->m_pow_payout_quantum = EncodeDestination(*claim));
        BOOST_CHECK(WITH_LOCK(wallet->cs_wallet, return wallet->GetRecordedPowPayoutKey()) == *claim);
        const QuantumStakeReturnPreparation prep = PrepareQuantumStakeReturn(*wallet, QuantumStakeReturnTrigger::EXPLICIT);
        BOOST_CHECK(prep.outcome == QuantumStakeReturnPreparation::Outcome::REUSED_ADDRESS);
        BOOST_CHECK(!prep.key_created);
        BOOST_CHECK_EQUAL(prep.address, EncodeDestination(*claim));
        BOOST_CHECK_EQUAL(WITH_LOCK(wallet->cs_wallet, return wallet->ListQuantumKeyInfos().size()), size_t{3});
    }
    // The configured claim payout key counts too, and exactly one configured PoS payout key comes first of all.
    {
        ScopedArgsRestore restore_args;
        auto wallet = fresh();
        const auto older = wallet->GetNewQuantumDestination("some older key");
        const auto claim = wallet->GetNewQuantumDestination("PoW - Quantum Claim Address");
        BOOST_REQUIRE(older && claim);
        gArgs.ForceSetArg("-qqpowpayoutaddress", EncodeDestination(*claim));
        BOOST_CHECK(WITH_LOCK(wallet->cs_wallet, return wallet->GetRecordedPowPayoutKey()) == *claim);
        gArgs.ForceSetArg("-qqpospayoutaddress", EncodeDestination(*older));
        const QuantumStakeReturnPreparation prep = PrepareQuantumStakeReturn(*wallet, QuantumStakeReturnTrigger::EXPLICIT);
        BOOST_CHECK_EQUAL(prep.address, EncodeDestination(*older));
    }
    // A recorded claim key that is not a key of this wallet is not used.
    {
        auto wallet = fresh();
        const auto other_wallet_key = fresh()->GetNewQuantumDestination("elsewhere");
        BOOST_REQUIRE(other_wallet_key);
        WITH_LOCK(wallet->cs_wallet, wallet->m_pow_payout_quantum = EncodeDestination(*other_wallet_key));
        BOOST_CHECK(WITH_LOCK(wallet->cs_wallet, return !IsValidDestination(wallet->GetRecordedPowPayoutKey())));
    }
}

BOOST_FIXTURE_TEST_CASE(a_staking_only_unlock_binds_an_existing_key_but_never_chooses_or_creates_one, LegacyStakeWindowSetup)
{
    using Outcome = QuantumStakeReturnPreparation::Outcome;
    ScopedQuantumBackupDir backups{m_path_root / "qkb"};
    auto wallet = CreateSyncedDiskWallet(*this, coinbaseKey, "staking-only");
    const auto existing = wallet->GetNewQuantumDestination("receive");
    BOOST_REQUIRE(existing);
    wallet->m_wallet_unlock_staking_only = true;
    for (const auto trigger : {QuantumStakeReturnTrigger::AUTOMATIC, QuantumStakeReturnTrigger::EXPLICIT}) {
        for (const bool allow_new : {false, true}) {
            const QuantumStakeReturnPreparation prep = PrepareQuantumStakeReturn(*wallet, trigger, allow_new);
            BOOST_CHECK(prep.outcome == Outcome::NO_ACTION);
            BOOST_CHECK(!prep.key_created);
        }
    }
    BOOST_CHECK(WITH_LOCK(wallet->cs_wallet, return wallet->m_quantum_stake_return.empty()));
    BOOST_CHECK(!WITH_LOCK(wallet->cs_wallet, return wallet->m_quantum_return_pending.has_value()));
    BOOST_CHECK_EQUAL(WITH_LOCK(wallet->cs_wallet, return wallet->ListQuantumKeyInfos().size()), size_t{1});
    // the explicit binding of a key the wallet already has is allowed
    bilingual_str error;
    BOOST_CHECK_MESSAGE(SetQuantumStakeReturn(*wallet, *existing, error), error.original);
    BOOST_CHECK_EQUAL(WITH_LOCK(wallet->cs_wallet, return wallet->m_quantum_stake_return), EncodeDestination(*existing));
    // and the key creation itself refuses
    BOOST_CHECK(!wallet->AddQuantumStakeReturnKey("PoS - Quantum Stake Address", "explicit"));
}

// A new key whose backup fails stays pending, is not usable as the return address in any way, and is retried as the
// same key. The mock database writes no file, so every backup there fails.
BOOST_FIXTURE_TEST_CASE(a_new_key_whose_backup_fails_stays_pending_and_is_retried_as_the_same_key, LegacyStakeWindowSetup)
{
    using Outcome = QuantumStakeReturnPreparation::Outcome;
    ScopedQuantumBackupDir backups{m_path_root / "qkb"};
    auto wallet = CreateSyncedWallet(*m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), coinbaseKey);
    QuantumStakeReturnPreparation prep = PrepareQuantumStakeReturn(*wallet, QuantumStakeReturnTrigger::EXPLICIT, /*allow_new_key=*/true);
    BOOST_CHECK(prep.outcome == Outcome::PENDING_BACKUP);
    BOOST_CHECK(prep.key_created);
    BOOST_CHECK(!prep.Saved());
    BOOST_CHECK(!prep.detail.empty());
    const std::string pending_address = prep.address;
    const auto pending_dest = DecodeDestination(pending_address);
    BOOST_REQUIRE(IsValidDestination(pending_dest));

    {
        LOCK(wallet->cs_wallet);
        BOOST_REQUIRE(wallet->m_quantum_return_pending.has_value());
        BOOST_CHECK_EQUAL(wallet->m_quantum_return_pending->consent, "explicit");
        BOOST_CHECK(wallet->m_quantum_stake_return.empty());
        BOOST_CHECK(wallet->IsQuantumStakeReturnPendingKey(pending_dest));
        const LegacyStakeQuantumReturn state = ResolveLegacyStakeQuantumReturn(*wallet);
        BOOST_CHECK(!state.available);
        BOOST_CHECK(state.pending);
        BOOST_CHECK_EQUAL(state.pending_address, pending_address);
        BOOST_CHECK_EQUAL(state.pending_error, prep.detail);
        const std::string notice = LegacyStakingNotice(Params().GetConsensus(), 101, state);
        BOOST_CHECK(notice.find("NOT active") != std::string::npos);
        BOOST_CHECK(notice.find(pending_address) != std::string::npos);
    }
    // not through the explicit binding either
    bilingual_str error;
    BOOST_CHECK(!SetQuantumStakeReturn(*wallet, pending_dest, error));
    BOOST_CHECK(error.original.find("waiting for its first verified wallet backup") != std::string::npos);
    BOOST_CHECK(WITH_LOCK(wallet->cs_wallet, return wallet->m_quantum_stake_return.empty()));
    // and not as a candidate of the automatic choice: asking again retries this key, it makes no second one
    gArgs.ForceSetArg("-qqallowautokeycreation", "1");
    prep = PrepareQuantumStakeReturn(*wallet, QuantumStakeReturnTrigger::AUTOMATIC);
    prep = PrepareQuantumStakeReturn(*wallet, QuantumStakeReturnTrigger::EXPLICIT, true);
    gArgs.ForceSetArg("-qqallowautokeycreation", "0");
    BOOST_CHECK(prep.outcome == Outcome::PENDING_BACKUP);
    BOOST_CHECK_EQUAL(prep.address, pending_address);
    BOOST_CHECK_EQUAL(WITH_LOCK(wallet->cs_wallet, return wallet->ListQuantumKeyInfos().size()), size_t{1});
    // a second key for the return address cannot be made while one waits
    BOOST_CHECK(!wallet->AddQuantumStakeReturnKey("PoS - Quantum Stake Address", "explicit"));

    // The record round trip: key and record are in the same database, and a reload finds both.
    const MockableData records = GetMockableDatabase(*wallet).m_records;
    CWallet reloaded(m_node.chain.get(), "", CreateMockableWalletDatabase(records));
    BOOST_REQUIRE_EQUAL(reloaded.LoadWallet(), DBErrors::LOAD_OK);
    {
        LOCK(reloaded.cs_wallet);
        BOOST_REQUIRE(reloaded.m_quantum_return_pending.has_value());
        BOOST_CHECK(reloaded.m_quantum_return_pending->witness_program == WITH_LOCK(wallet->cs_wallet, return wallet->m_quantum_return_pending->witness_program));
        BOOST_CHECK_EQUAL(reloaded.m_quantum_return_pending->consent, "explicit");
        BOOST_CHECK(reloaded.IsQuantumStakeReturnPendingKey(pending_dest));
        BOOST_CHECK(reloaded.m_quantum_stake_return.empty());
        BOOST_CHECK(!ResolveLegacyStakeQuantumReturn(reloaded).available);
    }
    // a record that names no key of the wallet is dropped, the wallet loads
    MockableData orphaned = records;
    for (auto it = orphaned.begin(); it != orphaned.end();) {
        // erase the key records, keep the pending record
        DataStream key{it->first};
        std::string type;
        key >> type;
        if (type == DBKeys::QUANTUM_KEY || type == DBKeys::QUANTUM_KEY_BACKUP_STATE || type == DBKeys::NAME || type == DBKeys::PURPOSE) {
            it = orphaned.erase(it);
        } else {
            ++it;
        }
    }
    CWallet without_key(m_node.chain.get(), "", CreateMockableWalletDatabase(orphaned));
    BOOST_REQUIRE_EQUAL(without_key.LoadWallet(), DBErrors::LOAD_OK);
    BOOST_CHECK(!WITH_LOCK(without_key.cs_wallet, return without_key.m_quantum_return_pending.has_value()));
}

// A key made for the return address whose backup failed carries the PoS label and sits in the address book. No
// automatic payout choice may take it (Gold Rush PoS signals, the PoW claim binding), configured or labelled or cached.
BOOST_FIXTURE_TEST_CASE(a_pending_return_key_is_never_chosen_as_a_gold_rush_payout_address, LegacyStakeWindowSetup)
{
    using Outcome = QuantumStakeReturnPreparation::Outcome;
    ScopedArgsRestore restore_args;
    ScopedQuantumBackupDir backups{m_path_root / "qkb-payout"};
    auto wallet = CreateSyncedWallet(*m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), coinbaseKey);
    // The mock database writes no file: the backup fails, the new key stays pending.
    const QuantumStakeReturnPreparation prep = PrepareQuantumStakeReturn(*wallet, QuantumStakeReturnTrigger::EXPLICIT, /*allow_new_key=*/true);
    BOOST_REQUIRE(prep.outcome == Outcome::PENDING_BACKUP);
    const CTxDestination pending = DecodeDestination(prep.address);
    BOOST_REQUIRE(IsValidDestination(pending));
    BOOST_CHECK(WITH_LOCK(wallet->cs_wallet, return wallet->IsQuantumStakeReturnPendingKey(pending)));
    {
        // The pending key sits in the address book under the label the PoS signal looks for.
        bool labelled{false};
        LOCK(wallet->cs_wallet);
        wallet->ForEachAddrBookEntry([&](const CTxDestination& dest, const std::string& label, bool, const std::optional<AddressPurpose>&) {
            if (dest == pending && label == "PoS - Quantum Stake Address") labelled = true;
        });
        BOOST_CHECK(labelled);
    }

    CScript script;
    std::string address;
    bilingual_str error;
    bool created{false};
    // The labelled reuse path: without consent to make a key the PoS signal has no payout, rather than this one.
    gArgs.ForceSetArg("-qqallowautokeycreation", "0");
    BOOST_CHECK(!wallet->EnsureShadowSignalPayoutAddress(script, address, error, &created));
    BOOST_CHECK(address.empty());
    BOOST_CHECK(script.empty());
    BOOST_CHECK(!created);
    BOOST_CHECK_MESSAGE(error.original.find("no existing payout key") != std::string::npos, error.original);
    // With consent a different key is made; the pending one is left alone.
    gArgs.ForceSetArg("-qqallowautokeycreation", "1");
    BOOST_REQUIRE_MESSAGE(wallet->EnsureShadowSignalPayoutAddress(script, address, error, &created), error.original);
    BOOST_CHECK(created);
    BOOST_CHECK(address != prep.address);
    BOOST_CHECK(WITH_LOCK(wallet->cs_wallet, return wallet->IsQuantumStakeReturnPendingKey(pending)));
    gArgs.ForceSetArg("-qqallowautokeycreation", "0");

    // A configured payout address: the shared validation refuses it, for the PoS signal and the PoW claim alike.
    {
        ScopedArgsRestore configured_pos;
        gArgs.ForceSetArg("-qqpospayoutaddress", prep.address);
        BOOST_CHECK(!wallet->EnsureShadowSignalPayoutAddress(script, address, error, &created));
        BOOST_CHECK_MESSAGE(error.original.find("waiting for its first verified wallet backup") != std::string::npos, error.original);
    }
    {
        ScopedArgsRestore configured_pow;
        gArgs.ForceSetArg("-qqpowpayoutaddress", prep.address);
        BOOST_CHECK(!wallet->EnsurePowPayoutAddress(error, &created));
        BOOST_CHECK_MESSAGE(error.original.find("waiting for its first verified wallet backup") != std::string::npos, error.original);
        BOOST_CHECK(WITH_LOCK(wallet->cs_wallet, return wallet->m_pow_payout_quantum.empty()));
    }

    // A cached binding to the pending key is refused as well, and so is a pending key under the PoW label.
    WITH_LOCK(wallet->cs_wallet, wallet->m_pow_payout_quantum = prep.address);
    BOOST_CHECK(!wallet->EnsurePowPayoutAddress(error, &created));
    BOOST_CHECK_MESSAGE(error.original.find("waiting for its first verified wallet backup") != std::string::npos, error.original);
    BOOST_CHECK(WITH_LOCK(wallet->cs_wallet, return !IsValidDestination(wallet->GetRecordedPowPayoutKey())));
    WITH_LOCK(wallet->cs_wallet, wallet->m_pow_payout_quantum.clear());
    BOOST_REQUIRE(wallet->SetAddressBook(pending, "PoW - Quantum Claim Address", AddressPurpose::RECEIVE));
    BOOST_CHECK(!wallet->EnsurePowPayoutAddress(error, &created));
    BOOST_CHECK(WITH_LOCK(wallet->cs_wallet, return wallet->m_pow_payout_quantum.empty()));
}

// The same on a real database: the backup is made, verified and recorded, and only then the address is active.
BOOST_FIXTURE_TEST_CASE(a_new_key_becomes_the_return_address_after_a_verified_backup_and_a_failed_one_is_retried, LegacyStakeWindowSetup)
{
    using Outcome = QuantumStakeReturnPreparation::Outcome;
    const fs::path base = m_path_root / "qkb-retry";
    ScopedQuantumBackupDir backups{base};
    auto wallet = CreateSyncedDiskWallet(*this, coinbaseKey, "retry-wallet");
    // The backup directory cannot be made: a regular file stands where its parent should be.
    {
        std::ofstream{m_path_root / "blocked"} << "a file";
        gArgs.ForceSetArg("-quantumkeybackupdir", fs::PathToString(m_path_root / "blocked" / "below"));
        const QuantumStakeReturnPreparation prep = PrepareQuantumStakeReturn(*wallet, QuantumStakeReturnTrigger::EXPLICIT, true);
        BOOST_CHECK(prep.outcome == Outcome::PENDING_BACKUP);
        BOOST_CHECK(WITH_LOCK(wallet->cs_wallet, return wallet->m_quantum_stake_return.empty()));
        BOOST_CHECK(WITH_LOCK(wallet->cs_wallet, return wallet->m_quantum_return_pending.has_value()));
        BOOST_CHECK(!WITH_LOCK(wallet->cs_wallet, return wallet->m_quantum_return_pending_error.empty()));
    }
    gArgs.ForceSetArg("-quantumkeybackupdir", fs::PathToString(base));
    const std::string pending_address = WITH_LOCK(wallet->cs_wallet, return EncodeDestination(WitnessUnknown{QUANTUM_MIGRATION_WITNESS_VERSION, wallet->m_quantum_return_pending->witness_program}));
    // The wallet's own (automatic) retry waits a minute after a failure; an explicit call does not.
    BOOST_CHECK(PrepareQuantumStakeReturn(*wallet, QuantumStakeReturnTrigger::AUTOMATIC).outcome == Outcome::NO_ACTION);
    const QuantumStakeReturnPreparation prep = PrepareQuantumStakeReturn(*wallet, QuantumStakeReturnTrigger::EXPLICIT);
    BOOST_CHECK(prep.outcome == Outcome::CREATED_ADDRESS);
    BOOST_CHECK_EQUAL(prep.address, pending_address);
    {
        LOCK(wallet->cs_wallet);
        BOOST_CHECK(!wallet->m_quantum_return_pending.has_value());
        BOOST_CHECK(wallet->m_quantum_return_pending_error.empty());
        BOOST_CHECK_EQUAL(wallet->m_quantum_stake_return, pending_address);
        BOOST_CHECK_EQUAL(wallet->ListQuantumKeyInfos().size(), size_t{1});
        const LegacyStakeQuantumReturn state = ResolveLegacyStakeQuantumReturn(*wallet);
        BOOST_CHECK(state.available);
        BOOST_CHECK(state.backup_verified);
        BOOST_CHECK(!state.pending);
    }
    const fs::path directory = base / fs::PathFromString(QuantumKeyBackupWalletComponent("retry-wallet"));
    const auto generations = ListQuantumKeyBackupGenerations(directory);
    BOOST_REQUIRE_EQUAL(generations.size(), size_t{1});
    BOOST_CHECK(generations[0].verified);
    BOOST_CHECK_EQUAL(generations[0].keys.size(), size_t{1});
    BOOST_CHECK(fs::exists(directory / fs::PathFromString(generations[0].file_name)));
}

// A backup that failed before the last Migration block is still completed afterwards: the pending key is handled
// before the automatic path's cutoff after M. The unlock requirement and the pause after a failure stay.
BOOST_FIXTURE_TEST_CASE(a_pending_key_whose_backup_failed_before_the_window_ended_is_retried_after_final_starts, LegacyStakeWindowSetup)
{
    using Outcome = QuantumStakeReturnPreparation::Outcome;
    const fs::path base = m_path_root / "qkb-after-final";
    ScopedQuantumBackupDir backups{base};
    auto wallet = CreateSyncedDiskWallet(*this, coinbaseKey, "after-final-wallet");
    {
        std::ofstream{m_path_root / "blocked-after-final"} << "a file";
        gArgs.ForceSetArg("-quantumkeybackupdir", fs::PathToString(m_path_root / "blocked-after-final" / "below"));
        const QuantumStakeReturnPreparation prep = PrepareQuantumStakeReturn(*wallet, QuantumStakeReturnTrigger::EXPLICIT, true);
        BOOST_CHECK(prep.outcome == Outcome::PENDING_BACKUP);
    }
    gArgs.ForceSetArg("-quantumkeybackupdir", fs::PathToString(base));
    const std::string pending_address = WITH_LOCK(wallet->cs_wallet, return EncodeDestination(WitnessUnknown{QUANTUM_MIGRATION_WITNESS_VERSION, wallet->m_quantum_return_pending->witness_program}));

    // Restart-like state at the first Final block: the next block (106) is after the last Migration block (105).
    mineBlocks(5);
    BOOST_CHECK_EQUAL(WITH_LOCK(::cs_main, return m_node.chainman->ActiveChain().Height()), 105);
    BOOST_CHECK(WITH_LOCK(wallet->cs_wallet, return wallet->m_quantum_return_pending.has_value()));

    // Normal unlock requirements are kept: a staking-only unlock does not complete it.
    wallet->m_quantum_return_retry_at = {};
    wallet->m_wallet_unlock_staking_only = true;
    BOOST_CHECK(PrepareQuantumStakeReturn(*wallet, QuantumStakeReturnTrigger::AUTOMATIC).outcome == Outcome::NO_ACTION);
    BOOST_CHECK(WITH_LOCK(wallet->cs_wallet, return wallet->m_quantum_return_pending.has_value()));
    wallet->m_wallet_unlock_staking_only = false;

    // The pause after a failure is kept: the retry time of the failed attempt has not come.
    wallet->m_quantum_return_retry_at = SteadyClock::now() + std::chrono::seconds{60};
    QuantumStakeReturnPreparation prep = PrepareQuantumStakeReturn(*wallet, QuantumStakeReturnTrigger::AUTOMATIC);
    BOOST_CHECK(prep.outcome == Outcome::NO_ACTION);
    BOOST_CHECK(prep.detail.find("retried soon") != std::string::npos);
    BOOST_CHECK(WITH_LOCK(wallet->cs_wallet, return wallet->m_quantum_return_pending.has_value()));

    // Once it has, the automatic path completes the same key after Final has started.
    wallet->m_quantum_return_retry_at = {};
    prep = PrepareQuantumStakeReturn(*wallet, QuantumStakeReturnTrigger::AUTOMATIC);
    BOOST_CHECK(prep.outcome == Outcome::CREATED_ADDRESS);
    BOOST_CHECK_EQUAL(prep.address, pending_address);
    {
        LOCK(wallet->cs_wallet);
        BOOST_CHECK(!wallet->m_quantum_return_pending.has_value());
        BOOST_CHECK_EQUAL(wallet->m_quantum_stake_return, pending_address);
    }
    // Nothing else is chosen or made by the automatic path after the window: no pending key, no new choice.
    gArgs.ForceSetArg("-qqallowautokeycreation", "1");
    auto other = CreateSyncedDiskWallet(*this, coinbaseKey, "after-final-other");
    prep = PrepareQuantumStakeReturn(*other, QuantumStakeReturnTrigger::AUTOMATIC);
    gArgs.ForceSetArg("-qqallowautokeycreation", "0");
    BOOST_CHECK(prep.outcome == Outcome::NO_ACTION);
    BOOST_CHECK_EQUAL(prep.detail, "the window has passed");
}

// The directories that hold the backup are made durable before the key is activated: when the commit of a new
// directory's entry fails, the key stays pending with the previous destination, and the retry completes it.
// (The failure is injected through a test-chain-only option, -quantumreturnfailcommit.)
BOOST_FIXTURE_TEST_CASE(a_failed_commit_of_a_new_backup_directory_keeps_the_new_key_pending, LegacyStakeWindowSetup)
{
    using Outcome = QuantumStakeReturnPreparation::Outcome;
    ScopedArgsRestore restore_args;
    const fs::path base = m_path_root / "qkb-durable" / "inner";
    ScopedQuantumBackupDir backups{base};
    auto wallet = CreateSyncedDiskWallet(*this, coinbaseKey, "durable-wallet");
    ScopedArgsRestore fault_scope;
    gArgs.ForceSetArg("-quantumreturnfailcommit", "inner"); // the entry of the base directory made for this wallet
    QuantumStakeReturnPreparation prep = PrepareQuantumStakeReturn(*wallet, QuantumStakeReturnTrigger::EXPLICIT, true);
    BOOST_CHECK(prep.outcome == Outcome::PENDING_BACKUP);
    BOOST_CHECK_MESSAGE(prep.detail.find("durable") != std::string::npos, prep.detail);
    {
        LOCK(wallet->cs_wallet);
        BOOST_CHECK(wallet->m_quantum_stake_return.empty());
        BOOST_CHECK(wallet->m_quantum_return_pending.has_value());
        BOOST_CHECK_EQUAL(wallet->ListQuantumKeyInfos().size(), size_t{1});
    }
    // No backup was made while the directory was not durable.
    const fs::path directory = base / fs::PathFromString(QuantumKeyBackupWalletComponent("durable-wallet"));
    BOOST_CHECK(ListQuantumKeyBackupGenerations(directory).empty());
    // Still failing: the retry does not take the directories left by the first attempt as durable.
    prep = PrepareQuantumStakeReturn(*wallet, QuantumStakeReturnTrigger::EXPLICIT);
    BOOST_CHECK(prep.outcome == Outcome::PENDING_BACKUP);
    BOOST_CHECK(WITH_LOCK(wallet->cs_wallet, return wallet->m_quantum_stake_return.empty()));
    gArgs.ForceSetArg("-quantumreturnfailcommit", "");
    prep = PrepareQuantumStakeReturn(*wallet, QuantumStakeReturnTrigger::EXPLICIT);
    BOOST_CHECK(prep.outcome == Outcome::CREATED_ADDRESS);
    BOOST_CHECK_EQUAL(WITH_LOCK(wallet->cs_wallet, return wallet->ListQuantumKeyInfos().size()), size_t{1});
    BOOST_CHECK_EQUAL(ListQuantumKeyBackupGenerations(directory).size(), size_t{1});
}

BOOST_FIXTURE_TEST_CASE(concurrent_preparations_make_one_key_and_one_backup, LegacyStakeWindowSetup)
{
    ScopedQuantumBackupDir backups{m_path_root / "qkb-concurrent"};
    auto wallet = CreateSyncedDiskWallet(*this, coinbaseKey, "concurrent-wallet");
    std::vector<std::thread> threads;
    std::vector<std::string> addresses(6);
    for (size_t i = 0; i < addresses.size(); ++i) {
        threads.emplace_back([&, i] {
            const QuantumStakeReturnPreparation prep = PrepareQuantumStakeReturn(*wallet, QuantumStakeReturnTrigger::EXPLICIT, true);
            addresses[i] = prep.address;
        });
    }
    for (std::thread& thread : threads) thread.join();
    BOOST_CHECK_EQUAL(WITH_LOCK(wallet->cs_wallet, return wallet->ListQuantumKeyInfos().size()), size_t{1});
    for (const std::string& address : addresses) BOOST_CHECK_EQUAL(address, addresses[0]);
    BOOST_CHECK_EQUAL(WITH_LOCK(wallet->cs_wallet, return wallet->m_quantum_stake_return), addresses[0]);
    const fs::path directory = m_path_root / "qkb-concurrent" / fs::PathFromString(QuantumKeyBackupWalletComponent("concurrent-wallet"));
    BOOST_CHECK_EQUAL(ListQuantumKeyBackupGenerations(directory).size(), size_t{1});
}


BOOST_AUTO_TEST_SUITE_END()
} // namespace
} // namespace wallet
