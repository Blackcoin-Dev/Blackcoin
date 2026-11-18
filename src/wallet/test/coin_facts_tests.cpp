// Copyright (c) 2026 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <wallet/coin_facts.h>

#include <chain.h>
#include <chainparams.h>
#include <coins.h>
#include <hash.h>
#include <interfaces/chain.h>
#include <key.h>
#include <random.h>
#include <script/interpreter.h>
#include <script/script.h>
#include <script/sign.h>
#include <script/signingprovider.h>
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
#include <chrono>
#include <functional>
#include <map>
#include <memory>
#include <set>
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

namespace {
/** A coins database stand-in that records every key it is asked for and
 * charges an injected clock for each read. */
class RecordingCoinsView final : public CCoinsView
{
public:
    std::map<COutPoint, Coin> coins;
    mutable std::vector<COutPoint> reads;
    std::function<void()> on_read;

    bool GetCoin(const COutPoint& outpoint, Coin& coin) const override
    {
        reads.push_back(outpoint);
        if (on_read) on_read();
        const auto it = coins.find(outpoint);
        if (it == coins.end()) return false;
        coin = it->second;
        return true;
    }
    bool HaveCoin(const COutPoint& outpoint) const override
    {
        Coin coin;
        return GetCoin(outpoint, coin);
    }
};

/** Number of maximal ascending runs of the keys, in database key order. */
size_t AscendingRuns(const std::vector<COutPoint>& keys)
{
    size_t runs{keys.empty() ? 0U : 1U};
    for (size_t i = 1; i < keys.size(); ++i) {
        if (ChainstateKeyBytes(keys[i]) < ChainstateKeyBytes(keys[i - 1])) ++runs;
    }
    return runs;
}

COutPoint DerivedKey(const COutPoint& outpoint, uint8_t tag)
{
    HashWriter hasher{};
    hasher << tag << outpoint;
    return COutPoint{hasher.GetSHA256(), 0};
}
} // namespace

