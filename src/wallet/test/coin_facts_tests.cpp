// Copyright (c) 2026 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <wallet/coin_facts.h>

#include <chain.h>
#include <chainparams.h>
#include <coins.h>
#include <interfaces/chain.h>
#include <key.h>
#include <random.h>
#include <script/script.h>
#include <script/solver.h>
#include <serialize.h>
#include <shadow.h>
#include <streams.h>
#include <test/util/setup_common.h>
#include <validation.h>
#include <wallet/spend.h>
#include <wallet/test/util.h>
#include <wallet/wallet.h>

#include <boost/test/unit_test.hpp>

#include <algorithm>
#include <memory>
#include <vector>

namespace wallet {
BOOST_AUTO_TEST_SUITE(coin_facts_tests)

namespace {
/** A chain of block indexes that exists only in this test. */
struct FakeChain {
    std::vector<std::unique_ptr<uint256>> hashes;
    std::vector<std::unique_ptr<CBlockIndex>> blocks;

    CBlockIndex* Add(CBlockIndex* prev, uint32_t time, uint8_t salt)
    {
        const int height = prev ? prev->nHeight + 1 : 0;
        uint256 hash;
        *hash.begin() = salt;
        *(hash.begin() + 1) = static_cast<uint8_t>(height & 0xff);
        *(hash.begin() + 2) = static_cast<uint8_t>((height >> 8) & 0xff);
        *(hash.begin() + 31) = 0x5a;
        hashes.push_back(std::make_unique<uint256>(hash));
        auto index = std::make_unique<CBlockIndex>();
        index->phashBlock = hashes.back().get();
        index->pprev = prev;
        index->nHeight = height;
        index->nTime = time;
        index->BuildSkip();
        blocks.push_back(std::move(index));
        return blocks.back().get();
    }
};

CScript PayScript(uint8_t tag)
{
    return CScript{} << OP_DUP << OP_HASH160 << std::vector<unsigned char>(20, tag) << OP_EQUALVERIFY << OP_CHECKSIG;
}

CMutableTransaction MakeTx(int32_t version, uint32_t time, bool coinbase, bool coinstake)
{
    CMutableTransaction tx;
    tx.nVersion = version;
    tx.nTime = version < 2 ? time : 0;
    tx.vin.resize(1);
    if (coinbase) {
        tx.vin[0].prevout.SetNull();
        tx.vin[0].scriptSig = CScript{} << 7 << OP_0;
    } else {
        tx.vin[0].prevout = COutPoint{uint256{static_cast<uint8_t>(0x30 + version + (coinstake ? 8 : 0))}, 1};
    }
    if (coinstake) tx.vout.emplace_back(0, CScript{});
    tx.vout.emplace_back(3 * COIN, PayScript(0x11));
    tx.vout.emplace_back(0, CScript{} << OP_RETURN << std::vector<unsigned char>(8, 0x22));
    tx.vout.emplace_back(5 * COIN, PayScript(0x33));
    return tx;
}

ConfirmedTxFacts FactsOf(const CTransaction& tx, const CBlockIndex& block)
{
    return ConfirmedTxFacts{tx.nVersion, tx.nTime, tx.IsCoinBase(), tx.IsCoinStake(), block.GetBlockHash(), block.nHeight};
}
} // namespace

BOOST_AUTO_TEST_CASE(chainstate_key_order_is_the_order_of_the_database_keys)
{
    FastRandomContext rng{/*fDeterministic=*/true};
    std::vector<COutPoint> outpoints;
    const std::vector<uint32_t> indexes{0, 1, 126, 127, 128, 129, 255, 256, 16510, 16511, 16512, 16513,
                                        2113663, 2113664, 0x7fffffff, 0xfffffffe, 0xffffffff};
    for (int t = 0; t < 12; ++t) {
        const uint256 txid = rng.rand256();
        for (const uint32_t n : indexes) outpoints.emplace_back(txid, n);
    }
    // Txids that differ only in their last or first byte.
    uint256 low, high;
    *(low.begin() + 31) = 1;
    *high.begin() = 1;
    outpoints.emplace_back(low, 0);
    outpoints.emplace_back(high, 0);

    for (const COutPoint& outpoint : outpoints) {
        DataStream stream{};
        stream << uint8_t{'C'} << outpoint.hash << VARINT(outpoint.n);
        const std::vector<unsigned char> expected{UCharCast(stream.data()), UCharCast(stream.data()) + stream.size()};
        BOOST_CHECK(ChainstateKeyBytes(outpoint) == expected);
    }

    OrderedChainCursor cursor;
    cursor.Reset(outpoints.size(), [&](uint32_t i) -> const COutPoint& { return outpoints[i]; });
    BOOST_REQUIRE_EQUAL(cursor.Order().size(), outpoints.size());
    for (size_t i = 1; i < cursor.Order().size(); ++i) {
        const std::vector<unsigned char> before = ChainstateKeyBytes(outpoints[cursor.Order()[i - 1]]);
        const std::vector<unsigned char> after = ChainstateKeyBytes(outpoints[cursor.Order()[i]]);
        BOOST_CHECK(before < after);
    }
    // The numeric order of the output index is not the order of the keys.
    const uint256 txid = rng.rand256();
    BOOST_CHECK(ChainstateKeyLess(COutPoint{txid, 16512}, COutPoint{txid, 16511}));
    BOOST_CHECK(!ChainstateKeyLess(COutPoint{txid, 7}, COutPoint{txid, 7}));
}

BOOST_AUTO_TEST_CASE(derived_coin_equals_the_coin_the_view_holds)
{
    LOCK(::cs_main);
    FakeChain chain;
    CBlockIndex* tip{nullptr};
    for (int i = 0; i < 40; ++i) tip = chain.Add(tip, /*time=*/1700000000 + 64 * static_cast<uint32_t>(i), /*salt=*/0xa0);
    CBlockIndex* block = tip->GetAncestor(25);
    BOOST_REQUIRE(block);

    CCoinsView base;
    CCoinsViewCache view{&base};

    struct Shape {
        int32_t version;
        bool coinbase;
        bool coinstake;
    };
    const std::vector<Shape> shapes{{1, false, false}, {2, false, false}, {1, false, true}, {2, false, true},
                                    {1, true, false}, {2, true, false}};
    for (const Shape& shape : shapes) {
        const CTransaction tx{MakeTx(shape.version, /*time=*/1600000123, shape.coinbase, shape.coinstake)};
        BOOST_REQUIRE_EQUAL(tx.IsCoinBase(), shape.coinbase);
        BOOST_REQUIRE_EQUAL(tx.IsCoinStake(), shape.coinstake);
        AddCoins(view, tx, block->nHeight, /*check=*/false, block->GetBlockTime());
        BOOST_CHECK_EQUAL(ConfirmedCoinTime(tx.nVersion, tx.nTime, block->nTime), GetCoinTime(tx, block->GetBlockTime()));
        const ConfirmedTxFacts facts = FactsOf(tx, *block);
        for (uint32_t n = 0; n < tx.vout.size(); ++n) {
            Coin stored;
            const bool have = view.GetCoin(COutPoint{tx.GetHash(), n}, stored) && !stored.IsSpent();
            const std::optional<Coin> derived = DeriveConfirmedCoin(tx.vout[n], facts, tip);
            if (shape.coinbase) {
                // A coinbase shaped transaction is never derived: its coin
                // (and a synthetic payout's provenance) is read.
                BOOST_CHECK(!derived);
                BOOST_CHECK(!have || stored.IsCoinBase());
                continue;
            }
            // An unspendable output never entered the UTXO set, and an empty
            // coinstake marker output is not something a wallet holds.
            if (tx.vout[n].scriptPubKey.IsUnspendable()) {
                BOOST_CHECK(!have);
                BOOST_CHECK(!derived);
                continue;
            }
            BOOST_REQUIRE(have);
            BOOST_REQUIRE(derived);
            BOOST_CHECK(derived->out == stored.out);
            BOOST_CHECK_EQUAL(derived->nHeight, stored.nHeight);
            BOOST_CHECK_EQUAL(derived->nTime, stored.nTime);
            BOOST_CHECK_EQUAL(derived->IsCoinBase(), stored.IsCoinBase());
            BOOST_CHECK_EQUAL(derived->IsCoinStake(), stored.IsCoinStake());
            BOOST_CHECK_EQUAL(derived->IsCoinStake(), shape.coinstake);
            BOOST_CHECK_EQUAL(derived->nTime, shape.version < 2 ? 1600000123U : block->nTime);
        }
    }

    // A transaction whose block is not in the active chain is not derived.
    const CTransaction tx{MakeTx(2, 0, false, false)};
    const ConfirmedTxFacts facts = FactsOf(tx, *block);
    BOOST_REQUIRE(DeriveConfirmedCoin(tx.vout[0], facts, tip));
    // ... a fork that left the chain below the block,
    CBlockIndex* fork = tip->GetAncestor(20);
    for (int i = 0; i < 30; ++i) fork = chain.Add(fork, /*time=*/1700009000 + 64 * static_cast<uint32_t>(i), /*salt=*/0xb0);
    BOOST_REQUIRE(fork->GetAncestor(25)->GetBlockHash() != block->GetBlockHash());
    BOOST_CHECK(!DeriveConfirmedCoin(tx.vout[0], facts, fork));
    // ... a tip below the block, no tip, and a height the wallet does not have.
    BOOST_CHECK(!DeriveConfirmedCoin(tx.vout[0], facts, tip->GetAncestor(24)));
    BOOST_CHECK(!DeriveConfirmedCoin(tx.vout[0], facts, nullptr));
    ConfirmedTxFacts unknown = facts;
    unknown.block_height = -1;
    BOOST_CHECK(!DeriveConfirmedCoin(tx.vout[0], unknown, tip));
    // The same block reached through a longer chain is still the block.
    BOOST_CHECK(DeriveConfirmedCoin(tx.vout[0], FactsOf(tx, *tip->GetAncestor(20)), fork));
}

BOOST_FIXTURE_TEST_CASE(payout_status_of_a_coin_that_is_not_coinbase_needs_no_read, BasicTestingSetup)
{
    // The lifecycle facts skip GetGoldRushPayoutStatus() for a confirmed coin
    // that is not coinbase. Whatever the chainstate holds at the reserved
    // marker outpoint of such a coin, the status is NOT_CANDIDATE.
    const Consensus::Params& consensus = Params().GetConsensus();
    FakeChain chain;
    CBlockIndex* tip{nullptr};
    for (int i = 0; i < 8; ++i) tip = chain.Add(tip, 1700000000 + 64 * static_cast<uint32_t>(i), 0xc0);

    CCoinsView base;
    CCoinsViewCache view{&base};
    const CTransaction plain{MakeTx(2, 0, false, false)};
    const CTransaction stake{MakeTx(2, 0, false, true)};
    AddCoins(view, plain, tip->nHeight, false, tip->GetBlockTime());
    AddCoins(view, stake, tip->nHeight, false, tip->GetBlockTime());
    // The direct payout marker consensus writes for an output of a coinstake.
    std::map<CScript, CAmount> payouts;
    payouts.emplace(stake.vout[1].scriptPubKey, stake.vout[1].nValue);
    const unsigned int entries_before = view.GetCacheSize();
    MarkGoldRushDirectPayoutOutputs(view, stake, tip, payouts);
    BOOST_REQUIRE_EQUAL(view.GetCacheSize(), entries_before + 1); // the marker is there

    for (const CTransaction* tx : {&plain, &stake}) {
        for (uint32_t n = 0; n < tx->vout.size(); ++n) {
            const COutPoint outpoint{tx->GetHash(), n};
            Coin coin;
            if (!view.GetCoin(outpoint, coin) || coin.IsSpent()) continue;
            BOOST_REQUIRE(!coin.IsCoinBase());
            BOOST_CHECK(GetGoldRushPayoutStatus(view, outpoint, consensus, nullptr, tip) == GoldRushPayoutStatus::NOT_CANDIDATE);
            BOOST_CHECK(GetGoldRushPayoutStatus(view, outpoint, consensus, nullptr, nullptr) == GoldRushPayoutStatus::NOT_CANDIDATE);
        }
    }
}

namespace {
struct CoinFactsChainSetup : public TestChain100Setup {
    const CBlockIndex* Tip()
    {
        return WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain().Tip());
    }
    CBlock Mine(const std::vector<CMutableTransaction>& txs = {})
    {
        return CreateAndProcessBlock(txs, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));
    }
    void Notify(CWallet& wallet, const CBlock& block)
    {
        const CBlockIndex* index = WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
            return m_node.chainman->m_blockman.LookupBlockIndex(block.GetHash()));
        BOOST_REQUIRE(index);
        const uint256 hash = index->GetBlockHash();
        const uint256 prev_hash = index->pprev->GetBlockHash();
        interfaces::BlockInfo info{hash};
        info.prev_hash = &prev_hash;
        info.height = index->nHeight;
        info.data = &block;
        info.chain_time_max = index->GetBlockTimeMax();
        wallet.blockConnected(ChainstateRole::NORMAL, info);
    }
    std::vector<std::optional<Coin>> DirectReads(const std::vector<COutPoint>& outpoints)
    {
        std::vector<std::optional<Coin>> coins;
        LOCK(::cs_main);
        const CCoinsViewCache& tip = m_node.chainman->ActiveChainstate().CoinsTip();
        for (const COutPoint& outpoint : outpoints) {
            Coin coin;
            if (tip.PeekCoin(outpoint, coin) && !coin.IsSpent()) {
                coins.emplace_back(std::move(coin));
            } else {
                coins.emplace_back();
            }
        }
        return coins;
    }
};

