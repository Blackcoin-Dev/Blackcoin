// Copyright (c) 2026 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <wallet/display_balance.h>

#include <core_io.h>
#include <interfaces/chain.h>
#include <rpc/request.h>
#include <rpc/server.h>
#include <script/solver.h>
#include <test/util/setup_common.h>
#include <univalue.h>
#include <validation.h>
#include <wallet/context.h>
#include <wallet/rpc/wallet.h>
#include <wallet/spend.h>
#include <wallet/test/util.h>
#include <wallet/wallet.h>

#include <boost/test/unit_test.hpp>

#include <atomic>
#include <chrono>
#include <future>
#include <map>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>

using namespace std::chrono_literals;

namespace wallet {
BOOST_AUTO_TEST_SUITE(polled_balance_tests)

namespace {
/** A wallet that is loaded the way a node loads it: AddWallet() puts it on
 * the display balance worker, RemoveWallet() takes it off. */
struct PolledWalletSetup : public TestChain100Setup {
    std::shared_ptr<CWallet> wallet;
    WalletContext context;

    PolledWalletSetup()
    {
        wallet.reset(CreateSyncedWallet(
            *m_node.chain,
            WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()),
            coinbaseKey).release());
        context.args = &m_args;
        context.chain = m_node.chain.get();
        BOOST_REQUIRE(!DisplayBalanceWorker::Global().Find(*wallet));
        BOOST_REQUIRE(AddWallet(context, wallet));
        BOOST_REQUIRE(DisplayBalanceWorker::Global().Find(*wallet));
    }
    ~PolledWalletSetup()
    {
        if (wallet) Unload();
    }
    void Unload()
    {
        BOOST_CHECK(RemoveWallet(context, wallet, /*load_on_start=*/std::nullopt));
        BOOST_CHECK(!DisplayBalanceWorker::Global().Find(*wallet));
        BOOST_CHECK_EQUAL(DisplayBalanceWorker::Global().WalletCount(), 0U);
        wallet.reset();
    }

    CBlock Mine() { return CreateAndProcessBlock({}, GetScriptForRawPubKey(coinbaseKey.GetPubKey())); }
    void Notify(const CBlock& block)
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
        wallet->blockConnected(ChainstateRole::NORMAL, info);
    }
    /** The walk under both locks that the RPCs used to do. */
    Balance LockedWalk(int min_depth, bool avoid_reuse, WalletLifecycleSummary* summary_out = nullptr)
    {
        Balance balance;
        WalletLifecycleSummary summary;
        std::string error;
        LOCK2(::cs_main, wallet->cs_wallet);
        BOOST_REQUIRE_MESSAGE(GetLifecycleAdjustedBalance(*wallet, min_depth, avoid_reuse, balance, summary, error), error);
        if (summary_out) *summary_out = summary;
        return balance;
    }
    UniValue CallRPC(const std::string& method, const UniValue& params = UniValue{UniValue::VARR})
    {
        JSONRPCRequest request;
        request.context = &context;
        request.strMethod = method;
        request.params = params;
        for (const CRPCCommand& command : GetWalletRPCCommands()) {
            if (command.name != method) continue;
            UniValue result;
            BOOST_REQUIRE(command.actor(request, result, /*last_handler=*/true));
            return result;
        }
        BOOST_FAIL("no such wallet RPC: " + method);
        return UniValue{};
    }
    static UniValue Params(std::initializer_list<UniValue> values)
    {
        UniValue params{UniValue::VARR};
        for (const UniValue& value : values) params.push_back(value);
        return params;
    }
    static std::set<std::string> Keys(const UniValue& object)
    {
        const std::vector<std::string>& keys = object.getKeys();
        return {keys.begin(), keys.end()};
    }
};

void CheckSameBalance(const Balance& a, const Balance& b)
{
    BOOST_CHECK_EQUAL(a.m_mine_trusted, b.m_mine_trusted);
    BOOST_CHECK_EQUAL(a.m_mine_untrusted_pending, b.m_mine_untrusted_pending);
    BOOST_CHECK_EQUAL(a.m_mine_immature, b.m_mine_immature);
    BOOST_CHECK_EQUAL(a.m_mine_stake, b.m_mine_stake);
    BOOST_CHECK_EQUAL(a.m_watchonly_trusted, b.m_watchonly_trusted);
    BOOST_CHECK_EQUAL(a.m_watchonly_untrusted_pending, b.m_watchonly_untrusted_pending);
    BOOST_CHECK_EQUAL(a.m_watchonly_immature, b.m_watchonly_immature);
    BOOST_CHECK_EQUAL(a.m_watchonly_stake, b.m_watchonly_stake);
}

