// Copyright (c) 2026 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <wallet/display_balance.h>

#include <interfaces/chain.h>
#include <interfaces/handler.h>
#include <interfaces/wallet.h>
#include <scheduler.h>
#include <test/util/logging.h>
#include <test/util/setup_common.h>
#include <validation.h>
#include <validationinterface.h>
#include <wallet/coincontrol.h>
#include <wallet/context.h>
#include <wallet/spend.h>
#include <wallet/test/util.h>
#include <wallet/wallet.h>

#include <boost/test/unit_test.hpp>

#include <atomic>
#include <chrono>
#include <future>
#include <thread>
#include <vector>

using namespace std::chrono_literals;

namespace wallet {
BOOST_AUTO_TEST_SUITE(display_balance_tests)

// ---- When a slice may start (I4) ------------------------------------------

BOOST_AUTO_TEST_CASE(busy_gate_runs_when_quiet_and_defers_when_busy)
{
    DisplayBusyGate gate;
    BOOST_CHECK(gate.MayRun(1000, /*busy=*/false));
    BOOST_CHECK(gate.MayRun(1001, /*busy=*/false));
    // Busy: no slice starts, however often the worker asks.
    for (int64_t t = 2000; t < 2000 + DisplayBusyGate::MAX_DEFER_MS; t += 5) {
        BOOST_CHECK(!gate.MayRun(t, /*busy=*/true));
    }
    BOOST_CHECK(!gate.Forced());
    // The first quiet moment lets the next slice start at once.
    BOOST_CHECK(gate.MayRun(2000 + DisplayBusyGate::MAX_DEFER_MS - 1, /*busy=*/false));
}

BOOST_AUTO_TEST_CASE(busy_gate_bounds_the_deference_on_a_permanently_busy_node)
{
    DisplayBusyGate gate;
    int64_t t = 1000;
    int slices{0};
    int64_t first_slice{0};
    std::vector<int64_t> starts;
    const int64_t end = t + DisplayBusyGate::MAX_DEFER_MS + 10 * DisplayBusyGate::FORCED_INTERVAL_MS;
    for (; t < end; t += 5) {
        if (gate.MayRun(t, /*busy=*/true)) {
            if (slices++ == 0) first_slice = t;
            starts.push_back(t);
        }
    }
    // Nothing for MAX_DEFER_MS, then one slice per FORCED_INTERVAL_MS: the
    // worker makes progress and the validation thread keeps most of the time.
    BOOST_CHECK_EQUAL(first_slice, 1000 + DisplayBusyGate::MAX_DEFER_MS);
    BOOST_CHECK_GE(slices, 9);
    BOOST_CHECK_LE(slices, 11);
    for (size_t i = 1; i < starts.size(); ++i) {
        BOOST_CHECK_GE(starts[i] - starts[i - 1], DisplayBusyGate::FORCED_INTERVAL_MS);
    }
    BOOST_CHECK(gate.Forced());
    // A quiet moment ends the forced mode; the next busy stretch is deferred
    // to for the full bound again.
    BOOST_CHECK(gate.MayRun(t, /*busy=*/false));
    BOOST_CHECK(!gate.Forced());
    const int64_t busy_again = t + 5;
    for (t = busy_again; t < busy_again + DisplayBusyGate::MAX_DEFER_MS; t += 5) {
        BOOST_CHECK(!gate.MayRun(t, /*busy=*/true));
    }
    BOOST_CHECK(gate.MayRun(t, /*busy=*/true));
}

// ---- Which wallet is served next (I3) --------------------------------------

namespace {
DisplayCandidate Candidate(bool needs_work, bool never_published, bool foreground,
                           int64_t last_publish_ms, int64_t last_served_ms, int64_t need_since_ms = 0)
{
    DisplayCandidate c;
    c.needs_work = needs_work;
    c.never_published = never_published;
    c.foreground = foreground;
    c.last_publish_ms = last_publish_ms;
    c.last_served_ms = last_served_ms;
    c.need_since_ms = need_since_ms;
    return c;
}
} // namespace

BOOST_AUTO_TEST_CASE(pick_never_published_then_foreground_then_oldest_snapshot)
{
    const int64_t now{100000};
    // Nothing needs work.
    BOOST_CHECK_EQUAL(PickDisplayWallet({}, now), -1);
    BOOST_CHECK_EQUAL(PickDisplayWallet({Candidate(false, true, true, 0, 0)}, now), -1);

    std::vector<DisplayCandidate> wallets{
        Candidate(true, false, false, /*last_publish_ms=*/5000, 0), // 0: background, old snapshot
        Candidate(true, false, true, 9000, 0),                      // 1: the wallet shown
        Candidate(true, true, false, 0, 0),                         // 2: never published
        Candidate(true, false, false, 3000, 0),                     // 3: background, oldest snapshot
        Candidate(false, true, false, 0, 0),                        // 4: never published, nothing to do (backing off)
    };
    BOOST_CHECK_EQUAL(PickDisplayWallet(wallets, now), 2);
    // Among wallets that never published, the one that is shown goes first.
    wallets.push_back(Candidate(true, true, true, 0, /*last_served_ms=*/99000));
    BOOST_CHECK_EQUAL(PickDisplayWallet(wallets, now), 5);
    wallets.pop_back();
    wallets[2].needs_work = false;
    BOOST_CHECK_EQUAL(PickDisplayWallet(wallets, now), 1);
    wallets[1].needs_work = false;
    BOOST_CHECK_EQUAL(PickDisplayWallet(wallets, now), 3);
    wallets[3].needs_work = false;
    BOOST_CHECK_EQUAL(PickDisplayWallet(wallets, now), 0);
    wallets[0].needs_work = false;
    BOOST_CHECK_EQUAL(PickDisplayWallet(wallets, now), -1);
}

BOOST_AUTO_TEST_CASE(pick_is_fair_among_wallets_that_never_published)
{
    // Thirty wallets that need a long warm-up each: every one gets a turn
    // before any gets a second one.
    std::vector<DisplayCandidate> wallets;
    for (int i = 0; i < 30; ++i) wallets.push_back(Candidate(true, true, false, 0, 0));
    std::vector<int> turns(wallets.size(), 0);
    int64_t now{1000};
    for (int round = 0; round < 90; ++round, now += 30) {
        const int pick = PickDisplayWallet(wallets, now);
        BOOST_REQUIRE(pick >= 0);
        ++turns[pick];
        wallets[pick].last_served_ms = now;
    }
    for (const int count : turns) BOOST_CHECK_EQUAL(count, 3);
}

BOOST_AUTO_TEST_CASE(pick_does_not_starve_the_wallet_shown)
{
    // Wallets that never published go first, but the wallet on screen is not
    // kept waiting behind them for more than DISPLAY_FOREGROUND_MAX_WAIT_MS.
    std::vector<DisplayCandidate> wallets;
    for (int i = 0; i < 30; ++i) wallets.push_back(Candidate(true, true, false, 0, 0));
    const int shown = static_cast<int>(wallets.size());
    wallets.push_back(Candidate(true, false, true, 500, 0, /*need_since_ms=*/1000));
    int64_t now{1000};
    int64_t shown_served_at{0};
    for (int round = 0; round < 1000 && shown_served_at == 0; ++round, now += 100) {
        const int pick = PickDisplayWallet(wallets, now);
        BOOST_REQUIRE(pick >= 0);
        wallets[pick].last_served_ms = now;
        if (pick == shown) shown_served_at = now;
    }
    BOOST_CHECK_EQUAL(shown_served_at, 1000 + DISPLAY_FOREGROUND_MAX_WAIT_MS);
    // Its wait starts again once it has been served.
    wallets[shown].need_since_ms = shown_served_at + 100;
    BOOST_CHECK(PickDisplayWallet(wallets, shown_served_at + 100) != shown);
}

// ---- The busy signal of the validation interface ---------------------------

BOOST_AUTO_TEST_CASE(scheduler_client_is_busy_while_a_callback_is_blocked)
{
    CScheduler scheduler;
    std::thread service([&] { scheduler.serviceQueue(); });
    SingleThreadedSchedulerClient client{scheduler};
    BOOST_CHECK(!client.CallbacksBusy());

    std::promise<void> entered, release;
    client.AddToProcessQueue([&] {
        entered.set_value();
        release.get_future().wait(); // a callback waiting for a wallet lock
    });
    entered.get_future().wait();
    // Nothing is queued, and yet the validation interface is not idle: this
    // is the state the old yield signal read as quiet.
    BOOST_CHECK_EQUAL(client.CallbacksPending(), 0U);
    BOOST_CHECK(client.CallbacksBusy());
    std::this_thread::sleep_for(50ms);
    BOOST_CHECK(client.CallbacksBusy());

    std::promise<void> second_ran;
    client.AddToProcessQueue([&] { second_ran.set_value(); });
    BOOST_CHECK_EQUAL(client.CallbacksPending(), 1U);
    BOOST_CHECK(client.CallbacksBusy());

    release.set_value();
    second_ran.get_future().wait();
    for (int i = 0; i < 1000 && client.CallbacksBusy(); ++i) std::this_thread::sleep_for(1ms);
    BOOST_CHECK(!client.CallbacksBusy());

    scheduler.StopWhenDrained();
    service.join();
}

BOOST_FIXTURE_TEST_CASE(chain_reports_busy_while_a_validation_callback_is_blocked, TestingSetup)
{
    SyncWithValidationInterfaceQueue();
    BOOST_CHECK(!m_node.chain->validationCallbacksBusy());
    std::promise<void> entered, release;
    CallFunctionInValidationInterfaceQueue([&] {
        entered.set_value();
        release.get_future().wait();
    });
    entered.get_future().wait();
    BOOST_CHECK_EQUAL(GetMainSignals().CallbacksPending(), 0U);
    for (int i = 0; i < 20; ++i) {
        BOOST_CHECK(m_node.chain->validationCallbacksBusy());
        std::this_thread::sleep_for(2ms);
    }
    release.set_value();
    SyncWithValidationInterfaceQueue();
    BOOST_CHECK(!m_node.chain->validationCallbacksBusy());
}

// ---- The worker and the published snapshot ---------------------------------

namespace {
struct DisplayWalletSetup : public TestChain100Setup {
    std::shared_ptr<CWallet> wallet;
    WalletContext context;
    std::unique_ptr<interfaces::Wallet> iface;