void CheckSameCoins(const std::vector<std::optional<Coin>>& a, const std::vector<std::optional<Coin>>& b)
{
    BOOST_REQUIRE_EQUAL(a.size(), b.size());
    for (size_t i = 0; i < a.size(); ++i) {
        BOOST_REQUIRE_EQUAL(a[i].has_value(), b[i].has_value());
        if (!a[i]) continue;
        BOOST_CHECK(a[i]->out == b[i]->out);
        BOOST_CHECK_EQUAL(a[i]->nHeight, b[i]->nHeight);
        BOOST_CHECK_EQUAL(a[i]->nTime, b[i]->nTime);
        BOOST_CHECK_EQUAL(a[i]->IsCoinBase(), b[i]->IsCoinBase());
        BOOST_CHECK_EQUAL(a[i]->IsCoinStake(), b[i]->IsCoinStake());
    }
}
} // namespace

BOOST_FIXTURE_TEST_CASE(ordered_reader_equals_unordered_reads_and_restarts_when_the_tip_moves, CoinFactsChainSetup)
{
    FastRandomContext rng{/*fDeterministic=*/true};
    std::vector<COutPoint> outpoints;
    for (const CTransactionRef& tx : m_coinbase_txns) {
        outpoints.emplace_back(tx->GetHash(), 0);
        outpoints.emplace_back(tx->GetHash(), 1); // may not exist
    }
    for (int i = 0; i < 20; ++i) outpoints.emplace_back(rng.rand256(), static_cast<uint32_t>(i)); // do not exist
    Shuffle(outpoints.begin(), outpoints.end(), rng);

    LifecycleSliceLimits limits = LifecycleSliceLimits::Unlimited();
    limits.max_items = 7;
    const auto run_slice = [&](OrderedCoinReader& reader) {
        LOCK(::cs_main);
        SliceMeter meter{limits, limits.main_budget};
        return reader.RunSlice(m_node.chainman->ActiveChainstate().CoinsTip(),
                               m_node.chainman->ActiveChain().Tip()->GetBlockHash(), meter);
    };

    {
        OrderedCoinReader reader{outpoints};
        std::vector<std::vector<unsigned char>> keys;
        reader.SetOnReadForTest([&](const COutPoint& outpoint) { keys.push_back(ChainstateKeyBytes(outpoint)); });
        const size_t cache_before = WITH_LOCK(::cs_main, return m_node.chainman->ActiveChainstate().CoinsTip().GetCacheSize());
        int slices{0};
        OrderedSliceResult result;
        do {
            result = run_slice(reader);
            ++slices;
            BOOST_REQUIRE(result == OrderedSliceResult::MORE || result == OrderedSliceResult::DONE);
        } while (result != OrderedSliceResult::DONE);
        // Sliced: seven items a slice.
        BOOST_CHECK_GE(slices, static_cast<int>(outpoints.size() / 7));
        BOOST_CHECK(reader.Done());
        BOOST_CHECK_EQUAL(reader.Restarts(), 0U);
        BOOST_CHECK(reader.TipHash() == Tip()->GetBlockHash());
        // Every outpoint was read once, in the order of the database keys.
        BOOST_REQUIRE_EQUAL(keys.size(), outpoints.size());
        for (size_t i = 1; i < keys.size(); ++i) BOOST_CHECK(keys[i - 1] <= keys[i]);
        // The same coins as reads in the caller's order.
        CheckSameCoins(reader.Coins(), DirectReads(outpoints));
        size_t found{0};
        for (const std::optional<Coin>& coin : reader.Coins()) found += coin ? 1 : 0;
        BOOST_CHECK_EQUAL(found, m_coinbase_txns.size());
        // Through the peek path: the chainstate cache did not grow.
        BOOST_CHECK_EQUAL(WITH_LOCK(::cs_main, return m_node.chainman->ActiveChainstate().CoinsTip().GetCacheSize()), cache_before);
    }

    {
        // The tip moves in the middle of a pass: the pass starts again and
        // its result is of the new tip.
        OrderedCoinReader reader{outpoints};
        size_t reads{0};
        reader.SetOnReadForTest([&](const COutPoint&) { ++reads; });
        BOOST_REQUIRE(run_slice(reader) == OrderedSliceResult::MORE);
        BOOST_REQUIRE(run_slice(reader) == OrderedSliceResult::MORE);
        BOOST_CHECK_EQUAL(reads, 14U);
        const CBlock block = Mine();
        outpoints.emplace_back(block.vtx[0]->GetHash(), 0); // not part of this reader
        BOOST_CHECK(run_slice(reader) == OrderedSliceResult::RESTARTED);
        BOOST_CHECK_EQUAL(reader.Restarts(), 1U);
        BOOST_CHECK(!reader.Done());
        for (const std::optional<Coin>& coin : reader.Coins()) BOOST_CHECK(!coin);
        OrderedSliceResult result;
        do {
            result = run_slice(reader);
        } while (result == OrderedSliceResult::MORE);
        BOOST_CHECK(result == OrderedSliceResult::DONE);
        BOOST_CHECK(reader.TipHash() == Tip()->GetBlockHash());
        BOOST_CHECK_EQUAL(reads, 14U + reader.Outpoints().size());
        CheckSameCoins(reader.Coins(), DirectReads(reader.Outpoints()));
    }
}

