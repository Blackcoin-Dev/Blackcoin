// Copyright (c) 2026 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <wallet/display_balance.h>

#include <coins.h>
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

// ---- The state of a snapshot ------------------------------------------------

BOOST_AUTO_TEST_CASE(display_state_names_and_log_cadence)
{
    DisplayBalanceSnapshot snapshot;
    snapshot.tip_height = 100;
    snapshot.tip_hash = uint256::ONE;
    snapshot.marker = 7;
    const uint256 other{uint256::ZERO};
    const auto classify = [&](const DisplayBalanceSnapshot* s, bool failed, bool marker_current, int height,
                              std::optional<uint256> hash) {
        return ClassifyDisplayBalance(s, failed, marker_current, height, hash);
    };

    // Nothing published; an error.
    auto state = classify(nullptr, false, false, 100, std::nullopt);
    BOOST_CHECK_EQUAL(state.ToString(), "none");
    BOOST_CHECK_EQUAL(state.SummaryIntervalMs(), WalletDisplayBalance::SUMMARY_INTERVAL_STALE_MS);
    state = classify(&snapshot, true, true, 100, uint256::ONE);
    BOOST_CHECK_EQUAL(state.ToString(), "failed");
    BOOST_CHECK_EQUAL(state.SummaryIntervalMs(), WalletDisplayBalance::SUMMARY_INTERVAL_EXACT_MS);

    // The block of the wallet and an unchanged wallet: exact.
    state = classify(&snapshot, false, true, 100, uint256::ONE);
    BOOST_CHECK_EQUAL(state.ToString(), "exact");
    BOOST_CHECK_EQUAL(state.SummaryIntervalMs(), WalletDisplayBalance::SUMMARY_INTERVAL_EXACT_MS);

    // The same block, but the wallet changed since: current-unverified, and
    // never "stale": it is of the block the wallet has processed.
    state = classify(&snapshot, false, false, 100, uint256::ONE);
    BOOST_CHECK_EQUAL(state.ToString(), "current-unverified");
    BOOST_CHECK_EQUAL(state.SummaryIntervalMs(), WalletDisplayBalance::SUMMARY_INTERVAL_EXACT_MS);
    // Without the hash the height alone says the same.
    BOOST_CHECK_EQUAL(classify(&snapshot, false, false, 100, std::nullopt).ToString(), "current-unverified");
    // Reference unknown: only the marker is judged.
    BOOST_CHECK_EQUAL(classify(&snapshot, false, true, -1, std::nullopt).ToString(), "exact");
    BOOST_CHECK_EQUAL(classify(&snapshot, false, false, -1, std::nullopt).ToString(), "current-unverified");

    // Blocks behind, whatever the marker says; a minute between lines.
    state = classify(&snapshot, false, true, 103, std::nullopt);
    BOOST_CHECK_EQUAL(state.ToString(), "behind(3)");
    BOOST_CHECK_EQUAL(state.behind_blocks, 3);
    BOOST_CHECK_EQUAL(state.SummaryIntervalMs(), WalletDisplayBalance::SUMMARY_INTERVAL_STALE_MS);
    BOOST_CHECK_EQUAL(classify(&snapshot, false, false, 101, std::nullopt).ToString(), "behind(1)");
    // Same height, other block (a reorg): behind by at least one.
    BOOST_CHECK_EQUAL(classify(&snapshot, false, true, 100, other).ToString(), "behind(1)");
    // A snapshot ahead of the reference is not behind.
    BOOST_CHECK_EQUAL(classify(&snapshot, false, true, 99, std::nullopt).ToString(), "exact");

    // A wallet that is not shown is recomputed at most once a minute, so it
    // is routinely a block or two behind: that is logged at the ten minute
    // cadence. The wallet on screen, and any wallet three or more blocks
    // behind, is logged every minute.
    for (const int behind : {1, 2}) {
        state = classify(&snapshot, false, true, 100 + behind, std::nullopt);
        BOOST_CHECK_EQUAL(state.behind_blocks, behind);
        BOOST_CHECK_EQUAL(state.SummaryIntervalMs(/*foreground=*/false), WalletDisplayBalance::SUMMARY_INTERVAL_EXACT_MS);
        BOOST_CHECK_EQUAL(state.SummaryIntervalMs(/*foreground=*/true), WalletDisplayBalance::SUMMARY_INTERVAL_STALE_MS);
    }
    state = classify(&snapshot, false, true, 100 + WalletDisplayBalance::BEHIND_LOG_MIN_BLOCKS, std::nullopt);
    BOOST_CHECK_EQUAL(state.SummaryIntervalMs(/*foreground=*/false), WalletDisplayBalance::SUMMARY_INTERVAL_STALE_MS);
    // Nothing published is reported every minute whichever wallet it is.
    BOOST_CHECK_EQUAL(classify(nullptr, false, false, 100, std::nullopt).SummaryIntervalMs(false),
                      WalletDisplayBalance::SUMMARY_INTERVAL_STALE_MS);
}