std::string Amount(CAmount amount) { return ValueFromAmount(amount).getValStr(); }

/** Holds cs_main on another thread until released. */
class MainLockHolder
{
    std::promise<void> m_held, m_release;
    std::thread m_thread;

public:
    MainLockHolder()
    {
        m_thread = std::thread([this] {
            LOCK(::cs_main);
            m_held.set_value();
            m_release.get_future().wait();
        });
        m_held.get_future().wait();
    }
    void Release()
    {
        if (!m_thread.joinable()) return;
        m_release.set_value();
        m_thread.join();
    }
    ~MainLockHolder() { Release(); }
};

int64_t ElapsedMs(std::chrono::steady_clock::time_point start)
{
    return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - start).count();
}
} // namespace

BOOST_FIXTURE_TEST_CASE(a_loaded_wallet_publishes_a_balance_without_being_asked, PolledWalletSetup)
{
    // Nobody shows the wallet and nobody has asked: the worker computes the
    // first snapshot of a loaded wallet by itself.
    const std::shared_ptr<WalletDisplayBalance> state = DisplayBalanceWorker::Global().Find(*wallet);
    BOOST_REQUIRE(state);
    for (int i = 0; i < 4000 && !state->Snapshot(); ++i) std::this_thread::sleep_for(5ms);
    const std::shared_ptr<const DisplayBalanceSnapshot> snapshot = state->Snapshot();
    BOOST_REQUIRE(snapshot);
    WalletLifecycleSummary summary;
    CheckSameBalance(snapshot->balance, LockedWalk(0, true, &summary));
    BOOST_CHECK_GT(snapshot->balance.m_mine_trusted, 0);
    BOOST_CHECK_EQUAL(snapshot->lifecycle.evaluation_height, summary.evaluation_height);
    BOOST_CHECK(snapshot->lifecycle.mine.nominal == summary.mine.nominal);

    // AddWallet and RemoveWallet are each idempotent towards the worker, and
    // a window on the wallet holds a reference of its own.
    DisplayBalanceWorker::Global().AcquirePolled(*wallet);
    BOOST_CHECK_EQUAL(DisplayBalanceWorker::Global().WalletCount(), 1U);
    const std::shared_ptr<WalletDisplayBalance> gui = DisplayBalanceWorker::Global().Acquire(*wallet);
    BOOST_CHECK(gui == state);
    DisplayBalanceWorker::Global().ReleasePolled(*wallet);
    DisplayBalanceWorker::Global().ReleasePolled(*wallet);
    BOOST_CHECK(DisplayBalanceWorker::Global().Find(*wallet) == state);
    DisplayBalanceWorker::Global().AcquirePolled(*wallet);
    DisplayBalanceWorker::Global().Release(*wallet);
    BOOST_CHECK(DisplayBalanceWorker::Global().Find(*wallet) == state);

    // Unloading takes the wallet off the worker; a poll then has nothing.
    const std::shared_ptr<CWallet> keep = wallet;
    Unload();
    const PolledBalance gone = GetPolledBalance(*keep);
    BOOST_CHECK(!gone.snapshot);
    BOOST_CHECK(!gone.exact);
}