    DisplayWalletSetup()
    {
        wallet.reset(CreateSyncedWallet(
            *m_node.chain,
            WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()),
            coinbaseKey).release());
        context.chain = m_node.chain.get();
        iface = interfaces::MakeWallet(context, wallet);
    }
    ~DisplayWalletSetup()
    {
        iface.reset();
        // The worker is gone with the last wallet that used it.
        BOOST_CHECK_EQUAL(DisplayBalanceWorker::Global().WalletCount(), 0U);
    }

    const CBlockIndex* Tip()
    {
        return WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain().Tip());
    }
    //! Mine a block; the wallet is told only when `notify` is set.
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
    CAmount PlainBalance()
    {
        Balance balance;
        WalletLifecycleSummary summary;
        std::string error;
        LOCK2(Assert(m_node.chainman)->GetMutex(), wallet->cs_wallet);
        BOOST_REQUIRE_MESSAGE(GetLifecycleAdjustedBalance(*wallet, 0, true, balance, summary, error), error);
        return balance.m_mine_trusted;
    }
};
} // namespace

BOOST_FIXTURE_TEST_CASE(snapshot_is_never_exact_for_a_tip_the_wallet_has_not_processed, DisplayWalletSetup)
{
    // Before anything was published.
    interfaces::WalletDisplayBalances shown = iface->getDisplaySnapshot();
    BOOST_CHECK(!shown.available || shown.block_hash == Tip()->GetBlockHash());

    interfaces::WalletDisplayBalances display;
    {
        DebugLogHelper first{"first balance ready after"};
        BOOST_REQUIRE(iface->tryGetDisplayBalances(display, std::nullopt, std::nullopt));
    }
    const uint256 tip0 = Tip()->GetBlockHash();
    const int height0 = Tip()->nHeight;
    BOOST_CHECK(display.available);
    BOOST_CHECK(display.exact);
    BOOST_CHECK(display.block_hash == tip0);
    BOOST_CHECK_EQUAL(display.block_height, height0);
    BOOST_CHECK_EQUAL(display.balances.balance, PlainBalance());
    BOOST_CHECK_GT(display.balances.balance, 0);
    // Nothing new for a caller that has this tip already.
    BOOST_CHECK(!iface->tryGetDisplayBalances(display, tip0, std::nullopt));

    // The chain moves; the wallet has not been told. The published snapshot
    // stays what it was, the balance of the last block the wallet processed,
    // and no balance appears for the new tip.
    const CBlock block = Mine();
    BOOST_REQUIRE(Tip()->GetBlockHash() != tip0);
    interfaces::WalletDisplayBalances unsynced;
    BOOST_CHECK(!iface->tryGetDisplayBalances(unsynced, std::nullopt, std::nullopt));
    for (int i = 0; i < 20; ++i) {
        shown = iface->getDisplaySnapshot();
        BOOST_REQUIRE(shown.available);
        BOOST_CHECK(shown.block_hash == tip0);
        BOOST_CHECK_EQUAL(shown.block_height, height0);
        BOOST_CHECK_EQUAL(shown.balances.balance, display.balances.balance);
        std::this_thread::sleep_for(5ms);
    }

    // The wallet processes the block. From this moment the old snapshot is
    // reported as stale, whether or not the worker has had a turn.
    Notify(block);
    shown = iface->getDisplaySnapshot();
    BOOST_CHECK(shown.available);
    BOOST_CHECK(shown.exact == (shown.block_hash == Tip()->GetBlockHash()));
    if (shown.block_hash == tip0) BOOST_CHECK(!shown.exact);

    BOOST_REQUIRE(iface->tryGetDisplayBalances(display, tip0, std::nullopt));
    BOOST_CHECK(display.exact);
    BOOST_CHECK(display.block_hash == Tip()->GetBlockHash());
    BOOST_CHECK_EQUAL(display.block_height, height0 + 1);
    BOOST_CHECK_EQUAL(display.balances.balance, PlainBalance());
    BOOST_CHECK_GT(display.sequence, shown.block_hash == tip0 ? shown.sequence : 0U);
}