BOOST_FIXTURE_TEST_CASE(worker_log_line_measures_state_and_age_against_the_same_block, DisplayWalletSetup)
{
    // A snapshot is published, then the wallet processes two more blocks while
    // this wallet has no turn. The line used to read "state=behind(2) ...
    // snapshot_age_blocks=0": the state was measured against the wallet's last
    // processed block and the age against the tip the worker saw when it last
    // started a pass of this wallet.
    const auto state = std::make_shared<WalletDisplayBalance>(*wallet);
    state->RunJob([] { return true; });
    const auto published = state->Snapshot();
    BOOST_REQUIRE(published);
    const int height = published->tip_height;
    BOOST_CHECK_EQUAL(state->State(height, published->tip_hash).ToString(), "exact");
    Notify(Mine());
    Notify(Mine());
    BOOST_CHECK_EQUAL(state->State(height + 2, std::nullopt).ToString(), "behind(2)");

    int lines{0};
    const auto count_lines = LogInstance().PushBackCallback([&](const std::string& text) {
        if (text.find("GUI balance worker: wallet=") != std::string::npos) ++lines;
    });
    const int64_t base = WalletDisplayBalance::NowMs();
    // Not shown and two blocks behind: nothing at the minute cadence.
    state->MaybeLogSummary(base + WalletDisplayBalance::SUMMARY_INTERVAL_STALE_MS + 1000);
    BOOST_CHECK_EQUAL(lines, 0);
    // Shown: the minute cadence, and state and age agree.
    state->SetInterest(/*foreground=*/true, std::nullopt, /*retry_send=*/false);
    {
        ASSERT_DEBUG_LOG(strprintf("state=behind(2) snapshot_height=%d wallet_height=%d snapshot_age_blocks=2 ", height, height + 2));
        state->MaybeLogSummary(base + WalletDisplayBalance::SUMMARY_INTERVAL_STALE_MS + 2000);
    }
    BOOST_CHECK_EQUAL(lines, 1);
    // Not shown again: the ten minute cadence.
    state->SetInterest(/*foreground=*/false, std::nullopt, /*retry_send=*/false);
    state->MaybeLogSummary(base + 3 * WalletDisplayBalance::SUMMARY_INTERVAL_STALE_MS);
    BOOST_CHECK_EQUAL(lines, 1);
    {
        ASSERT_DEBUG_LOG("state=behind(2) ");
        state->MaybeLogSummary(base + WalletDisplayBalance::SUMMARY_INTERVAL_STALE_MS + WalletDisplayBalance::SUMMARY_INTERVAL_EXACT_MS + 3000);
    }
    BOOST_CHECK_EQUAL(lines, 2);
    // A new snapshot of the wallet's block: exact, age zero.
    state->RunJob([] { return true; });
    {
        ASSERT_DEBUG_LOG(strprintf("state=exact snapshot_height=%d wallet_height=%d snapshot_age_blocks=0 ", height + 2, height + 2));
        state->MaybeLogSummary(base + 3 * WalletDisplayBalance::SUMMARY_INTERVAL_EXACT_MS);
    }
    LogInstance().DeleteCallback(count_lines);
}