BOOST_FIXTURE_TEST_CASE(polled_balance_does_not_wait_for_cs_main, PolledWalletSetup)
{
    PolledBalanceOptions exact_options;
    exact_options.exact = true;
    const PolledBalance first = GetPolledBalance(*wallet, exact_options);
    BOOST_REQUIRE(first.snapshot);
    BOOST_CHECK(first.exact);
    CheckSameBalance(first.snapshot->balance, LockedWalk(0, true));
    const CAmount balance_before = first.snapshot->balance.m_mine_trusted;

    // Another thread holds cs_main, as block connection does for as long as
    // it takes on a slow disk.
    MainLockHolder holder;

    // The snapshot is current: a poll, and an exact request, answer at once.
    {
        const auto start = std::chrono::steady_clock::now();
        const PolledBalance polled = GetPolledBalance(*wallet);
        const PolledBalance exact = GetPolledBalance(*wallet, exact_options);
        BOOST_CHECK_LT(ElapsedMs(start), 5000);
        BOOST_REQUIRE(polled.snapshot && exact.snapshot);
        BOOST_CHECK(polled.exact);
        BOOST_CHECK(exact.exact);
        BOOST_CHECK_EQUAL(polled.snapshot->balance.m_mine_trusted, balance_before);
    }
    // So do the RPCs, with every field a caller of the old RPCs reads.
    {
        const auto start = std::chrono::steady_clock::now();
        const UniValue info = CallRPC("getwalletinfo");
        const UniValue balances = CallRPC("getbalances");
        const UniValue balance = CallRPC("getbalance");
        BOOST_CHECK_LT(ElapsedMs(start), 5000);
        for (const char* key : {"walletname", "walletversion", "format", "balance", "stake", "unconfirmed_balance",
                                "immature_balance", "lifecycle", "txcount", "keypoolsize", "paytxfee",
                                "private_keys_enabled", "avoid_reuse", "scanning", "descriptors", "external_signer",
                                "quantum_keys", "blank", "lastprocessedblock",
                                "balance_exact", "balance_height", "balance_blockhash", "balance_state"}) {
            BOOST_CHECK_MESSAGE(info.exists(key), key);
        }
        BOOST_CHECK(info["balance"].isNum());
        BOOST_CHECK(info["stake"].isNum());
        BOOST_CHECK(info["immature_balance"].isNum());
        BOOST_CHECK(info["unconfirmed_balance"].isNum());
        BOOST_CHECK(info["lifecycle"].isObject());
        BOOST_CHECK(info["lifecycle"]["categories"].isObject());
        BOOST_CHECK_EQUAL(info["balance"].getValStr(), Amount(balance_before));
        BOOST_CHECK_EQUAL(info["balance_exact"].get_bool(), true);
        BOOST_CHECK_EQUAL(info["balance_state"].get_str(), "exact");
        BOOST_CHECK_EQUAL(info["balance_height"].getInt<int>(), first.snapshot->tip_height);
        BOOST_CHECK_EQUAL(info["balance_blockhash"].get_str(), first.snapshot->tip_hash.GetHex());
        BOOST_CHECK_EQUAL(info["lastprocessedblock"]["hash"].get_str(), first.snapshot->tip_hash.GetHex());

        BOOST_CHECK((Keys(balances) == std::set<std::string>{"mine", "lifecycle_evaluation_height", "lifecycle_evaluation_mtp",
                                                             "balance_exact", "balance_height", "balance_blockhash",
                                                             "balance_state", "lastprocessedblock"}));
        BOOST_CHECK((Keys(balances["mine"]) == std::set<std::string>{"trusted", "untrusted_pending", "immature", "stake", "lifecycle"}));
        BOOST_CHECK_EQUAL(balances["mine"]["trusted"].getValStr(), Amount(balance_before));
        BOOST_CHECK_EQUAL(balances["mine"]["immature"].getValStr(), Amount(first.snapshot->balance.m_mine_immature));
        BOOST_CHECK_EQUAL(balances["mine"]["stake"].getValStr(), Amount(first.snapshot->balance.m_mine_stake));
        BOOST_CHECK_EQUAL(balances["balance_exact"].get_bool(), true);
        BOOST_CHECK_EQUAL(balance.getValStr(), Amount(balance_before));
    }

    // The wallet changes while cs_main is held. No new balance can be
    // computed; a poll says so after its short wait and returns the last one.
    WITH_LOCK(wallet->cs_wallet, wallet->BumpBalanceScanMarker());
    {
        const auto start = std::chrono::steady_clock::now();
        const PolledBalance polled = GetPolledBalance(*wallet);
        BOOST_CHECK_LT(ElapsedMs(start), 5000);
        BOOST_REQUIRE(polled.snapshot);
        BOOST_CHECK(!polled.exact);
        BOOST_CHECK_EQUAL(polled.snapshot->balance.m_mine_trusted, balance_before);

        const UniValue info = CallRPC("getwalletinfo");
        BOOST_CHECK_LT(ElapsedMs(start), 10000);
        BOOST_CHECK_EQUAL(info["balance_exact"].get_bool(), false);
        BOOST_CHECK_EQUAL(info["balance_state"].get_str(), "current-unverified");
        BOOST_CHECK_EQUAL(info["balance"].getValStr(), Amount(balance_before));
        BOOST_CHECK_EQUAL(CallRPC("getbalance").getValStr(), Amount(balance_before));
    }
    // An exact request waits, without a lock, and gives up at its timeout
    // with the last balance: it never walks the wallet under both locks.
    {
        PolledBalanceOptions impatient = exact_options;
        impatient.exact_timeout = 300ms;
        const auto start = std::chrono::steady_clock::now();
        const PolledBalance exact = GetPolledBalance(*wallet, impatient);
        BOOST_CHECK_GE(ElapsedMs(start), 250);
        BOOST_CHECK_LT(ElapsedMs(start), 10000);
        BOOST_REQUIRE(exact.snapshot);
        BOOST_CHECK(!exact.exact);
        BOOST_CHECK_EQUAL(exact.snapshot->balance.m_mine_trusted, balance_before);
        // A balance for other arguments cannot be had either, and says so.
        std::string error;
        BOOST_CHECK(!ComputeBalanceVariant(*wallet, /*min_depth=*/6, /*avoid_reuse=*/true, 300ms, error));
        BOOST_CHECK(!error.empty());
    }

    // cs_main is free again: the exact balance arrives.
    holder.Release();
    const PolledBalance after = GetPolledBalance(*wallet, exact_options);
    BOOST_REQUIRE(after.snapshot);
    BOOST_CHECK(after.exact);
    BOOST_CHECK_EQUAL(CallRPC("getwalletinfo")["balance_state"].get_str(), "exact");
}