BOOST_FIXTURE_TEST_CASE(sliced_pass_derives_confirmed_outputs_that_are_not_coinbase, CoinFactsChainSetup)
{
    std::unique_ptr<CWallet> wallet{CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()),
        coinbaseKey)};
    const CScript wallet_script = GetScriptForRawPubKey(coinbaseKey.GetPubKey());

    // A confirmed wallet transaction that is not a coinbase.
    const CMutableTransaction spend = CreateValidMempoolTransaction(
        m_coinbase_txns[0], /*input_vout=*/0, /*input_height=*/1, coinbaseKey, wallet_script,
        m_coinbase_txns[0]->vout[0].nValue - COIN / 100, /*submit=*/false);
    const uint256 spend_txid = spend.GetHash();
    Notify(*wallet, Mine({spend}));
    const COutPoint derived_outpoint{spend_txid, 0};
    {
        LOCK(wallet->cs_wallet);
        const CWalletTx* wtx = wallet->GetWalletTx(spend_txid);
        BOOST_REQUIRE(wtx);
        BOOST_REQUIRE(wtx->state<TxStateConfirmed>());
        BOOST_REQUIRE(!wtx->IsCoinBase());
        BOOST_REQUIRE(!wallet->IsSpent(derived_outpoint));
    }

    struct Result {
        bool ok{false};
        Balance balance;
        WalletLifecycleSummary summary;
        WalletLifecycleScanStats stats;
    };
    const auto plain = [&](bool use_memo) {
        Result r;
        WalletLifecycleOptions options;
        options.use_memo = use_memo;
        options.stats = &r.stats;
        std::string error;
        LOCK2(::cs_main, wallet->cs_wallet);
        r.ok = GetLifecycleAdjustedBalance(*wallet, /*min_depth=*/0, /*avoid_reuse=*/true, r.balance, r.summary, error, options);
        BOOST_CHECK_MESSAGE(r.ok, error);
        return r;
    };
    LifecycleMemoJournal journal;
    LifecycleAttestationCache attestations;
    const auto sliced = [&](uint64_t max_items) {
        Result r;
        LifecyclePass pass;
        LifecycleSliceLimits limits = LifecycleSliceLimits::Unlimited();
        limits.max_items = max_items;
        const LifecycleSliceReport report = RunLifecyclePassToEnd(*wallet, pass, journal, attestations, limits);
        r.ok = report.result == LifecycleSliceResult::DONE;
        BOOST_CHECK_MESSAGE(r.ok, report.error);
        r.balance = pass.balance;
        r.summary = pass.summary;
        r.stats = pass.stats;
        return r;
    };
    const auto check_equal = [&](const Result& a, const Result& b) {
        BOOST_CHECK_EQUAL(a.balance.m_mine_trusted, b.balance.m_mine_trusted);
        BOOST_CHECK_EQUAL(a.balance.m_mine_immature, b.balance.m_mine_immature);
        BOOST_CHECK_EQUAL(a.balance.m_mine_stake, b.balance.m_mine_stake);
        BOOST_CHECK_EQUAL(a.balance.m_mine_untrusted_pending, b.balance.m_mine_untrusted_pending);
        BOOST_CHECK_EQUAL(a.summary.evaluation_height, b.summary.evaluation_height);
        BOOST_CHECK(a.summary.mine.outputs == b.summary.mine.outputs);
        BOOST_CHECK(a.summary.mine.nominal == b.summary.mine.nominal);
        BOOST_CHECK(a.summary.mine.effective == b.summary.mine.effective);
        BOOST_CHECK(a.summary.mine.burned == b.summary.mine.burned);
        BOOST_CHECK_EQUAL(a.summary.mine.ordinary_available, b.summary.mine.ordinary_available);
        BOOST_CHECK_EQUAL(a.summary.mine.spendable_legacy, b.summary.mine.spendable_legacy);
        BOOST_CHECK_EQUAL(a.summary.mine.spendable_quantum, b.summary.mine.spendable_quantum);
    };

    // The reference: every output read from the chainstate, nothing derived.
    const Result reference = plain(/*use_memo=*/false);
    BOOST_REQUIRE(reference.ok);
    BOOST_CHECK_EQUAL(reference.stats.derived, 0U);
    BOOST_CHECK_EQUAL(reference.stats.database_reads, reference.stats.outputs);

    // The sliced pass derives the one output that is not coinbase, shallow as
    // it is, reads the rest, and computes the same balance.
    for (const uint64_t max_items : {uint64_t{0}, uint64_t{1}, uint64_t{5}}) {
        const Result pass = sliced(max_items);
        BOOST_REQUIRE(pass.ok);
        check_equal(reference, pass);
        BOOST_CHECK_EQUAL(pass.stats.outputs, reference.stats.outputs);
        BOOST_CHECK_EQUAL(pass.stats.derived, 1U);
        BOOST_CHECK_EQUAL(pass.stats.database_reads + pass.stats.memo_hits + pass.stats.derived, pass.stats.outputs);
    }
    // So does the display scan that holds both locks.
    {
        const Result memo = plain(/*use_memo=*/true);
        check_equal(reference, memo);
        BOOST_CHECK_EQUAL(memo.stats.derived, 1U);
    }
    // Shallow: not memoized.
    BOOST_CHECK_EQUAL(WITH_LOCK(wallet->cs_wallet, return wallet->m_output_lifecycle_memo.count(derived_outpoint)), 0U);

    // A transaction whose block the wallet names is not the active chain's
    // block at that height is not derived: the chainstate is read.
    TxState good_state{TxStateInactive{}};
    {
        LOCK(wallet->cs_wallet);
        CWalletTx& wtx = wallet->mapWallet.at(spend_txid);
        good_state = wtx.m_state;
        const TxStateConfirmed& conf = *wtx.state<TxStateConfirmed>();
        uint256 other = conf.confirmed_block_hash;
        *other.begin() ^= 0x01;
        wtx.m_state = TxStateConfirmed{other, conf.confirmed_block_height, conf.position_in_block};
        wallet->BumpBalanceScanMarker();
    }
    {
        const Result pass = sliced(0);
        BOOST_REQUIRE(pass.ok);
        check_equal(reference, pass);
        BOOST_CHECK_EQUAL(pass.stats.derived, 0U);
        BOOST_CHECK_EQUAL(pass.stats.database_reads + pass.stats.memo_hits, pass.stats.outputs);
    }
    {
        LOCK(wallet->cs_wallet);
        wallet->mapWallet.at(spend_txid).m_state = good_state;
        wallet->BumpBalanceScanMarker();
    }

    // Deep: the derived facts are memoized, and they are the coin's.
    for (int i = 0; i < 101; ++i) Notify(*wallet, Mine());
    const Result deep_reference = plain(/*use_memo=*/false);
    const Result deep_pass = sliced(0);
    BOOST_REQUIRE(deep_pass.ok);
    check_equal(deep_reference, deep_pass);
    BOOST_CHECK_EQUAL(deep_pass.stats.derived, 1U);
    // The journal is applied by the pass's last wallet slice.
    WalletOutputLifecycleMemo memo;
    {
        LOCK(wallet->cs_wallet);
        BOOST_REQUIRE_EQUAL(wallet->m_output_lifecycle_memo.count(derived_outpoint), 1U);
        memo = wallet->m_output_lifecycle_memo.at(derived_outpoint);
    }
    const std::optional<Coin> coin = DirectReads({derived_outpoint}).front();
    BOOST_REQUIRE(coin);
    BOOST_CHECK_EQUAL(memo.coin_height, coin->nHeight);
    BOOST_CHECK_EQUAL(memo.coin_time, coin->nTime);
    BOOST_CHECK_EQUAL(memo.coinbase, coin->IsCoinBase());
    BOOST_CHECK_EQUAL(memo.coinstake, coin->IsCoinStake());
    BOOST_CHECK(!memo.synthetic);
    // And served from the memo from then on, unless the tip puts the entry in
    // the slice that is compared with the database.
    const Result again = sliced(0);
    check_equal(deep_reference, again);
    BOOST_CHECK_EQUAL(again.stats.derived, 0U);
    BOOST_CHECK_GE(again.stats.memo_hits, 1U);

    // The memo warm-up derives it too: no database read for it.
    WITH_LOCK(wallet->cs_wallet, wallet->ClearOutputLifecycleMemo());
    LifecycleWarmup warmup;
    LifecycleMemoJournal warm_journal;
    for (int i = 0; i < 100000; ++i) {
        const LifecycleSliceReport report = RunLifecycleWarmupSlice(*wallet, warmup, warm_journal, LifecycleSliceLimits::Unlimited());
        BOOST_REQUIRE(report.result != LifecycleSliceResult::LOCK_BUSY);
        if (report.result == LifecycleSliceResult::DONE) break;
    }
    BOOST_CHECK(warmup.stage == LifecycleWarmup::Stage::DONE);
    BOOST_CHECK_EQUAL(warmup.derived, 1U);
    BOOST_CHECK_GT(warmup.fetched, warmup.derived);
    {
        LOCK(wallet->cs_wallet);
        BOOST_REQUIRE_EQUAL(wallet->m_output_lifecycle_memo.count(derived_outpoint), 1U);
        const WalletOutputLifecycleMemo& warmed = wallet->m_output_lifecycle_memo.at(derived_outpoint);
        BOOST_CHECK_EQUAL(warmed.coin_height, memo.coin_height);
        BOOST_CHECK_EQUAL(warmed.coin_time, memo.coin_time);
        BOOST_CHECK_EQUAL(warmed.coinbase, memo.coinbase);
        BOOST_CHECK_EQUAL(warmed.coinstake, memo.coinstake);
        BOOST_CHECK_EQUAL(warmed.synthetic, memo.synthetic);
    }
    check_equal(deep_reference, sliced(0));
}

BOOST_AUTO_TEST_SUITE_END()
} // namespace wallet
