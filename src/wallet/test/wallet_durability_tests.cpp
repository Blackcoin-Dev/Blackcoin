// Copyright (c) 2026 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <chain.h>
#include <interfaces/chain.h>
#include <key_io.h>
#include <random.h>
#include <script/descriptor.h>
#include <script/script.h>
#include <test/util/logging.h>
#include <test/util/random.h>
#include <test/util/setup_common.h>
#include <util/check.h>
#include <validation.h>
#include <wallet/scheduler_stats.h>
#include <wallet/scriptpubkeyman.h>
#include <wallet/sqlite.h>
#include <wallet/test/util.h>
#include <wallet/wallet.h>
#include <wallet/walletdb.h>

#include <boost/test/unit_test.hpp>

#include <future>
#include <optional>
#include <thread>

#include <sqlite3.h>

namespace wallet {
namespace {

#ifdef USE_SQLITE
std::shared_ptr<CWallet> LoadSqliteWallet(const std::string& name, interfaces::Chain* chain)
{
    DatabaseOptions options;
    options.require_format = DatabaseFormat::SQLITE;
    DatabaseStatus status;
    bilingual_str error;
    auto database{MakeWalletDatabase(name, options, status, error)};
    BOOST_REQUIRE_MESSAGE(database, error.original);
    auto wallet{std::make_shared<CWallet>(chain, "", std::move(database))};
    BOOST_REQUIRE_EQUAL(wallet->LoadWallet(), DBErrors::LOAD_OK);
    return wallet;
}

sqlite3* RawDb(CWallet& wallet)
{
    return static_cast<SQLiteDatabase&>(wallet.GetDatabase()).m_db;
}

struct CommitCounter {
    sqlite3* db;
    int commits{0};
    explicit CommitCounter(sqlite3* db_in) : db{db_in}
    {
        sqlite3_commit_hook(db, [](void* arg) -> int { ++*static_cast<int*>(arg); return 0; }, &commits);
    }
    ~CommitCounter() { sqlite3_commit_hook(db, nullptr, nullptr); }
};
#endif

} // namespace

BOOST_AUTO_TEST_SUITE(wallet_durability_tests)

BOOST_AUTO_TEST_CASE(latency_buckets)
{
    using std::chrono::microseconds;
    using namespace std::chrono_literals;
    BOOST_CHECK_EQUAL(LatencyBucket(0us), 0U);
    BOOST_CHECK_EQUAL(LatencyBucket(9999us), 0U);
    BOOST_CHECK_EQUAL(LatencyBucket(10ms), 1U);
    BOOST_CHECK_EQUAL(LatencyBucket(99ms), 1U);
    BOOST_CHECK_EQUAL(LatencyBucket(100ms), 2U);
    BOOST_CHECK_EQUAL(LatencyBucket(999ms), 2U);
    BOOST_CHECK_EQUAL(LatencyBucket(1s), 3U);
    BOOST_CHECK_EQUAL(LatencyBucket(9999ms), 3U);
    BOOST_CHECK_EQUAL(LatencyBucket(10s), 4U);
    BOOST_CHECK_EQUAL(LatencyBucket(1h), 4U);
}

BOOST_AUTO_TEST_CASE(scheduler_stats_records_wait_and_hold)
{
    using namespace std::chrono_literals;
    SchedulerStats& stats = SchedulerStats::Instance();
    stats.Reset();
    stats.Record(WalletCallbackKind::BLOCK_CONNECTED, 5ms, 50ms);
    stats.Record(WalletCallbackKind::BLOCK_CONNECTED, 2s, 20ms);
    const CallbackLatencySnapshot s = stats.Snapshot(WalletCallbackKind::BLOCK_CONNECTED);
    BOOST_CHECK_EQUAL(s.count, 2U);
    BOOST_CHECK_EQUAL(s.wait_total_us, 2005000U);
    BOOST_CHECK_EQUAL(s.wait_max_us, 2000000U);
    BOOST_CHECK_EQUAL(s.hold_total_us, 70000U);
    BOOST_CHECK_EQUAL(s.hold_max_us, 50000U);
    BOOST_CHECK_EQUAL(s.wait_histogram[0], 1U);
    BOOST_CHECK_EQUAL(s.wait_histogram[3], 1U);
    BOOST_CHECK_EQUAL(s.hold_histogram[1], 2U);
    BOOST_CHECK_EQUAL(stats.Snapshot(WalletCallbackKind::MEMPOOL_ADDED).count, 0U);
    BOOST_CHECK(stats.FormatSummary().find("connected n=2") != std::string::npos);
    stats.Reset();
}

BOOST_AUTO_TEST_CASE(sqlite_commit_counters_accumulate_and_drain)
{
    using namespace std::chrono_literals;
    SqliteCommitCounters counters;
    counters.Record(SqliteCommitKind::DURABLE, 30ms);
    counters.Record(SqliteCommitKind::DURABLE, 10ms);
    counters.Record(SqliteCommitKind::AUTOCOMMIT, 1ms);
    const SqliteCommitSnapshot peek = counters.Snapshot();
    BOOST_CHECK_EQUAL(peek[static_cast<size_t>(SqliteCommitKind::DURABLE)].count, 2U);
    BOOST_CHECK_EQUAL(peek[static_cast<size_t>(SqliteCommitKind::DURABLE)].total_us, 40000U);
    BOOST_CHECK_EQUAL(peek[static_cast<size_t>(SqliteCommitKind::DURABLE)].max_us, 30000U);
    BOOST_CHECK_EQUAL(peek[static_cast<size_t>(SqliteCommitKind::NON_DURABLE)].count, 0U);

    // Take reads and zeroes: the next line covers only what came after.
    const SqliteCommitSnapshot taken = counters.Take();
    const std::string line = FormatSqliteCommits(taken);
    BOOST_CHECK(line.find("n=3 total=41 ms max=30 ms") != std::string::npos);
    BOOST_CHECK(line.find("durable=2/40/30") != std::string::npos);
    BOOST_CHECK(line.find("autocommit=1/1/1") != std::string::npos);
    BOOST_CHECK(line.find("non_durable") == std::string::npos);
    BOOST_CHECK(FormatSqliteCommits(counters.Take()).find("n=0 total=0 ms max=0 ms") != std::string::npos);
}

BOOST_FIXTURE_TEST_CASE(summary_line_carries_the_sqlite_commits_since_the_last_line, BasicTestingSetup)
{
    using namespace std::chrono_literals;
    SchedulerStats& stats = SchedulerStats::Instance();
    stats.Reset();
    ProcessSqliteCommits().Reset();
    ProcessSqliteCommits().Record(SqliteCommitKind::BULK_SCOPE, 5ms);
    {
        ASSERT_DEBUG_LOG("sqlite commits since last line: n=1 total=5 ms max=5 ms");
        stats.MaybeLogSummary(std::chrono::steady_clock::now());
    }
    // The line drained the counters.
    BOOST_CHECK_EQUAL(ProcessSqliteCommits().Snapshot()[static_cast<size_t>(SqliteCommitKind::BULK_SCOPE)].count, 0U);
    stats.Reset();
}

BOOST_AUTO_TEST_CASE(nested_handler_is_not_counted_twice)
{
    SchedulerStats& stats = SchedulerStats::Instance();
    stats.Reset();
    {
        WalletCallbackTimer outer{WalletCallbackKind::BLOCK_CONNECTED};
        outer.LockAcquired();
        {
            // The block handler calls the mempool-removal handler for each transaction.
            WalletCallbackTimer inner{WalletCallbackKind::MEMPOOL_REMOVED};
            inner.LockAcquired();
        }
    }
    BOOST_CHECK_EQUAL(stats.Snapshot(WalletCallbackKind::BLOCK_CONNECTED).count, 1U);
    BOOST_CHECK_EQUAL(stats.Snapshot(WalletCallbackKind::MEMPOOL_REMOVED).count, 0U);
    {
        WalletCallbackTimer alone{WalletCallbackKind::MEMPOOL_REMOVED};
        alone.LockAcquired();
    }
    BOOST_CHECK_EQUAL(stats.Snapshot(WalletCallbackKind::MEMPOOL_REMOVED).count, 1U);
    stats.Reset();
}

BOOST_AUTO_TEST_CASE(summary_is_rate_limited)
{
    SchedulerStats& stats = SchedulerStats::Instance();
    stats.Reset();
    SetValidationQueueDepthProvider([] { return size_t{7}; });
    BOOST_CHECK_EQUAL(GetValidationQueueDepth().value_or(0), 7U);
    BOOST_CHECK(stats.FormatSummary().find("queue=7") != std::string::npos);
    SetValidationQueueDepthProvider(nullptr);
    BOOST_CHECK(!GetValidationQueueDepth());
    const auto process_memory = GetProcessMemory();
#if defined(__APPLE__) || defined(__linux__)
    BOOST_REQUIRE(process_memory);
    BOOST_CHECK_GT(process_memory->resident_bytes, 0U);
    BOOST_CHECK(FormatProcessMemory(*process_memory).find("resident=") != std::string::npos);
#endif
    stats.Reset();
}

#ifdef USE_SQLITE
BOOST_FIXTURE_TEST_CASE(topup_without_change_writes_and_announces_nothing, BasicTestingSetup)
{
    auto wallet = LoadSqliteWallet("topup-noop", nullptr);
    DescriptorScriptPubKeyMan* spkm{nullptr};
    {
        LOCK(wallet->cs_wallet);
        wallet->SetWalletFlag(WALLET_FLAG_DESCRIPTORS);
        wallet->SetupDescriptorScriptPubKeyMans();
        spkm = dynamic_cast<DescriptorScriptPubKeyMan*>(wallet->GetScriptPubKeyMan(OutputType::BECH32, /*internal=*/false));
    }
    BOOST_REQUIRE(spkm);
    int announcements{0};
    auto connection = spkm->NotifyCanGetAddressesChanged.connect([&] { ++announcements; });

    // The keypool is full after setup: another top up has nothing to do.
    {
        CommitCounter counter{RawDb(*wallet)};
        BOOST_CHECK(spkm->TopUp());
        BOOST_CHECK(spkm->TopUp());
        BOOST_CHECK_EQUAL(counter.commits, 0);
        BOOST_CHECK_EQUAL(announcements, 0);
    }

    // Every own output of every transaction calls MarkUnusedAddresses. A script
    // that is already behind next_index changes nothing.
    auto used = spkm->GetNewDestination(OutputType::BECH32);
    BOOST_REQUIRE(used);
    const CScript used_script = GetScriptForDestination(*used);
    BOOST_CHECK(spkm->TopUp()); // settle the range after the address was handed out
    announcements = 0;
    {
        CommitCounter counter{RawDb(*wallet)};
        for (int i = 0; i < 5; ++i) BOOST_CHECK(spkm->MarkUnusedAddresses(used_script).empty());
        BOOST_CHECK_EQUAL(counter.commits, 0);
        BOOST_CHECK_EQUAL(announcements, 0);
    }

    // A script ahead of next_index advances next_index; that must still reach the database.
    int32_t next_index_before{0};
    {
        LOCK(spkm->cs_desc_man);
        next_index_before = spkm->GetWalletDescriptor().next_index;
    }
    const auto ahead = spkm->GetScriptPubKeys(next_index_before + 3);
    BOOST_REQUIRE(!ahead.empty());
    CScript future_script;
    {
        // Pick the one with the lowest index: the first by repeated probing.
        for (int32_t i = next_index_before + 3; i < next_index_before + 10; ++i) {
            const auto at_or_above = spkm->GetScriptPubKeys(i);
            const auto next = spkm->GetScriptPubKeys(i + 1);
            if (at_or_above.size() == next.size() + 1) {
                for (const CScript& s : at_or_above) {
                    if (!next.count(s)) future_script = s;
                }
                break;
            }
        }
    }
    BOOST_REQUIRE(!future_script.empty());
    {
        CommitCounter counter{RawDb(*wallet)};
        const auto marked = spkm->MarkUnusedAddresses(future_script);
        BOOST_CHECK(!marked.empty());
        BOOST_CHECK_GT(counter.commits, 0);
        BOOST_CHECK_GT(announcements, 0);
    }
    int32_t next_index_after{0};
    {
        LOCK(spkm->cs_desc_man);
        next_index_after = spkm->GetWalletDescriptor().next_index;
    }
    BOOST_CHECK_GT(next_index_after, next_index_before);
    connection.disconnect();

    // The advanced next_index was persisted by that call and survives a reload.
    spkm = nullptr;
    wallet.reset();
    wallet = LoadSqliteWallet("topup-noop", nullptr);
    {
        LOCK(wallet->cs_wallet);
        auto* reloaded = dynamic_cast<DescriptorScriptPubKeyMan*>(wallet->GetScriptPubKeyMan(OutputType::BECH32, /*internal=*/false));
        BOOST_REQUIRE(reloaded);
        LOCK(reloaded->cs_desc_man);
        BOOST_CHECK_EQUAL(reloaded->GetWalletDescriptor().next_index, next_index_after);
    }

    // A real change (a larger keypool) still writes and announces.
    {
        LOCK(wallet->cs_wallet);
        auto* active = dynamic_cast<DescriptorScriptPubKeyMan*>(wallet->GetScriptPubKeyMan(OutputType::BECH32, /*internal=*/false));
        BOOST_REQUIRE(active);
        CommitCounter counter{RawDb(*wallet)};
        BOOST_CHECK(active->TopUp(2000));
        BOOST_CHECK_GT(counter.commits, 0);
    }
}

//! A block of the test chain with the BlockInfo the wallet callbacks take.
struct ConnectedBlock {
    CBlock block;
    uint256 hash;
    uint256 prev_hash;
    int height;
    interfaces::BlockInfo Info() const
    {
        interfaces::BlockInfo info{hash};
        info.prev_hash = &prev_hash;
        info.height = height;
        info.data = &block;
        info.chain_time_max = block.GetBlockTime();
        return info;
    }
};

ConnectedBlock MineBlock(TestChain100Setup& setup)
{
    ConnectedBlock out;
    out.block = setup.CreateAndProcessBlock({}, GetScriptForRawPubKey(setup.coinbaseKey.GetPubKey()));
    out.hash = out.block.GetHash();
    out.prev_hash = out.block.hashPrevBlock;
    out.height = WITH_LOCK(Assert(setup.m_node.chainman)->GetMutex(), return Assert(setup.m_node.chainman)->ActiveChain().Height());
    return out;
}

std::optional<uint256> StoredBestBlock(CWallet& wallet)
{
    CBlockLocator stored;
    if (!WalletBatch{wallet.GetDatabase()}.ReadBestBlock(stored) || stored.vHave.empty()) return std::nullopt;
    return stored.vHave.front();
}

BOOST_FIXTURE_TEST_CASE(connected_block_persists_best_block_in_its_commit, TestChain100Setup)
{
    // A block that writes a wallet record moves the best block with the
    // block's own writes: one commit, and the stored locator leads with the
    // block just connected.
    auto wallet = LoadSqliteWallet("best-block-per-block", m_node.chain.get());
    {
        LOCK(wallet->cs_wallet);
        wallet->SetWalletFlag(WALLET_FLAG_DESCRIPTORS);
        FlatSigningProvider provider;
        std::string error;
        std::unique_ptr<Descriptor> desc = Parse("combo(" + EncodeSecret(coinbaseKey) + ")", provider, error, /*require_checksum=*/false);
        BOOST_REQUIRE(desc);
        WalletDescriptor w_desc(std::move(desc), 0, 0, 1, 1);
        BOOST_REQUIRE(wallet->AddWalletDescriptor(w_desc, provider, "", false));
    }
    for (int i = 0; i < 3; ++i) {
        const ConnectedBlock connected{MineBlock(*this)};
        const size_t txs_before{WITH_LOCK(wallet->cs_wallet, return wallet->mapWallet.size())};
        {
            CommitCounter counter{RawDb(*wallet)};
            wallet->blockConnected(ChainstateRole::NORMAL, connected.Info());
            BOOST_CHECK_EQUAL(counter.commits, 1);
        }
        BOOST_CHECK_EQUAL(WITH_LOCK(wallet->cs_wallet, return wallet->mapWallet.size()), txs_before + 1);
        CBlockLocator stored;
        BOOST_REQUIRE(WalletBatch{wallet->GetDatabase()}.ReadBestBlock(stored));
        BOOST_REQUIRE(!stored.vHave.empty());
        BOOST_CHECK(stored.vHave.front() == connected.hash);
        BOOST_CHECK(m_node.chain->findLocatorFork(stored) == connected.height);
    }
    // Nothing is left to write when the wallet is flushed.
    CommitCounter counter{RawDb(*wallet)};
    wallet->Flush();
    BOOST_CHECK_EQUAL(counter.commits, 0);
}

BOOST_FIXTURE_TEST_CASE(block_without_wallet_records_defers_the_best_block, TestChain100Setup)
{
    // The wallet holds no key, so no block writes a record.
    auto wallet = LoadSqliteWallet("best-block-deferred", m_node.chain.get());
    const auto bulk_commits = [&] {
        return static_cast<SQLiteDatabase&>(wallet->GetDatabase()).CommitCounters().Snapshot()[static_cast<size_t>(SqliteCommitKind::BULK_SCOPE)].count;
    };
    const uint64_t bulk_before{bulk_commits()};

    // Blocks are deferred up to the bound: no commit, and nothing stored.
    ConnectedBlock last;
    for (int i = 0; i < CWallet::MAX_DEFERRED_BEST_BLOCKS; ++i) {
        last = MineBlock(*this);
        CommitCounter counter{RawDb(*wallet)};
        wallet->blockConnected(ChainstateRole::NORMAL, last.Info());
        BOOST_CHECK_EQUAL(counter.commits, 0);
    }
    BOOST_CHECK(!StoredBestBlock(*wallet));
    BOOST_CHECK_EQUAL(bulk_commits(), bulk_before);

    // The next block is past the bound and writes its own best block.
    last = MineBlock(*this);
    {
        CommitCounter counter{RawDb(*wallet)};
        wallet->blockConnected(ChainstateRole::NORMAL, last.Info());
        BOOST_CHECK_EQUAL(counter.commits, 1);
    }
    BOOST_CHECK(StoredBestBlock(*wallet) == last.hash);
    BOOST_CHECK_EQUAL(bulk_commits(), bulk_before + 1);
    const ConnectedBlock persisted{last};

    // Deferral starts over, and a flush writes the deferred best block.
    for (int i = 0; i < 3; ++i) {
        last = MineBlock(*this);
        CommitCounter counter{RawDb(*wallet)};
        wallet->blockConnected(ChainstateRole::NORMAL, last.Info());
        BOOST_CHECK_EQUAL(counter.commits, 0);
    }
    BOOST_CHECK(StoredBestBlock(*wallet) == persisted.hash);
    {
        CommitCounter counter{RawDb(*wallet)};
        wallet->Flush();
        BOOST_CHECK_EQUAL(counter.commits, 1);
        BOOST_CHECK(StoredBestBlock(*wallet) == last.hash);
        wallet->Flush();
        BOOST_CHECK_EQUAL(counter.commits, 1);
    }

    // Ten minutes after the last write the next block is written at once.
    last = MineBlock(*this);
    wallet->blockConnected(ChainstateRole::NORMAL, last.Info());
    BOOST_CHECK(StoredBestBlock(*wallet) != last.hash);
    SetMockTime(GetTime<std::chrono::seconds>() + CWallet::MAX_BEST_BLOCK_DEFERRAL + std::chrono::seconds{1});
    last = MineBlock(*this);
    {
        CommitCounter counter{RawDb(*wallet)};
        wallet->blockConnected(ChainstateRole::NORMAL, last.Info());
        BOOST_CHECK_EQUAL(counter.commits, 1);
    }
    BOOST_CHECK(StoredBestBlock(*wallet) == last.hash);

    // A chainstate flush writes the best block, so nothing stays deferred.
    last = MineBlock(*this);
    wallet->blockConnected(ChainstateRole::NORMAL, last.Info());
    BOOST_CHECK(StoredBestBlock(*wallet) != last.hash);
    wallet->chainStateFlushed(ChainstateRole::NORMAL, m_node.chain->getTipLocator());
    BOOST_CHECK(StoredBestBlock(*wallet) == last.hash);
    {
        CommitCounter counter{RawDb(*wallet)};
        wallet->Flush();
        BOOST_CHECK_EQUAL(counter.commits, 0);
    }

    // A wallet that goes away without a flush (a crash) keeps the older
    // stored best block and resumes at most the deferred blocks behind.
    const ConnectedBlock flushed{last};
    for (int i = 0; i < 5; ++i) {
        last = MineBlock(*this);
        wallet->blockConnected(ChainstateRole::NORMAL, last.Info());
    }
    wallet.reset();
    wallet = LoadSqliteWallet("best-block-deferred", m_node.chain.get());
    CBlockLocator stored;
    BOOST_REQUIRE(WalletBatch{wallet->GetDatabase()}.ReadBestBlock(stored));
    BOOST_REQUIRE(!stored.vHave.empty());
    BOOST_CHECK(stored.vHave.front() == flushed.hash);
    const std::optional<int> fork{m_node.chain->findLocatorFork(stored)};
    BOOST_REQUIRE(fork);
    BOOST_CHECK_EQUAL(*fork, flushed.height);
    BOOST_CHECK_LE(last.height - *fork, CWallet::MAX_DEFERRED_BEST_BLOCKS);
}

BOOST_FIXTURE_TEST_CASE(disconnected_block_drops_its_deferred_best_block, TestChain100Setup)
{
    auto wallet = LoadSqliteWallet("best-block-disconnect", m_node.chain.get());
    const ConnectedBlock first{MineBlock(*this)};
    wallet->blockConnected(ChainstateRole::NORMAL, first.Info());
    wallet->Flush();
    BOOST_CHECK(StoredBestBlock(*wallet) == first.hash);

    const ConnectedBlock second{MineBlock(*this)};
    wallet->blockConnected(ChainstateRole::NORMAL, second.Info());
    wallet->blockDisconnected(second.Info());
    // The disconnected block is never recorded as the best block.
    wallet->Flush();
    BOOST_CHECK(StoredBestBlock(*wallet) == first.hash);
}

BOOST_FIXTURE_TEST_CASE(commit_transaction_is_one_commit, TestChain100Setup)
{
    auto wallet = LoadSqliteWallet("commit-transaction-once", m_node.chain.get());
    const CBlockIndex* funding_block = WITH_LOCK(::cs_main, return Assert(m_node.chainman)->ActiveChain()[1]);
    const CTransactionRef funding{m_coinbase_txns[0]};
    BOOST_REQUIRE(wallet->AddToWallet(funding, TxStateConfirmed{funding_block->GetBlockHash(), funding_block->nHeight, /*index=*/0}));

    CMutableTransaction spend;
    spend.vin.emplace_back(COutPoint{funding->GetHash(), 0});
    spend.vout.emplace_back(funding->vout[0].nValue - 10000, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));
    const CTransactionRef tx{MakeTransactionRef(spend)};