BOOST_FIXTURE_TEST_CASE(worker_publishes_for_the_wallet_shown_and_announces_it, DisplayWalletSetup)
{
    std::atomic<int> announced{0};
    const std::unique_ptr<interfaces::Handler> handler = iface->handleDisplayBalancesChanged([&] { ++announced; });
    // No synchronous request: the wallet is the one shown, and the worker
    // gives it a snapshot by itself.
    iface->requestDisplayBalances(/*foreground=*/true, std::nullopt, /*retry_send=*/false);
    interfaces::WalletDisplayBalances shown;
    for (int i = 0; i < 2000; ++i) {
        shown = iface->getDisplaySnapshot();
        if (shown.available) break;
        std::this_thread::sleep_for(5ms);
    }
    BOOST_REQUIRE(shown.available);
    BOOST_CHECK(shown.exact);
    BOOST_CHECK_GE(announced.load(), 1);
    BOOST_CHECK_EQUAL(shown.balances.balance, PlainBalance());

    // A wallet change is picked up without anybody asking again.
    const uint64_t sequence = shown.sequence;
    const CBlock block = Mine();
    Notify(block);
    for (int i = 0; i < 2000; ++i) {
        shown = iface->getDisplaySnapshot();
        if (shown.exact && shown.sequence != sequence) break;
        std::this_thread::sleep_for(5ms);
    }
    BOOST_CHECK(shown.exact);
    BOOST_CHECK(shown.block_hash == Tip()->GetBlockHash());
    BOOST_CHECK_EQUAL(shown.balances.balance, PlainBalance());
    BOOST_CHECK_GE(announced.load(), 2);
    handler->disconnect();
}

