// Copyright (c) 2026 Blackcoin Core Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

// Slow-disk regression gates. A spinning disk turns every chainstate lookup
// into a seek and every wallet commit into a flush, so the gates count those
// operations instead of timing them: a count does not depend on how fast the
// machine running the test is.
//
// Part one holds on RC13 and keeps holding: the counters count exactly, the
// large wallet fixture builds, and its balance is the sum of its outputs.
// Part two are gates for the other RC14 tracks; they are guarded by
// RC14_GATES_ENFORCED below (see test/util/rc14_gate.h).

#include <chainparams.h>
#include <coins.h>
#include <interfaces/chain.h>
#include <interfaces/wallet.h>
#include <node/blockstorage.h>
#include <primitives/block.h>
#include <rpc/request.h>
#include <rpc/server.h>
#include <test/util/rc14_gate.h>
#include <test/util/setup_common.h>
#include <univalue.h>
#include <util/io_counters.h>
#include <validation.h>
#include <validationinterface.h>
#include <wallet/context.h>
#include <wallet/display_balance.h>
#include <wallet/receive.h>
#include <wallet/rpc/wallet.h>
#include <wallet/scheduler_stats.h>
#include <wallet/spend.h>
#include <wallet/test/large_wallet_fixture.h>
#include <wallet/test/util.h>
#include <wallet/wallet.h>
#include <wallet/walletdb.h>

#include <boost/test/unit_test.hpp>

#include <atomic>
#include <chrono>
#include <future>
#include <thread>

using namespace std::chrono_literals;

//! TODO(rc14-integration): set to true once the other RC14 tracks are merged
//! (balance served without chainstate reads, sorted warm-up, one commit per
//! idle block batch). Each guarded check fails on RC13 by design.
static constexpr bool RC14_GATES_ENFORCED{false};

namespace wallet {
namespace {

struct GateSetup : public TestChain100Setup {
    WalletContext context;
    test::LargeWallet large;

    GateSetup()
    {
        context.args = &m_args;
        context.chain = m_node.chain.get();
        large = test::BuildLargeWallet(*this, test::LargeWalletSize::FromEnvironment(), "io_gate_wallet");
    }
    ~GateSetup()
    {
        SyncWithValidationInterfaceQueue();
        for (const std::shared_ptr<CWallet>& wallet : GetWallets(context)) {
            wallet->m_chain_notifications_handler.reset();
            RemoveWallet(context, wallet, /*load_on_start=*/std::nullopt);
        }
        large.wallet.reset();
        context.chain = nullptr;
    }

    UniValue CallWalletRpc(const std::string& method)
    {
        JSONRPCRequest request;
        request.context = &context;
        request.strMethod = method;
        request.params.setArray();
        UniValue result;
        for (const CRPCCommand& command : GetWalletRPCCommands()) {
            if (command.name == method) {
                BOOST_REQUIRE(command.actor(request, result, /*last_handler=*/true));
                return result;
            }
        }
        BOOST_FAIL("missing wallet RPC: " + method);
        return result;
    }

    //! Close the wallet and open it again from its file, as a node restart does.
    std::shared_ptr<CWallet> Reopen()
    {
        large.wallet.reset();
        DatabaseOptions options;
        options.require_format = DatabaseFormat::SQLITE;
        DatabaseStatus status;
        bilingual_str error;
        std::vector<bilingual_str> warnings;
        auto database{MakeWalletDatabase(large.name, options, status, error)};
        BOOST_REQUIRE_MESSAGE(database, error.original);
        auto reopened = CWallet::Create(context, large.name, std::move(database), /*wallet_creation_flags=*/0, error, warnings);
        BOOST_REQUIRE_MESSAGE(reopened, error.original);
        BOOST_REQUIRE(AddWallet(context, reopened));
        large.wallet = reopened;
        return reopened;
    }

    uint64_t ChainstateReads() const
    {
        const iocounters::Snapshot s = iocounters::Read();
        return s.chainstate_get_coin + s.chainstate_have_coin;
    }

    //! Distinct transaction ids of the coin keys recorded from `first` on.
    std::set<uint256> RecordedCoinTxids(size_t first) const
    {
        std::set<uint256> txids;
        for (const std::string& key : iocounters::RecordedKeys(first)) {
            if (key.size() < 33 || key[0] != 'C') continue;
            txids.insert(uint256{Span<const unsigned char>{reinterpret_cast<const unsigned char*>(key.data()) + 1, 32}});
        }
        return txids;
    }