    const auto& counters = static_cast<SQLiteDatabase&>(wallet->GetDatabase()).CommitCounters();
    const SqliteCommitSnapshot before{counters.Snapshot()};
    BOOST_REQUIRE(!wallet->GetBroadcastTransactions());
    {
        // The order position and the transaction record are separate rows.
        CommitCounter counter{RawDb(*wallet)};
        BOOST_CHECK(wallet->CommitTransaction(tx, {}, {}));
        BOOST_CHECK_EQUAL(counter.commits, 1);
    }
    const SqliteCommitSnapshot after{counters.Snapshot()};
    const auto delta = [&](SqliteCommitKind kind) {
        return after[static_cast<size_t>(kind)].count - before[static_cast<size_t>(kind)].count;
    };
    BOOST_CHECK_EQUAL(delta(SqliteCommitKind::BULK_SCOPE), 1U);
    BOOST_CHECK_EQUAL(delta(SqliteCommitKind::AUTOCOMMIT), 0U);
    BOOST_CHECK_EQUAL(delta(SqliteCommitKind::DURABLE), 0U);
    BOOST_CHECK_EQUAL(delta(SqliteCommitKind::NON_DURABLE), 0U);

    // Both rows are on disk: the record and the order position survive a reload.
    const int64_t order_pos{WITH_LOCK(wallet->cs_wallet, return wallet->mapWallet.at(tx->GetHash()).nOrderPos)};
    wallet.reset();
    wallet = LoadSqliteWallet("commit-transaction-once", m_node.chain.get());
    LOCK(wallet->cs_wallet);
    const auto reloaded = wallet->mapWallet.find(tx->GetHash());
    BOOST_REQUIRE(reloaded != wallet->mapWallet.end());
    BOOST_CHECK_EQUAL(reloaded->second.nOrderPos, order_pos);
    BOOST_CHECK(reloaded->second.fFromMe);
    BOOST_CHECK_GT(wallet->nOrderPosNext, order_pos);
}