BOOST_FIXTURE_TEST_CASE(worker_defers_to_a_blocked_validation_callback, DisplayWalletSetup)
{
    SyncWithValidationInterfaceQueue();
    std::promise<void> entered, release;
    CallFunctionInValidationInterfaceQueue([&] {
        entered.set_value();
        release.get_future().wait();
    });
    entered.get_future().wait();
    // The validation interface is executing a callback (which, on a real
    // node, may be waiting for the very wallet lock a slice would take): no
    // slice starts, so no balance arrives.
    auto request = std::async(std::launch::async, [&] {
        interfaces::WalletDisplayBalances display;
        return iface->tryGetDisplayBalances(display, std::nullopt, std::nullopt);
    });
    BOOST_CHECK(request.wait_for(400ms) == std::future_status::timeout);
    BOOST_CHECK(!iface->getDisplaySnapshot().available);
    release.set_value();
    BOOST_REQUIRE(request.wait_for(20s) == std::future_status::ready);
    BOOST_CHECK(request.get());
    BOOST_CHECK(iface->getDisplaySnapshot().available);
    SyncWithValidationInterfaceQueue();
}

BOOST_FIXTURE_TEST_CASE(send_family_balance_and_sliced_worker_passes, DisplayWalletSetup)
{
    // The worker computes the same balance however small its slices are.
    iface->getDisplaySnapshot(); // puts the wallet on the worker
    {
        const std::shared_ptr<WalletDisplayBalance> state = DisplayBalanceWorker::Global().Acquire(*wallet);
        LifecycleSliceLimits limits = LifecycleSliceLimits::Unlimited();
        limits.max_items = 2;
        state->SetSliceLimitsForTest(limits);
        DisplayBalanceWorker::Global().Release(*wallet);
    }
    // Whatever the worker has published so far is out of date now.
    WITH_LOCK(wallet->cs_wallet, wallet->BumpBalanceScanMarker());
    CCoinControl legacy;
    legacy.m_input_family = CCoinControl::InputFamily::LEGACY;
    const CAmount legacy_total = iface->getAvailableBalance(legacy);
    BOOST_CHECK_GT(legacy_total, 0);
    interfaces::WalletDisplayBalances display;
    BOOST_REQUIRE(iface->tryGetDisplayBalances(display, std::nullopt, interfaces::WalletDisplayCoinFamily::LEGACY));
    BOOST_CHECK_EQUAL(display.balances.balance, PlainBalance());
    BOOST_CHECK(display.send_family == interfaces::WalletDisplayCoinFamily::LEGACY);
    BOOST_CHECK_EQUAL(display.send_family_balance.value_or(-1), legacy_total);
    // The published snapshot carries it for the GUI.
    const interfaces::WalletDisplayBalances shown = iface->getDisplaySnapshot();
    BOOST_CHECK_EQUAL(shown.send_family_balance.value_or(-1), legacy_total);

    // Two interfaces to one wallet share one display state; the wallet stays
    // on the worker until the last one is gone.
    std::unique_ptr<interfaces::Wallet> second = interfaces::MakeWallet(context, wallet);
    BOOST_CHECK(second->getDisplaySnapshot().available);
    BOOST_CHECK_EQUAL(DisplayBalanceWorker::Global().WalletCount(), 1U);
    second.reset();
    BOOST_CHECK_EQUAL(DisplayBalanceWorker::Global().WalletCount(), 1U);
    BOOST_CHECK(iface->getDisplaySnapshot().available);
}