BOOST_FIXTURE_TEST_CASE(exact_balance_equals_the_walk_under_both_locks, PolledWalletSetup)
{
    PolledBalanceOptions exact_options;
    exact_options.exact = true;
    exact_options.want_full = true;

    for (int round = 0; round < 3; ++round) {
        // A new block: the wallet processes it, the snapshot is behind until
        // the worker has had a turn, and an exact request waits for that.
        const CBlock block = Mine();
        Notify(block);
        const PolledBalance exact = GetPolledBalance(*wallet, exact_options);
        BOOST_REQUIRE(exact.snapshot);
        BOOST_CHECK(exact.exact);
        const uint256 tip = WITH_LOCK(::cs_main, return m_node.chainman->ActiveChain().Tip()->GetBlockHash());
        BOOST_CHECK(exact.snapshot->tip_hash == tip);
        WalletLifecycleSummary summary;
        const Balance walked = LockedWalk(0, true, &summary);
        CheckSameBalance(exact.snapshot->balance, walked);
        BOOST_CHECK_EQUAL(exact.snapshot->lifecycle.evaluation_height, summary.evaluation_height);
        BOOST_CHECK_EQUAL(exact.snapshot->lifecycle.evaluation_mtp, summary.evaluation_mtp);
        BOOST_CHECK(exact.snapshot->lifecycle.mine.outputs == summary.mine.outputs);
        BOOST_CHECK(exact.snapshot->lifecycle.mine.nominal == summary.mine.nominal);
        BOOST_CHECK(exact.snapshot->lifecycle.mine.effective == summary.mine.effective);
        // The balance without the reuse filter, of the same wallet state.
        BOOST_REQUIRE(exact.full);
        CheckSameBalance(*exact.full, LockedWalk(0, false));

        // Arguments the snapshot does not cover are computed for the call.
        for (const int min_depth : {0, 1, 6, 101, 1000}) {
            for (const bool avoid_reuse : {true, false}) {
                std::string error;
                const std::optional<BalanceVariant> variant = ComputeBalanceVariant(*wallet, min_depth, avoid_reuse, 60s, error);
                BOOST_REQUIRE_MESSAGE(variant, error);
                BOOST_CHECK(variant->tip_hash == tip);
                CheckSameBalance(variant->balance, LockedWalk(min_depth, avoid_reuse));
            }
        }

        // The RPCs, with exact=true and with other arguments.
        BOOST_CHECK_EQUAL(CallRPC("getbalance", Params({"*", 0, false, NullUniValue, true})).getValStr(), Amount(walked.m_mine_trusted));
        BOOST_CHECK_EQUAL(CallRPC("getbalance", Params({"*", 6})).getValStr(), Amount(LockedWalk(6, true).m_mine_trusted));
        BOOST_CHECK_EQUAL(CallRPC("getbalance", Params({"*", 1000})).getValStr(), Amount(0));
        const UniValue info = CallRPC("getwalletinfo", Params({true}));
        BOOST_CHECK_EQUAL(info["balance"].getValStr(), Amount(walked.m_mine_trusted));
        BOOST_CHECK_EQUAL(info["immature_balance"].getValStr(), Amount(walked.m_mine_immature));
        BOOST_CHECK_EQUAL(info["stake"].getValStr(), Amount(walked.m_mine_stake));
        BOOST_CHECK_EQUAL(info["balance_exact"].get_bool(), true);
        BOOST_CHECK_EQUAL(info["balance_blockhash"].get_str(), tip.GetHex());
        BOOST_CHECK_EQUAL(info["lifecycle"]["evaluation_height"].getInt<int>(), summary.evaluation_height);
        const UniValue balances = CallRPC("getbalances", Params({true}));
        BOOST_CHECK_EQUAL(balances["mine"]["trusted"].getValStr(), Amount(walked.m_mine_trusted));
        BOOST_CHECK_EQUAL(balances["mine"]["immature"].getValStr(), Amount(walked.m_mine_immature));
        BOOST_CHECK_EQUAL(balances["lifecycle_evaluation_height"].getInt<int>(), summary.evaluation_height);
        BOOST_CHECK_EQUAL(balances["balance_state"].get_str(), "exact");
    }

    // The chain moves and the wallet has not been told. What is published
    // stays the balance of the wallet's last processed block and is exact
    // for the wallet as it is (the RPCs let the wallet catch up first when
    // exact is asked for). No balance is computed for a tip the wallet has
    // not processed.
    const PolledBalance before = GetPolledBalance(*wallet, exact_options);
    BOOST_REQUIRE(before.exact);
    Mine(); // the wallet is not told
    const PolledBalance unsynced = GetPolledBalance(*wallet, exact_options);
    BOOST_REQUIRE(unsynced.snapshot);
    BOOST_CHECK(unsynced.snapshot->tip_hash == before.snapshot->tip_hash);
    CheckSameBalance(unsynced.snapshot->balance, before.snapshot->balance);
    BOOST_CHECK_EQUAL(WITH_LOCK(wallet->cs_wallet, return PolledBalanceStateString(*wallet, unsynced)), "exact");
    std::string error;
    BOOST_CHECK(!ComputeBalanceVariant(*wallet, 6, true, 300ms, error));
    BOOST_CHECK_MESSAGE(error.find("has not processed the chain tip") != std::string::npos, error);
}