BOOST_FIXTURE_TEST_CASE(entering_the_mempool_rewrites_no_record, TestChain100Setup)
{
    auto wallet = LoadSqliteWallet("mempool-entry-no-write", m_node.chain.get());
    CMutableTransaction mtx;
    mtx.vin.emplace_back(COutPoint{Txid::FromUint256(GetRandHash()), 0});
    mtx.vout.emplace_back(50000, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));
    const CTransactionRef tx{MakeTransactionRef(mtx)};
    const uint256 hash{tx->GetHash()};
    BOOST_REQUIRE(wallet->AddToWallet(tx, TxStateInactive{}));

    int notifications{0};
    ChangeType last_change{CT_NEW};
    auto connection = wallet->NotifyTransactionChanged.connect([&](const uint256& changed, ChangeType change) {
        if (changed == hash) {
            ++notifications;
            last_change = change;
        }
    });

    // Inactive to InMempool: the stored record is byte for byte the same, so
    // no row is written, and the wallet still announces the change.
    {
        const unsigned int updates_before{wallet->GetDatabase().nUpdateCounter.load()};
        CommitCounter counter{RawDb(*wallet)};
        const CWalletTx* wtx{wallet->AddToWallet(tx, TxStateInMempool{})};
        BOOST_REQUIRE(wtx);
        BOOST_CHECK(wtx->InMempool());
        BOOST_CHECK_EQUAL(counter.commits, 0);
        BOOST_CHECK_EQUAL(wallet->GetDatabase().nUpdateCounter.load(), updates_before);
        BOOST_CHECK_EQUAL(notifications, 1);
        BOOST_CHECK(last_change == CT_UPDATED);
    }
    const auto [order_pos, time_received] = WITH_LOCK(wallet->cs_wallet, return std::make_pair(wallet->mapWallet.at(hash).nOrderPos, wallet->mapWallet.at(hash).nTimeReceived));

    // A reload gives the state that record always had on disk.
    connection.disconnect();
    wallet.reset();
    wallet = LoadSqliteWallet("mempool-entry-no-write", m_node.chain.get());
    {
        LOCK(wallet->cs_wallet);
        const auto reloaded = wallet->mapWallet.find(hash);
        BOOST_REQUIRE(reloaded != wallet->mapWallet.end());
        const auto* inactive = reloaded->second.state<TxStateInactive>();
        BOOST_REQUIRE(inactive);
        BOOST_CHECK(!inactive->abandoned);
        BOOST_CHECK_EQUAL(reloaded->second.nOrderPos, order_pos);
        BOOST_CHECK_EQUAL(reloaded->second.nTimeReceived, time_received);
        BOOST_CHECK(reloaded->second.mapValue.count("note") == 0);
    }

    // An update function that changes the record makes the same transition write it.
    {
        CommitCounter counter{RawDb(*wallet)};
        BOOST_REQUIRE(wallet->AddToWallet(tx, TxStateInMempool{}, [](CWalletTx& wtx, bool) {
            wtx.mapValue["note"] = "kept";
            return true;
        }));
        BOOST_CHECK_EQUAL(counter.commits, 1);
    }
    // Leaving the mempool, and an abandoned record entering it, are written as before.
    {
        CommitCounter counter{RawDb(*wallet)};
        BOOST_REQUIRE(wallet->AddToWallet(tx, TxStateInactive{/*abandoned=*/true}));
        BOOST_CHECK_EQUAL(counter.commits, 1);
        BOOST_REQUIRE(wallet->AddToWallet(tx, TxStateInMempool{}));
        BOOST_CHECK_EQUAL(counter.commits, 2);
    }
    wallet.reset();
    wallet = LoadSqliteWallet("mempool-entry-no-write", m_node.chain.get());
    LOCK(wallet->cs_wallet);
    const auto reloaded = wallet->mapWallet.find(hash);
    BOOST_REQUIRE(reloaded != wallet->mapWallet.end());
    const auto* inactive = reloaded->second.state<TxStateInactive>();
    BOOST_REQUIRE(inactive);
    BOOST_CHECK(!inactive->abandoned);
    BOOST_CHECK_EQUAL(reloaded->second.mapValue.at("note"), "kept");
}
#endif