BOOST_FIXTURE_TEST_CASE(releasing_a_wallet_stops_the_worker_promptly, DisplayWalletSetup)
{
    iface->requestDisplayBalances(/*foreground=*/true, std::nullopt, /*retry_send=*/false);
    BOOST_CHECK_EQUAL(DisplayBalanceWorker::Global().WalletCount(), 1U);
    // Keep the wallet changing so that the worker always has something to
    // do, then take the wallet away in the middle of it.
    std::atomic<bool> stop{false};
    std::thread churn([&] {
        while (!stop) {
            WITH_LOCK(wallet->cs_wallet, wallet->BumpBalanceScanMarker());
            std::this_thread::sleep_for(1ms);
        }
    });
    std::this_thread::sleep_for(100ms);
    const auto start = std::chrono::steady_clock::now();
    iface.reset();
    const auto took = std::chrono::steady_clock::now() - start;
    stop = true;
    churn.join();
    BOOST_CHECK_EQUAL(DisplayBalanceWorker::Global().WalletCount(), 0U);
    BOOST_CHECK_LT(std::chrono::duration_cast<std::chrono::milliseconds>(took).count(), 2000);
    // The wallet can be used, and destroyed, without the worker.
    BOOST_CHECK_GT(PlainBalance(), 0);
    // A new interface starts the worker again.
    iface = interfaces::MakeWallet(context, wallet);
    interfaces::WalletDisplayBalances display;
    BOOST_REQUIRE(iface->tryGetDisplayBalances(display, std::nullopt, std::nullopt));
    BOOST_CHECK_EQUAL(display.balances.balance, PlainBalance());
}