BOOST_FIXTURE_TEST_CASE(wallet_slice_stays_within_its_budget_plus_the_record_it_is_on, DisplayWalletSetup)
{
    // What a record costs depends on memory the slice cannot see: cached
    // amounts that were invalidated, pages the system compressed. Here every
    // cached amount is invalid and the injected clock charges each item of a
    // slice (a record, one of its outputs, a memo entry): cheap at first, then
    // 3 ms each, as when the walk reaches memory that has to be brought back.
    // The meter used to read the clock every 64 items; those 64 items would
    // hold cs_wallet for 190 ms against a 20 ms budget (the field saw 1.4 s).
    wallet->MarkDirty();
    size_t records{0};
    uint64_t largest_bucket_items{0};
    {
        LOCK(wallet->cs_wallet);
        records = wallet->mapWallet.size();
        for (size_t bucket = 0; bucket < wallet->mapWallet.bucket_count(); ++bucket) {
            uint64_t items{0};
            for (auto it = wallet->mapWallet.begin(bucket); it != wallet->mapWallet.end(bucket); ++it) {
                items += 1 + it->second.tx->vout.size();
            }
            largest_bucket_items = std::max(largest_bucket_items, items);
        }
    }
    BOOST_REQUIRE_GT(records, 64U);
    BOOST_REQUIRE_GT(largest_bucket_items, 0U);

    std::chrono::steady_clock::time_point clock{};
    uint64_t items{0};
    const auto item_cost = [&] { return items <= 40 ? std::chrono::microseconds{10} : std::chrono::microseconds{3ms}; };
    LifecycleSliceLimits limits;
    limits.now = [&] { return clock; };
    limits.on_item = [&] {
        ++items;
        clock += item_cost();
    };
    const auto wallet_bound = std::chrono::microseconds{limits.wallet_budget} + largest_bucket_items * std::chrono::microseconds{3ms};
    // A chainstate slice ends early only after four items.
    const auto main_bound = std::chrono::microseconds{limits.main_budget} + 3 * std::chrono::microseconds{3ms};

    LifecyclePass pass;
    LifecycleMemoJournal journal;
    LifecycleAttestationCache attestations;
    int wallet_slices{0}, main_slices{0};
    std::chrono::microseconds longest_wallet{0};
    LifecycleSliceReport report;
    for (int guard = 0; guard < 100000; ++guard) {
        report = RunLifecyclePassSlice(*wallet, pass, journal, attestations, limits);
        BOOST_REQUIRE_MESSAGE(report.result != LifecycleSliceResult::FAILED, report.error);
        if (report.held_wallet) {
            ++wallet_slices;
            longest_wallet = std::max(longest_wallet, report.held);
            BOOST_CHECK_LE(report.held.count(), wallet_bound.count());
        }
        if (report.held_main) {
            ++main_slices;
            BOOST_CHECK_LE(report.held.count(), main_bound.count());
        }
        if (report.result == LifecycleSliceResult::DONE) break;
    }
    BOOST_REQUIRE(report.result == LifecycleSliceResult::DONE);
    // The budget was what ended the slices: many of them, each near the budget.
    BOOST_CHECK_GT(wallet_slices, 10);
    BOOST_CHECK_GT(main_slices, 0);
    BOOST_CHECK_GE(longest_wallet.count(), std::chrono::microseconds{limits.wallet_budget}.count());
    BOOST_CHECK_LE(longest_wallet.count(), wallet_bound.count());
    // Slicing changes nothing about the result.
    BOOST_CHECK_EQUAL(pass.balance.m_mine_trusted, PlainBalance());
}

BOOST_FIXTURE_TEST_CASE(worker_log_line_uses_the_new_states, DisplayWalletSetup)
{
    // Nothing published yet: "none", logged at the minute cadence.
    const auto state = std::make_shared<WalletDisplayBalance>(*wallet);
    const int64_t base = WalletDisplayBalance::NowMs();
    {
        // Not due yet.
        state->MaybeLogSummary(base + WalletDisplayBalance::SUMMARY_INTERVAL_STALE_MS / 2);
    }
    {
        ASSERT_DEBUG_LOG("state=none snapshot_height=-1");
        state->MaybeLogSummary(base + WalletDisplayBalance::SUMMARY_INTERVAL_STALE_MS + 1000);
    }
    {
        ASSERT_DEBUG_LOG("state=none snapshot_height=-1");
        state->MaybeLogSummary(base + 2 * WalletDisplayBalance::SUMMARY_INTERVAL_STALE_MS + 2000);
    }
}