BOOST_FIXTURE_TEST_CASE(dense_locator_resumes_within_a_few_blocks, TestChain100Setup)
{
    // Mine a chain long enough for every step size, then pretend the node
    // lost the newest blocks: the persisted locator must still point to a
    // block within 4 (or, deeper, 16) blocks of where the node's chain ends.
    for (int i = 0; i < 60; ++i) CreateAndProcessBlock({}, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));
    const CBlockIndex* tip = WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return Assert(m_node.chainman)->ActiveChain().Tip());
    const CBlockLocator dense = GetDenseLocator(tip);
    const CBlockLocator sparse = GetLocator(tip);
    BOOST_CHECK_GT(dense.vHave.size(), sparse.vHave.size());
    BOOST_CHECK(dense.vHave.front() == tip->GetBlockHash());
    BOOST_CHECK(dense.vHave.back() == sparse.vHave.back()); // both end at genesis

    // Entries are every block for ten, then every fourth.
    for (size_t i = 0; i < 10; ++i) {
        BOOST_CHECK(dense.vHave[i] == tip->GetAncestor(tip->nHeight - static_cast<int>(i))->GetBlockHash());
    }
    BOOST_CHECK(dense.vHave[11] == tip->GetAncestor(tip->nHeight - 14)->GetBlockHash());

    for (int lost = 1; lost <= 55; ++lost) {
        // Replace the entries that lie above (tip - lost) with unknown hashes.
        CBlockLocator damaged = dense;
        const int cutoff = tip->nHeight - lost;
        for (uint256& hash : damaged.vHave) {
            const CBlockIndex* index = WITH_LOCK(::cs_main, return Assert(m_node.chainman)->m_blockman.LookupBlockIndex(hash));
            if (index && index->nHeight > cutoff) hash = GetRandHash();
        }
        const auto fork = m_node.chain->findLocatorFork(damaged);
        BOOST_REQUIRE(fork);
        BOOST_CHECK_LE(*fork, cutoff);
        BOOST_CHECK_LE(cutoff - *fork, lost < 10 ? 0 : 4);
        BOOST_CHECK_LE(cutoff - *fork, 4);
    }
}