BOOST_FIXTURE_TEST_CASE(polls_while_blocks_connect_are_never_wrong_about_their_block, PolledWalletSetup)
{
    // One thread connects blocks and tells the wallet; another polls. Every
    // answer is the balance of the block it names.
    std::map<uint256, CAmount> walked;
    walked[WITH_LOCK(::cs_main, return m_node.chainman->ActiveChain().Tip()->GetBlockHash())] = LockedWalk(0, true).m_mine_trusted;

    std::atomic<bool> stop{false};
    std::mutex seen_mutex;
    std::vector<std::pair<uint256, CAmount>> seen;
    std::thread poller([&] {
        while (!stop) {
            PolledBalanceOptions quick;
            quick.fresh_wait = 20ms;
            const PolledBalance polled = GetPolledBalance(*wallet, quick);
            if (polled.snapshot) {
                std::lock_guard<std::mutex> lock(seen_mutex);
                seen.emplace_back(polled.snapshot->tip_hash, polled.snapshot->balance.m_mine_trusted);
            }
            std::this_thread::sleep_for(2ms);
        }
    });
    PolledBalanceOptions exact_options;
    exact_options.exact = true;
    for (int i = 0; i < 12; ++i) {
        const CBlock block = Mine();
        Notify(block);
        walked[block.GetHash()] = LockedWalk(0, true).m_mine_trusted;
        const PolledBalance exact = GetPolledBalance(*wallet, exact_options);
        BOOST_REQUIRE(exact.snapshot);
        BOOST_CHECK(exact.exact);
        BOOST_CHECK(exact.snapshot->tip_hash == block.GetHash());
        BOOST_CHECK_EQUAL(exact.snapshot->balance.m_mine_trusted, walked.at(block.GetHash()));
    }
    stop = true;
    poller.join();
    BOOST_CHECK(!seen.empty());
    for (const auto& [tip_hash, balance] : seen) {
        const auto it = walked.find(tip_hash);
        BOOST_REQUIRE(it != walked.end());
        BOOST_CHECK_EQUAL(balance, it->second);
    }
}

BOOST_AUTO_TEST_SUITE_END()
} // namespace wallet