    //! A block that pays somebody else, so the wallet has nothing to record for it.
    CBlock MineForeignBlock()
    {
        CKey other;
        other.MakeNewKey(/*fCompressed=*/true);
        return CreateAndProcessBlock({}, GetScriptForRawPubKey(other.GetPubKey()));
    }

    void NotifyConnected(CWallet& wallet, const CBlock& block)
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
};

struct RecorderOff {
    ~RecorderOff()
    {
        iocounters::SetKeyRecorder(false);
        iocounters::ClearRecordedKeys();
    }
};

} // namespace

BOOST_AUTO_TEST_SUITE(io_gate_tests)

// ---- Part one: holds on RC13 ------------------------------------------------

BOOST_FIXTURE_TEST_CASE(fixture_builds_and_balance_equals_the_sum_of_its_outputs, GateSetup)
{
    CWallet& wallet = *large.wallet;
    const size_t records = WITH_LOCK(wallet.cs_wallet, return wallet.mapWallet.size());
    BOOST_CHECK_EQUAL(records, large.txs);
    BOOST_CHECK_GT(large.live.size(), large.coinbase_txids.size());
    BOOST_CHECK_GT(large.live_total, 0);

    const Balance balance = GetBalance(wallet);
    BOOST_CHECK_EQUAL(balance.m_mine_trusted, large.live_total);
    BOOST_CHECK_EQUAL(balance.m_mine_untrusted_pending, 0);
    BOOST_CHECK_EQUAL(balance.m_mine_immature, 0);

    // The wallet sees every live output as spendable and no dead one.
    size_t unspent{0};
    {
        LOCK2(::cs_main, wallet.cs_wallet);
        for (const auto& [txid, wtx] : wallet.mapWallet) {
            for (size_t n = 0; n < wtx.tx->vout.size(); ++n) {
                const COutPoint outpoint{txid, static_cast<uint32_t>(n)};
                const bool is_live = large.live.count(outpoint) != 0;
                BOOST_REQUIRE_EQUAL(!wallet.IsSpent(outpoint), is_live);
                unspent += is_live;
            }
        }
        CoinsResult coins = AvailableCoins(wallet, /*coinControl=*/nullptr, /*feerate=*/std::nullopt, CoinFilterParams{});
        BOOST_CHECK_EQUAL(coins.Size(), large.live.size());
        BOOST_CHECK_EQUAL(coins.GetTotalAmount(), large.live_total);
    }
    BOOST_CHECK_EQUAL(unspent, large.live.size());
}

BOOST_FIXTURE_TEST_CASE(fixture_coins_are_in_the_chainstate_database_and_counted, GateSetup)
{
    Chainstate& chainstate = m_node.chainman->ActiveChainstate();
    const iocounters::Snapshot before = iocounters::Read();
    size_t looked_up{0};
    {
        LOCK(::cs_main);
        for (const COutPoint& outpoint : large.live) {
            Coin coin;
            BOOST_REQUIRE(chainstate.CoinsDB().GetCoin(outpoint, coin));
            BOOST_CHECK(!coin.IsSpent());
            if (++looked_up == 100) break;
        }
        // The first dead output has no coin.
        LOCK(large.wallet->cs_wallet);
        for (const auto& [txid, wtx] : large.wallet->mapWallet) {
            const COutPoint outpoint{txid, 0};
            if (large.live.count(outpoint)) continue;
            BOOST_CHECK(!chainstate.CoinsDB().HaveCoin(outpoint));
            break;
        }
    }
    const iocounters::Snapshot after = iocounters::Read();
    BOOST_CHECK_EQUAL(after.chainstate_get_coin - before.chainstate_get_coin, looked_up);
    BOOST_CHECK_EQUAL(after.chainstate_have_coin - before.chainstate_have_coin, 1U);
}

BOOST_FIXTURE_TEST_CASE(wallet_commit_counters_count_a_known_sequence, GateSetup)
{
    CWallet& wallet = *large.wallet;
    WalletDatabase& db = wallet.GetDatabase();
    const auto commits = [] { return iocounters::Read().wallet_commits; };
    const auto in_handler = [] { return iocounters::Read().wallet_commits_in_handler; };

    // One write outside any transaction commits by itself.
    uint64_t c0 = commits();
    {
        WalletBatch batch{db};
        BOOST_REQUIRE(batch.WriteName("gate-address-0", "label"));
    }
    BOOST_CHECK_EQUAL(commits() - c0, 1U);

    // Ten writes in one transaction are one commit.
    c0 = commits();
    {
        WalletBatch batch{db};
        BOOST_REQUIRE(batch.TxnBegin());
        for (int n = 1; n <= 10; ++n) BOOST_REQUIRE(batch.WriteName(strprintf("gate-address-%d", n), "label"));
        BOOST_REQUIRE(batch.TxnCommit());
    }
    BOOST_CHECK_EQUAL(commits() - c0, 1U);

    // A grouped-writes scope is one commit however many records it holds.
    c0 = commits();
    {
        std::unique_ptr<DatabaseBulkScope> writes = db.MakeBulkScope();
        BOOST_REQUIRE(writes);
        WalletBatch batch{db};
        for (int n = 11; n <= 30; ++n) BOOST_REQUIRE(batch.WriteName(strprintf("gate-address-%d", n), "label"));
        BOOST_REQUIRE(writes->Commit());
    }
    BOOST_CHECK_EQUAL(commits() - c0, 1U);

    // A commit made inside a wallet handler is counted as one under cs_wallet.
    c0 = commits();
    uint64_t h0 = in_handler();
    {
        WalletBatch batch{db};
        BOOST_REQUIRE(batch.WriteName("gate-outside", "label"));
    }
    BOOST_CHECK_EQUAL(commits() - c0, 1U);
    BOOST_CHECK_EQUAL(in_handler() - h0, 0U);
    {
        WalletCallbackTimer timer{WalletCallbackKind::BLOCK_CONNECTED};
        LOCK(wallet.cs_wallet);
        timer.LockAcquired();
        BOOST_CHECK(InWalletCallback());
        WalletBatch batch{db};
        BOOST_REQUIRE(batch.WriteName("gate-inside", "label"));
    }
    BOOST_CHECK(!InWalletCallback());
    BOOST_CHECK_EQUAL(commits() - c0, 2U);
    BOOST_CHECK_EQUAL(in_handler() - h0, 1U);
}

BOOST_FIXTURE_TEST_CASE(wallet_commit_delay_applies_to_a_real_commit, GateSetup)
{
    struct Off { ~Off() { iocounters::SetWalletCommitDelayUs(0); } } off;
    WalletDatabase& db = large.wallet->GetDatabase();
    iocounters::SetWalletCommitDelayUs(5000);
    const auto start = std::chrono::steady_clock::now();
    for (int n = 0; n < 4; ++n) {
        WalletBatch batch{db};
        BOOST_REQUIRE(batch.WriteName(strprintf("gate-delay-%d", n), "label"));
    }
    BOOST_CHECK_GE(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - start).count(), 4 * 5000);
}

