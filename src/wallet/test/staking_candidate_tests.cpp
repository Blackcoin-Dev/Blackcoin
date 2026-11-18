// Copyright (c) 2026 Blackcoin Core Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <chain.h>
#include <chainparams.h>
#include <coins.h>
#include <consensus/validation.h>
#include <key.h>
#include <pos.h>
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

BOOST_AUTO_TEST_SUITE_END()
} // namespace
} // namespace wallet