BOOST_AUTO_TEST_CASE(read_plan_reads_the_database_in_ascending_sweeps)
{
    // A few thousand outputs. An ordinary one needs its coin. A coinbase one
    // also needs a record under a key derived from its outpoint (present for
    // some), and a record that is present names one more.
    FastRandomContext rng{/*fDeterministic=*/true};
    RecordingCoinsView database;
    struct Item {
        COutPoint outpoint;
        bool exists;
        bool coinbase;
        bool marked;
    };
    std::vector<Item> items;
    for (int i = 0; i < 4000; ++i) {
        Item item{COutPoint{rng.rand256(), static_cast<uint32_t>(i % 5)}, i % 11 != 0, i % 3 == 0, false};
        if (item.exists) {
            database.coins.emplace(item.outpoint, Coin{CTxOut{COIN + i, PayScript(0x44)}, 100 + i, item.coinbase, false, 7});
        }
        items.push_back(item);
    }
    const auto compute = [&](uint32_t index, const CCoinsViewCache& view) {
        // 0: no coin; 1: ordinary; 2: coinbase without a record; 3: record
        // without the one it names; 4: both records.
        const Item& item = items[index];
        Coin coin;
        if (!view.GetCoin(item.outpoint, coin) || coin.IsSpent()) return 0;
        if (!coin.IsCoinBase()) return 1;
        Coin record;
        if (!view.GetCoin(DerivedKey(item.outpoint, 1), record)) return 2;
        Coin named;
        return view.GetCoin(DerivedKey(item.outpoint, 2), named) ? 4 : 3;
    };
    const auto expected = [&](const Item& item, bool second_level) {
        if (!item.exists) return 0;
        if (!item.coinbase) return 1;
        if (!item.marked) return 2;
        return second_level ? 4 : 3;
    };

    for (const bool second_level : {false, true}) {
        // Records of the second sweep; with `second_level` some name a third.
        size_t marked{0};
        for (size_t i = 0; i < items.size(); ++i) {
            Item& item = items[i];
            item.marked = second_level && item.exists && item.coinbase && i % 2 == 0;
            if (item.marked) {
                ++marked;
                database.coins.emplace(DerivedKey(item.outpoint, 1), Coin{CTxOut{0, PayScript(0x55)}, 1, true, false, 0});
                database.coins.emplace(DerivedKey(item.outpoint, 2), Coin{CTxOut{0, PayScript(0x66)}, 1, true, false, 0});
            }
        }
        BOOST_REQUIRE_EQUAL(marked > 0, second_level);
        database.reads.clear();
        CCoinsViewCache coins_tip{&database};

        // An injected clock: a read costs 4 ms, nothing else costs anything.
        auto now = std::chrono::steady_clock::time_point{} + std::chrono::hours{1};
        database.on_read = [&] { now += std::chrono::milliseconds{4}; };
        LifecycleSliceLimits limits;
        limits.now = [&] { return now; };

        ChainReadPlan plan;
        plan.Reset(items.size());
        std::vector<int> results(items.size(), -1);
        std::vector<COutPoint> announced;
        plan.SetOnReadForTest([&](const COutPoint& key) { announced.push_back(key); });
        uint256 tip_hash;
        *tip_hash.begin() = 1;
        int slices{0};
        size_t committed{0};
        OrderedSliceResult result;
        do {
            plan.PrepareUnlocked();
            const size_t reads_before = database.reads.size();
            const size_t committed_before = committed;
            const auto slice_start = now;
            {
                LOCK(::cs_main);
                SliceMeter meter{limits, limits.main_budget};
                result = plan.RunSlice(coins_tip, tip_hash, /*restart_on_tip_move=*/true, meter, compute,
                    [&](uint32_t index, int value) {
                        BOOST_CHECK_EQUAL(results[index], -1); // committed once
                        results[index] = value;
                        ++committed;
                        return true;
                    });
            }
            ++slices;
            BOOST_REQUIRE(result == OrderedSliceResult::MORE || result == OrderedSliceResult::DONE);
            // The slice stays within its budget plus the reads the meter
            // lets it finish, and a slice that reads makes progress.
            const auto held = std::chrono::duration_cast<std::chrono::milliseconds>(now - slice_start);
            BOOST_CHECK_LE(held.count(), limits.main_budget.count() + 4 * static_cast<int64_t>(SliceMeter::MIN_ITEMS_BEFORE_EARLY_END));
            BOOST_CHECK(result == OrderedSliceResult::DONE || database.reads.size() > reads_before ||
                        committed > committed_before || plan.ReadsWaiting() > 0);
            BOOST_REQUIRE_LT(slices, 100000);
        } while (result != OrderedSliceResult::DONE);

        // Many slices, each a few reads long.
        BOOST_CHECK_GT(slices, 500);
        // Every item has the answer direct reads give.
        for (size_t i = 0; i < items.size(); ++i) BOOST_CHECK_EQUAL(results[i], expected(items[i], second_level));
        BOOST_CHECK_EQUAL(plan.Unresolved(), 0U);
        // The database saw exactly the reads the plan announced, each key
        // once: the coin of every item, a record key for every coinbase coin
        // and the key every present record names.
        BOOST_CHECK(database.reads == announced);
        const std::set<COutPoint> distinct{database.reads.begin(), database.reads.end()};
        BOOST_CHECK_EQUAL(distinct.size(), database.reads.size());
        size_t coinbase_coins{0};
        for (const Item& item : items) coinbase_coins += item.exists && item.coinbase ? 1 : 0;
        BOOST_CHECK_EQUAL(database.reads.size(), items.size() + coinbase_coins + marked);
        // And in ascending sweeps: all coins, then all records; a third
        // sweep only for what a record names.
        BOOST_CHECK_EQUAL(AscendingRuns(database.reads), second_level ? 3U : 2U);
        BOOST_CHECK_EQUAL(plan.Sweeps(), second_level ? 3U : 2U);
        for (size_t i = 0; i < items.size(); ++i) BOOST_CHECK(database.reads[i] != DerivedKey(items[i].outpoint, 1));

        if (second_level) {
            // A tip move forgets everything and the plan starts again.
            ChainReadPlan moved;
            moved.Reset(items.size());
            database.reads.clear();
            size_t count{0};
            const auto count_commit = [&](uint32_t, int) { ++count; return true; };
            uint256 other_tip;
            *other_tip.begin() = 2;
            for (int i = 0; i < 20; ++i) {
                moved.PrepareUnlocked();
                LOCK(::cs_main);
                SliceMeter meter{limits, limits.main_budget};
                BOOST_REQUIRE(moved.RunSlice(coins_tip, tip_hash, true, meter, compute, count_commit) == OrderedSliceResult::MORE);
            }
            BOOST_CHECK_GT(database.reads.size(), 0U);
            {
                LOCK(::cs_main);
                SliceMeter meter{limits, limits.main_budget};
                BOOST_CHECK(moved.RunSlice(coins_tip, other_tip, true, meter, compute, count_commit) == OrderedSliceResult::RESTARTED);
            }
            BOOST_CHECK_EQUAL(moved.Restarts(), 1U);
            BOOST_CHECK_EQUAL(moved.Unresolved(), items.size());
            database.reads.clear();
            count = 0;
            do {
                moved.PrepareUnlocked();
                LOCK(::cs_main);
                SliceMeter meter{LifecycleSliceLimits::Unlimited(), std::chrono::milliseconds{0}};
                result = moved.RunSlice(coins_tip, other_tip, true, meter, compute, count_commit);
            } while (result == OrderedSliceResult::MORE);
            BOOST_CHECK(result == OrderedSliceResult::DONE);
            BOOST_CHECK_EQUAL(count, items.size());
            BOOST_CHECK_EQUAL(AscendingRuns(database.reads), 3U);
        }
    }
}