// ---- Part two: gates for the other tracks -----------------------------------

BOOST_FIXTURE_TEST_CASE(polling_getwalletinfo_and_getbalances_reads_no_chainstate_and_ignores_cs_main, GateSetup)
{
    BOOST_REQUIRE(AddWallet(context, large.wallet));
    (void)CallWalletRpc("getbalances"); // the first call may do the warm-up work

    // Polling: no chainstate lookup at all.
    const uint64_t reads_before = ChainstateReads();
    for (int n = 0; n < 3; ++n) {
        (void)CallWalletRpc("getwalletinfo");
        (void)CallWalletRpc("getbalances");
    }
    const uint64_t polled_reads = ChainstateReads() - reads_before;
    RC14_GATE_CHECK(RC14_GATES_ENFORCED, polled_reads == 0,
                    "polling getwalletinfo and getbalances performs zero chainstate reads (saw " << polled_reads << ")");

    // And it returns while another thread holds cs_main.
    std::promise<void> held, release;
    std::shared_future<void> release_signal{release.get_future()};
    std::thread holder([&] {
        LOCK(::cs_main);
        held.set_value();
        release_signal.wait();
    });
    held.get_future().wait();
    auto polls = std::async(std::launch::async, [&] {
        (void)CallWalletRpc("getwalletinfo");
        (void)CallWalletRpc("getbalances");
    });
    // A generous bound: only a call that waits on cs_main can miss it.
    const bool returned = polls.wait_for(30s) == std::future_status::ready;
    release.set_value();
    holder.join();
    polls.wait();
    RC14_GATE_CHECK(RC14_GATES_ENFORCED, returned,
                    "getwalletinfo and getbalances return while another thread holds cs_main");
}