// ---- The meter of a cs_main slice ----------------------------------------------

namespace {
/** A coins view whose every read takes `per_read` of an injected clock. */
class SlowCoinsView final : public CCoinsView
{
public:
    SlowCoinsView(std::chrono::steady_clock::time_point& clock, std::chrono::microseconds per_read)
        : m_clock(clock), m_per_read(per_read) {}
    bool GetCoin(const COutPoint&, Coin&) const override
    {
        ++reads;
        m_clock += m_per_read;
        return false;
    }
    uint256 GetBestBlock() const override { return {}; }
    mutable uint64_t reads{0};

private:
    std::chrono::steady_clock::time_point& m_clock;
    const std::chrono::microseconds m_per_read;
};
} // namespace

BOOST_AUTO_TEST_CASE(slice_meter_stays_within_its_budget_plus_one_chainstate_item)
{
    // An item that misses the memo makes up to three uncached chainstate
    // reads (the coin, the payout status, the attestation); here each read
    // costs 4 ms against a 25 ms budget, so an item costs 12 ms. Items are
    // metered one by one: the old rule (a clock reading every 16 items)
    // would run on for 16 items, nearly 200 ms.
    std::chrono::steady_clock::time_point clock{};
    const auto start = clock;
    uint64_t clock_reads{0};
    LifecycleSliceLimits limits;
    limits.now = [&] {
        ++clock_reads;
        return clock;
    };
    const std::chrono::milliseconds budget{25};
    SlowCoinsView slow{clock, 4ms};
    CCoinsViewCache view{&slow};
    SliceMeter meter{limits, budget};
    uint32_t n{0};
    while (!meter.Expired()) {
        for (int read = 0; read < 3; ++read) {
            Coin coin;
            view.GetCoin(COutPoint{uint256{static_cast<uint8_t>(n + 1)}, static_cast<uint32_t>(read)}, coin);
        }
        meter.TickChainItem();
        ++n;
        BOOST_REQUIRE_LT(n, 100U);
    }
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(clock - start);
    const auto largest_item = 12ms;
    BOOST_CHECK_LE(elapsed.count(), (budget + largest_item).count());
    // Fewer than four items were done, so the remaining budget (1 ms after two
    // items) is not used to end the slice early: it ends when the budget is
    // used up, at 36 ms after three items, within the budget plus one item.
    BOOST_CHECK_EQUAL(n, 3U);
    BOOST_CHECK_GT(elapsed.count(), budget.count());
    BOOST_CHECK_EQUAL(meter.MaxChainItem().count(), std::chrono::microseconds{12ms}.count());
    BOOST_CHECK_EQUAL(slow.reads, 9U);
    // The clock was read once per chainstate item, plus once at the start.
    BOOST_CHECK_EQUAL(clock_reads, 1U + n);
}

BOOST_AUTO_TEST_CASE(slice_meter_bounds_a_slice_whose_items_get_slower)
{
    // The first items are cheap and teach the meter nothing about the one
    // that follows: the slice may overrun by that one item, never by more.
    std::chrono::steady_clock::time_point clock{};
    const auto start = clock;
    LifecycleSliceLimits limits;
    limits.now = [&] { return clock; };
    const std::chrono::milliseconds budget{25};
    SliceMeter meter{limits, budget};
    const std::vector<std::chrono::milliseconds> costs{1ms, 1ms, 1ms, 1ms, 40ms, 1ms, 1ms};
    size_t done{0};
    for (const auto cost : costs) {
        if (meter.Expired()) break;
        clock += cost;
        meter.TickChainItem();
        ++done;
    }
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(clock - start);
    BOOST_CHECK_EQUAL(done, 5U); // ends after the 40 ms item
    BOOST_CHECK_LE(elapsed.count(), (budget + 40ms).count());
    BOOST_CHECK(meter.Expired());
    BOOST_CHECK_EQUAL(meter.MaxChainItem().count(), std::chrono::microseconds{40ms}.count());

    // A seed from the previous slice of the pass makes the next slice stop
    // sooner: half of a 40 ms item leaves no room for another item once
    // 6 ms have passed, but only after four items were done in the slice.
    clock = start;
    SliceMeter next{limits, budget};
    next.SeedMaxChainItem(40ms);
    clock += 4ms;
    BOOST_CHECK(!next.TickChainItem()); // 4 + 20 < 25
    clock += 2ms;
    BOOST_CHECK(!next.TickChainItem()); // 6 + 20 > 25, but only two items so far
    BOOST_CHECK(!next.TickChainItem()); // three
    BOOST_CHECK(next.TickChainItem());  // four items and no room for another
}