BOOST_FIXTURE_TEST_CASE(worker_survives_a_throwing_job_and_serves_the_next_wallet, DisplayWalletSetup)
{
    std::shared_ptr<CWallet> second{CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()),
        coinbaseKey).release()};
    std::unique_ptr<interfaces::Wallet> second_iface = interfaces::MakeWallet(context, second);

    const std::shared_ptr<WalletDisplayBalance> state = DisplayBalanceWorker::Global().Acquire(*wallet);
    state->SetJobFaultForTest([] { throw std::runtime_error("injected display job failure"); });
    {
        DebugLogHelper failed{"GUI balance worker job failed: injected display job failure"};
        const DisplayBalanceOutcome outcome = state->RequestAndWait(
            std::nullopt, 20s, [] { DisplayBalanceWorker::Global().Wake(); });
        // The caller gets the failure at once, not a timeout, and the wallet is marked failed.
        BOOST_CHECK(!outcome.ok);
        BOOST_CHECK(outcome.exception);
        BOOST_CHECK(state->Failed());
    }
    // The worker thread is still alive and serves the next wallet.
    interfaces::WalletDisplayBalances display;
    BOOST_REQUIRE(second_iface->tryGetDisplayBalances(display, std::nullopt, std::nullopt));
    BOOST_CHECK(display.available);
    BOOST_CHECK_GT(display.balances.balance, 0);
    state->SetJobFaultForTest(nullptr);
    DisplayBalanceWorker::Global().Release(*wallet);
    second_iface.reset();
}

BOOST_FIXTURE_TEST_CASE(releasing_a_wallet_completes_outstanding_requests_as_failed, DisplayWalletSetup)
{
    SyncWithValidationInterfaceQueue();
    std::promise<void> entered, release;
    CallFunctionInValidationInterfaceQueue([&] {
        entered.set_value();
        release.get_future().wait();
    });
    entered.get_future().wait();
    // While the validation interface is blocked no pass starts, so the request stays outstanding.
    const std::shared_ptr<WalletDisplayBalance> state = DisplayBalanceWorker::Global().Acquire(*wallet);
    auto request = std::async(std::launch::async, [&] {
        return state->RequestAndWait(std::nullopt, 20s, [] { DisplayBalanceWorker::Global().Wake(); });
    });
    BOOST_CHECK(request.wait_for(300ms) == std::future_status::timeout);
    const auto start = std::chrono::steady_clock::now();
    DisplayBalanceWorker::Global().Release(*wallet);
    iface.reset();
    BOOST_REQUIRE(request.wait_for(5s) == std::future_status::ready);
    BOOST_CHECK(std::chrono::steady_clock::now() - start < 5s);
    const DisplayBalanceOutcome outcome = request.get();
    BOOST_CHECK(!outcome.ok);
    // A request made after the wallet left the worker fails at once too.
    BOOST_CHECK(!state->RequestAndWait(std::nullopt, 20s, [] {}).ok);
    release.set_value();
    SyncWithValidationInterfaceQueue();
}

BOOST_AUTO_TEST_SUITE_END()
} // namespace wallet