BOOST_FIXTURE_TEST_CASE(restart_reads_no_noncoinbase_output_before_the_first_balance, GateSetup)
{
    RecorderOff off;
    iocounters::ClearRecordedKeys();
    iocounters::SetKeyRecorder(true);
    const std::shared_ptr<CWallet> wallet = Reopen();
    BOOST_REQUIRE(wallet);
    BOOST_CHECK_EQUAL(WITH_LOCK(wallet->cs_wallet, return wallet->mapWallet.size()), large.txs);
    (void)CallWalletRpc("getbalances"); // the first balance served
    iocounters::SetKeyRecorder(false);

    size_t noncoinbase_reads{0};
    for (const uint256& txid : RecordedCoinTxids(0)) noncoinbase_reads += large.noncoinbase_live_txids.count(txid);
    RC14_GATE_CHECK(RC14_GATES_ENFORCED, noncoinbase_reads == 0,
                    "restart performs zero chainstate reads for non-coinbase wallet outputs before the first balance (saw "
                        << noncoinbase_reads << " of " << large.noncoinbase_live_txids.size() << ")");
}

BOOST_FIXTURE_TEST_CASE(balance_warm_up_reads_come_in_key_order, GateSetup)
{
    RecorderOff off;
    const std::shared_ptr<CWallet> wallet = Reopen();
    BOOST_REQUIRE(wallet);
    iocounters::ClearRecordedKeys();
    iocounters::SetKeyRecorder(true);
    const auto state = std::make_shared<WalletDisplayBalance>(*wallet);
    state->RunJob([] { return true; });
    iocounters::SetKeyRecorder(false);

    const iocounters::KeyOrderReport order = iocounters::RecordedKeyOrder('C');
    RC14_GATE_CHECK(RC14_GATES_ENFORCED, order.inversions == 0,
                    "chainstate reads of the balance warm-up come in non-decreasing key order (" << order.keys
                        << " reads, " << order.inversions << " out of order)");
}

BOOST_FIXTURE_TEST_CASE(fifty_idle_blocks_do_at_most_three_wallet_commits, GateSetup)
{
    CWallet& wallet = *large.wallet;
    std::vector<CBlock> blocks;
    for (int n = 0; n < 50; ++n) blocks.push_back(MineForeignBlock());

    const iocounters::Snapshot before = iocounters::Read();
    for (const CBlock& block : blocks) NotifyConnected(wallet, block);
    const iocounters::Snapshot after = iocounters::Read();
    const uint64_t commits = after.wallet_commits - before.wallet_commits;
    BOOST_TEST_MESSAGE("wallet commits for 50 idle blocks: " << commits << " (in handlers: "
                       << after.wallet_commits_in_handler - before.wallet_commits_in_handler << ")");
    RC14_GATE_CHECK(RC14_GATES_ENFORCED, commits <= 3,
                    "connecting 50 blocks with no wallet activity performs at most 3 wallet DB commits (saw " << commits << ")");
}

// ---- Full size: select by name, e.g. --run_test=io_gate_tests/scale_*  -------

BOOST_AUTO_TEST_CASE(scale_full_size_fixture, *boost::unit_test::disabled())
{
    // Run with BLACKCOIN_LARGE_WALLET=full for the full-size gates above, or
    // directly to see how long the fixture takes at 140,000 records.
    TestChain100Setup setup;
    const auto start = std::chrono::steady_clock::now();
    test::LargeWallet full = test::BuildLargeWallet(setup, test::LargeWalletSize::Full(), "io_gate_full");
    BOOST_TEST_MESSAGE("full size fixture built in "
                       << std::chrono::duration_cast<std::chrono::seconds>(std::chrono::steady_clock::now() - start).count() << " s");
    BOOST_CHECK_EQUAL(full.live.size(), 124'000U);
    BOOST_CHECK_EQUAL(GetBalance(*full.wallet).m_mine_trusted, full.live_total);
    full.wallet.reset();
}

BOOST_AUTO_TEST_SUITE_END()
} // namespace wallet