BOOST_AUTO_TEST_CASE(slice_meter_makes_progress_with_a_very_slow_view)
{
    // Items that cost more than half the budget used to end every slice after
    // one item (the predicted overrun), and slices are spaced by the worker's
    // forced interval. A slice now keeps going until four items are done or
    // the budget is used up.
    const std::chrono::milliseconds budget{25};
    const auto run_slice = [&](std::chrono::milliseconds cost, std::chrono::milliseconds seed) {
        std::chrono::steady_clock::time_point clock{};
        const auto start = clock;
        LifecycleSliceLimits limits;
        limits.now = [&] { return clock; };
        SliceMeter meter{limits, budget};
        meter.SeedMaxChainItem(seed);
        uint32_t items{0};
        while (!meter.Expired()) {
            clock += cost;
            meter.TickChainItem();
            ++items;
            BOOST_REQUIRE_LT(items, 100U);
        }
        const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(clock - start);
        // Budget plus the cost of at most three more items.
        BOOST_CHECK_LE(elapsed.count(), (budget + 3 * cost).count());
        return items;
    };
    // 10 ms items after a slice that saw a 60 ms item: the old rule stopped
    // after the first (10 + 30 > 25); now three are done (30 ms >= 25 ms).
    BOOST_CHECK_EQUAL(run_slice(10ms, 60ms), 3U);
    // 14 ms items against a 25 ms budget: two items use it up.
    BOOST_CHECK_EQUAL(run_slice(14ms, 28ms), 2U);
    // A single item that costs more than the whole budget still ends the slice,
    // after it, with progress made.
    BOOST_CHECK_EQUAL(run_slice(40ms, 80ms), 1U);
    // Ordinary costs still stop near the budget: 1 ms items run to the 25 ms budget.
    BOOST_CHECK_EQUAL(run_slice(1ms, 0ms), 25U);
}

BOOST_AUTO_TEST_CASE(slice_meter_reads_the_clock_every_16_items_for_memo_hits)
{
    std::chrono::steady_clock::time_point clock{};
    uint64_t clock_reads{0};
    LifecycleSliceLimits limits;
    limits.now = [&] {
        ++clock_reads;
        return clock;
    };
    SliceMeter meter{limits, std::chrono::milliseconds{25}};
    BOOST_CHECK_EQUAL(clock_reads, 1U); // the start
    for (int i = 0; i < 15; ++i) BOOST_CHECK(!meter.Tick(16));
    BOOST_CHECK_EQUAL(clock_reads, 1U);
    BOOST_CHECK(!meter.Tick(16));
    BOOST_CHECK_EQUAL(clock_reads, 2U);
    // A memo-hit run does not teach the meter anything about chainstate cost.
    BOOST_CHECK_EQUAL(meter.MaxChainItem().count(), 0);
    // Once the time is up the 16th item ends the slice.
    clock += 30ms;
    for (int i = 0; i < 15; ++i) BOOST_CHECK(!meter.Tick(16));
    BOOST_CHECK(meter.Tick(16));
    // An item limit still ends it at once.
    LifecycleSliceLimits limited;
    limited.max_items = 2;
    SliceMeter by_items{limited, std::chrono::milliseconds{0}};
    BOOST_CHECK(!by_items.TickChainItem());
    BOOST_CHECK(by_items.TickChainItem());
}

BOOST_AUTO_TEST_SUITE_END()
} // namespace wallet