BOOST_FIXTURE_TEST_CASE(wallet_pass_and_warmup_read_the_chainstate_in_two_ascending_sweeps, CoinFactsChainSetup)
{
    std::unique_ptr<CWallet> wallet{CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()),
        coinbaseKey)};
    const CScript wallet_script = GetScriptForRawPubKey(coinbaseKey.GetPubKey());

    // A few thousand wallet outputs: ordinary ones from one large
    // transaction, and the coinbase of every block.
    CMutableTransaction fan = CreateValidMempoolTransaction(
        m_coinbase_txns[0], /*input_vout=*/0, /*input_height=*/1, coinbaseKey, wallet_script,
        m_coinbase_txns[0]->vout[0].nValue - COIN, /*submit=*/false);
    {
        const int ordinary{3000};
        const CAmount each = fan.vout[0].nValue / ordinary;
        fan.vout.assign(ordinary, CTxOut{each, wallet_script});
        // Signed again, as the fixture signs: the outputs changed.
        fan.vin[0].scriptSig.clear();
        FillableSigningProvider keystore;
        keystore.AddKey(coinbaseKey);
        const CTxOut& spent = m_coinbase_txns[0]->vout[0];
        int hash_type = SIGHASH_ALL;
        {
            LOCK(::cs_main);
            const CBlockIndex* tip{m_node.chainman->ActiveChain().Tip()};
            if (IsQuantumWitnessSpendActive(Params().GetConsensus(), tip->GetMedianTimePast(), tip->nHeight + 1)) {
                hash_type |= SIGHASH_FORKID;
            }
        }
        const CTransaction fan_const{fan};
        PrecomputedTransactionData txdata;
        txdata.Init(fan_const, std::vector<CTxOut>{spent}, true);
        SignatureData sigdata = DataFromTransaction(fan, 0, spent);
        BOOST_REQUIRE(ProduceSignature(keystore, MutableTransactionSignatureCreator{fan, 0, spent.nValue, &txdata, hash_type},
                                       spent.scriptPubKey, sigdata));
        UpdateInput(fan.vin[0], sigdata);
    }
    Notify(*wallet, Mine({fan}));
    BOOST_REQUIRE(WITH_LOCK(wallet->cs_wallet, return wallet->GetWalletTx(fan.GetHash()) != nullptr));
    for (int i = 0; i < 260; ++i) Notify(*wallet, Mine());

    Balance reference_balance;
    WalletLifecycleSummary reference_summary;
    WalletLifecycleScanStats reference_stats;
    {
        WalletLifecycleOptions options;
        options.stats = &reference_stats;
        std::string error;
        LOCK2(::cs_main, wallet->cs_wallet);
        BOOST_REQUIRE_MESSAGE(GetLifecycleAdjustedBalance(*wallet, 0, true, reference_balance, reference_summary, error, options), error);
    }
    BOOST_REQUIRE_GT(reference_stats.outputs, 3300U);

    // An injected clock: a chainstate read costs 5 ms.
    auto now = std::chrono::steady_clock::time_point{} + std::chrono::hours{1};
    LifecycleSliceLimits limits;
    limits.now = [&] { return now; };
    const int64_t main_bound = limits.main_budget.count() + 5 * static_cast<int64_t>(SliceMeter::MIN_ITEMS_BEFORE_EARLY_END);

    // The display pass on a wallet whose memo is empty.
    {
        LifecycleMemoJournal journal;
        LifecycleAttestationCache attestations;
        LifecyclePass pass;
        std::vector<COutPoint> reads;
        pass.chain_plan.SetOnReadForTest([&](const COutPoint& key) {
            reads.push_back(key);
            now += std::chrono::milliseconds{5};
        });
        int main_slices{0};
        for (;;) {
            const LifecycleSliceReport report = RunLifecyclePassSlice(*wallet, pass, journal, attestations, limits);
            BOOST_REQUIRE(report.result != LifecycleSliceResult::LOCK_BUSY);
            if (report.held_main) {
                ++main_slices;
                BOOST_CHECK_LE(report.held.count() / 1000, main_bound);
            }
            if (report.result == LifecycleSliceResult::MORE) continue;
            BOOST_REQUIRE_MESSAGE(report.result == LifecycleSliceResult::DONE, report.error);
            break;
        }
        BOOST_CHECK_EQUAL(pass.balance.m_mine_trusted, reference_balance.m_mine_trusted);
        BOOST_CHECK_EQUAL(pass.balance.m_mine_immature, reference_balance.m_mine_immature);
        BOOST_CHECK(pass.summary.mine.outputs == reference_summary.mine.outputs);
        BOOST_CHECK(pass.summary.mine.nominal == reference_summary.mine.nominal);
        BOOST_CHECK(pass.summary.mine.effective == reference_summary.mine.effective);
        BOOST_CHECK_EQUAL(pass.stats.outputs, reference_stats.outputs);
        // The ordinary outputs cost no read; every coinbase output costs its
        // coin and the key of its payout record, which is not there.
        BOOST_CHECK_EQUAL(pass.stats.derived, 3000U);
        BOOST_CHECK_EQUAL(pass.stats.database_reads, pass.stats.outputs - 3000U);
        BOOST_CHECK_EQUAL(reads.size(), 2 * pass.stats.database_reads);
        const std::set<COutPoint> distinct{reads.begin(), reads.end()};
        BOOST_CHECK_EQUAL(distinct.size(), reads.size());
        // First every coin, then every record: two ascending sweeps.
        BOOST_CHECK_EQUAL(AscendingRuns(reads), 2U);
        const std::vector<COutPoint> coin_sweep{reads.begin(), reads.begin() + static_cast<std::ptrdiff_t>(pass.stats.database_reads)};
        BOOST_CHECK_EQUAL(AscendingRuns(coin_sweep), 1U);
        for (const COutPoint& key : coin_sweep) {
            BOOST_CHECK(WITH_LOCK(wallet->cs_wallet, return wallet->GetWalletTx(key.hash) != nullptr));
        }
        BOOST_CHECK_GT(main_slices, 20);
    }

    // The memo warm-up of the whole wallet: the same two sweeps, not two per
    // batch of outputs.
    {
        WITH_LOCK(wallet->cs_wallet, wallet->ClearOutputLifecycleMemo());
        LifecycleWarmup warmup;
        LifecycleMemoJournal journal;
        std::vector<COutPoint> reads;
        warmup.fetch_plan.SetOnReadForTest([&](const COutPoint& key) {
            reads.push_back(key);
            now += std::chrono::milliseconds{5};
        });
        for (int i = 0; i < 1000000; ++i) {
            const LifecycleSliceReport report = RunLifecycleWarmupSlice(*wallet, warmup, journal, limits);
            BOOST_REQUIRE(report.result != LifecycleSliceResult::LOCK_BUSY);
            if (report.held_main) BOOST_CHECK_LE(report.held.count() / 1000, main_bound);
            if (report.result == LifecycleSliceResult::DONE) break;
        }
        BOOST_REQUIRE(warmup.stage == LifecycleWarmup::Stage::DONE);
        BOOST_CHECK_EQUAL(warmup.derived, 3000U);
        BOOST_CHECK_GT(warmup.fetched, warmup.derived + 150);
        BOOST_CHECK_EQUAL(warmup.skipped, 0U);
        BOOST_CHECK_EQUAL(reads.size(), 2 * (warmup.fetched - warmup.derived));
        BOOST_CHECK_EQUAL(AscendingRuns(reads), 2U);
        BOOST_CHECK_EQUAL(WITH_LOCK(wallet->cs_wallet, return wallet->m_output_lifecycle_memo.size()), warmup.fetched);

        // What the warm-up stored is what a pass computes the balance from.
        LifecycleAttestationCache attestations;
        LifecyclePass pass;
        const LifecycleSliceReport report = RunLifecyclePassToEnd(*wallet, pass, journal, attestations);
        BOOST_REQUIRE_MESSAGE(report.result == LifecycleSliceResult::DONE, report.error);
        BOOST_CHECK_EQUAL(pass.balance.m_mine_trusted, reference_balance.m_mine_trusted);
        BOOST_CHECK_EQUAL(pass.balance.m_mine_immature, reference_balance.m_mine_immature);
        BOOST_CHECK(pass.summary.mine.nominal == reference_summary.mine.nominal);
        BOOST_CHECK_GE(pass.stats.memo_hits, warmup.fetched - 16);
    }
}

BOOST_AUTO_TEST_SUITE_END()
} // namespace wallet