BOOST_FIXTURE_TEST_CASE(dense_chain_locator_is_built_once_per_block_and_follows_reorgs, TestChain100Setup)
{
    const auto tip_of = [&] { return WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return Assert(m_node.chainman)->ActiveChain().Tip()); };
    CBlockIndex* old_tip = tip_of();
    const uint256 old_hash = old_tip->GetBlockHash();
    const CBlockLocator first = m_node.chain->getDenseChainLocator(old_hash);
    BOOST_CHECK(first.vHave == GetDenseLocator(old_tip).vHave);

    // The second call for the same block does not take cs_main: with cs_main held elsewhere it still returns.
    std::promise<void> held, release;
    std::thread holder([&] {
        LOCK(::cs_main);
        held.set_value();
        release.get_future().wait();
    });
    held.get_future().wait();
    auto cached = std::async(std::launch::async, [&] { return m_node.chain->getDenseChainLocator(old_hash); });
    const bool served_without_cs_main = cached.wait_for(std::chrono::seconds{5}) == std::future_status::ready;
    release.set_value();
    holder.join();
    BOOST_REQUIRE(served_without_cs_main);
    BOOST_CHECK(cached.get().vHave == first.vHave);

    // A reorg: the cache is keyed by block hash, so the new tip gets its own locator and the old one stays right.
    BlockValidationState state;
    BOOST_REQUIRE(m_node.chainman->ActiveChainstate().InvalidateBlock(state, old_tip));
    const CBlock replacement = CreateAndProcessBlock({}, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));
    const CBlockIndex* new_tip = tip_of();
    BOOST_REQUIRE(new_tip->GetBlockHash() == replacement.GetHash());
    BOOST_REQUIRE(new_tip->GetBlockHash() != old_hash);
    const CBlockLocator second = m_node.chain->getDenseChainLocator(new_tip->GetBlockHash());
    BOOST_CHECK(second.vHave == GetDenseLocator(new_tip).vHave);
    BOOST_CHECK(second.vHave.front() == new_tip->GetBlockHash());
    BOOST_CHECK(m_node.chain->getDenseChainLocator(old_hash).vHave == first.vHave);
    BOOST_CHECK(m_node.chain->getDenseChainLocator(new_tip->GetBlockHash()).vHave == second.vHave);
    // An unknown block has no locator and does not disturb the cache.
    BOOST_CHECK(m_node.chain->getDenseChainLocator(GetRandHash()).IsNull());
    BOOST_CHECK(m_node.chain->getDenseChainLocator(new_tip->GetBlockHash()).vHave == second.vHave);
}

BOOST_AUTO_TEST_SUITE_END()

} // namespace wallet
