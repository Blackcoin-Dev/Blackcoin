// Copyright (c) 2026 Blackcoin Core Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <chain.h>
#include <chainparams.h>
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
    auto wallet = CreateSyncedWallet(*m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), coinbaseKey);
    // No quantum address and key creation not allowed: no action, no key, and it says why.
    QuantumStakeReturnPreparation prep = PrepareQuantumStakeReturn(*wallet, QuantumStakeReturnTrigger::AUTOMATIC);
    BOOST_CHECK(prep.outcome == Outcome::NO_ACTION);
    BOOST_CHECK(!prep.key_created);
    BOOST_CHECK(!prep.Saved());
    BOOST_CHECK(!prep.detail.empty());

    // Key creation allowed: a key is created, saved, and reported as created.
    gArgs.ForceSetArg("-qqallowautokeycreation", "1");
    prep = PrepareQuantumStakeReturn(*wallet, QuantumStakeReturnTrigger::AUTOMATIC);
    gArgs.ForceSetArg("-qqallowautokeycreation", "0");
    BOOST_CHECK(prep.outcome == Outcome::CREATED_ADDRESS);
    BOOST_CHECK(prep.key_created);
    BOOST_CHECK(prep.Saved());
    BOOST_CHECK_EQUAL(WITH_LOCK(wallet->cs_wallet, return wallet->m_quantum_stake_return), prep.address);

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
    auto wallet = CreateSyncedWallet(*m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), coinbaseKey);
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
    auto holder = CreateSyncedWallet(*m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), coinbaseKey);
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
}

BOOST_AUTO_TEST_SUITE_END()
} // namespace
} // namespace wallet
