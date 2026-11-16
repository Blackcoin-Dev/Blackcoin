// Copyright (c) 2026 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <wallet/block_connect_activity.h>

#include <boost/test/unit_test.hpp>

#include <atomic>
#include <chrono>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <vector>

namespace wallet {
BOOST_AUTO_TEST_SUITE(block_connect_activity_tests)

BOOST_AUTO_TEST_CASE(no_activity_never_defers)
{
    BlockConnectActivity a;
    BOOST_CHECK(!a.ShouldDefer(1000));
}

BOOST_AUTO_TEST_CASE(defers_while_fresh_then_releases_when_quiet)
{
    BlockConnectActivity a;
    a.Note(1000);
    BOOST_CHECK(a.ShouldDefer(1100));
    BOOST_CHECK(a.ShouldDefer(1500));
    BOOST_CHECK(!a.ShouldDefer(1000 + BlockConnectActivity::QUIET_MS));
}

BOOST_AUTO_TEST_CASE(continuous_activity_lets_one_poll_through_every_max_defer)
{
    BlockConnectActivity a;
    int64_t t = 1000;
    a.Note(t);
    BOOST_CHECK(a.ShouldDefer(t)); // starts the deferral at t
    int allowed = 0;
    for (; t < 1000 + 3 * BlockConnectActivity::MAX_DEFER_MS; t += 250) {
        a.Note(t); // scheduler keeps working
        if (!a.ShouldDefer(t)) ++allowed;
    }
    // About one release per MAX_DEFER_MS plus the re-arming poll.
    BOOST_CHECK_GE(allowed, 2);
    BOOST_CHECK_LE(allowed, 3);
}

BOOST_AUTO_TEST_CASE(quiet_resets_the_defer_window)
{
    BlockConnectActivity a;
    a.Note(1000);
    BOOST_CHECK(a.ShouldDefer(1100));
    BOOST_CHECK(!a.ShouldDefer(5000)); // quiet for > QUIET_MS
    a.Note(6000);
    BOOST_CHECK(a.ShouldDefer(6100));  // a fresh window starts
}

BOOST_AUTO_TEST_CASE(is_dispatching_changes_no_state)
{
    BlockConnectActivity a;
    BOOST_CHECK(!a.IsDispatching(1000));
    a.Note(1000);
    BOOST_CHECK(a.IsDispatching(1000 + BlockConnectActivity::QUIET_MS - 1));
    BOOST_CHECK(!a.IsDispatching(1000 + BlockConnectActivity::QUIET_MS));
    // Asking never opens a deferral window: the first ShouldDefer still starts it.
    for (int i = 0; i < 100; ++i) BOOST_CHECK(a.IsDispatching(1100));
    BOOST_CHECK(a.ShouldDefer(1100));
}

namespace {
//! A clock the test moves by hand.
struct FakeClock {
    std::atomic<int64_t> now{1000};
    GuiBalanceScanQueue::Clock Get() { return [this] { return now.load(); }; }
};

//! Start `count` threads that each wait for a slot of `queue`, one after the
//! other so that their arrival order is known; each records `tag` when
//! admitted and releases at once.
struct OrderedWaiters {
    GuiBalanceScanQueue& queue;
    std::mutex mutex;
    std::vector<int> admitted_order;
    std::atomic<int> refused{0};
    std::vector<std::thread> threads;
    void Add(int tag, int64_t last_publish_ms)
    {
        const size_t before = queue.Waiting();
        threads.emplace_back([this, tag, last_publish_ms] {
            if (!queue.Acquire(last_publish_ms, 10000)) {
                ++refused;
                return;
            }
            {
                std::lock_guard<std::mutex> lock(mutex);
                admitted_order.push_back(tag);
            }
            queue.Release();
        });
        while (queue.Waiting() == before) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    void Join() { for (auto& t : threads) t.join(); }
};
} // namespace

BOOST_AUTO_TEST_CASE(gui_balance_scan_queue_single_flight)
{
    GuiBalanceScanQueue queue{1, /*backoff=*/true};
    BOOST_CHECK(queue.Acquire(0, 0));
    BOOST_CHECK(!queue.Acquire(0, 0)); // a second one is not admitted while the first runs
    BOOST_CHECK_EQUAL(queue.Running(), 1);
    BOOST_CHECK_EQUAL(queue.Waiting(), 0U); // a caller that gave up leaves the line
    queue.Release();
    BOOST_CHECK_EQUAL(queue.Running(), 0);
    BOOST_CHECK(queue.Acquire(0, 0));
    queue.Release();
}

BOOST_AUTO_TEST_CASE(gui_balance_scan_queue_admits_never_published_then_oldest_then_fifo)
{
    GuiBalanceScanQueue queue{1, /*backoff=*/false};
    BOOST_REQUIRE(queue.Acquire(0, 0)); // the slot is taken while the line forms
    OrderedWaiters w{queue};
    w.Add(1, 500);  // published, newer
    w.Add(2, 100);  // published, oldest
    w.Add(3, 0);    // never published, first of its kind
    w.Add(4, 300);  // published
    w.Add(5, 0);    // never published, second of its kind
    w.Add(6, 100);  // tie with 2: arrived later
    queue.Release();
    w.Join();
    BOOST_CHECK_EQUAL(w.refused.load(), 0);
    const std::vector<int> expected{3, 5, 2, 6, 4, 1};
    BOOST_CHECK_EQUAL_COLLECTIONS(w.admitted_order.begin(), w.admitted_order.end(), expected.begin(), expected.end());
    BOOST_CHECK_EQUAL(queue.Running(), 0);
    BOOST_CHECK_EQUAL(queue.Waiting(), 0U);
}

BOOST_AUTO_TEST_CASE(gui_balance_scan_queue_times_out_not_admitted)
{
    GuiBalanceScanQueue queue{1, /*backoff=*/false};
    BOOST_REQUIRE(queue.Acquire(0, 0));
    int64_t waited{-1};
    const auto start = std::chrono::steady_clock::now();
    BOOST_CHECK(!queue.Acquire(0, 60, {}, &waited));
    const auto real_ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - start).count();
    BOOST_CHECK_GE(real_ms, 50);
    BOOST_CHECK_LT(real_ms, 2000);
    BOOST_CHECK_GE(waited, 50);
    BOOST_CHECK_EQUAL(queue.Waiting(), 0U);
    BOOST_CHECK_EQUAL(queue.Running(), 1); // the holder is unaffected
    queue.Release();
}

BOOST_AUTO_TEST_CASE(gui_balance_scan_queue_gives_up_when_asked)
{
    GuiBalanceScanQueue queue{1, /*backoff=*/false};
    BOOST_REQUIRE(queue.Acquire(0, 0));
    std::atomic<int> polls{0};
    int64_t waited{-1};
    const auto start = std::chrono::steady_clock::now();
    BOOST_CHECK(!queue.Acquire(0, 60000, [&] { return ++polls >= 3; }, &waited));
    const auto real_ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - start).count();
    BOOST_CHECK_LT(real_ms, 5000); // long before the 60 s bound
    BOOST_CHECK_GE(polls.load(), 3);
    BOOST_CHECK_EQUAL(queue.Waiting(), 0U);
    // A caller that is let through is not asked to give up.
    queue.Release();
    BOOST_CHECK(queue.Acquire(0, 0, [] { return true; }));
    queue.Release();
}

BOOST_AUTO_TEST_CASE(gui_balance_scan_queue_backs_off_after_a_long_hold)
{
    FakeClock clock;
    GuiBalanceScanQueue queue{1, /*backoff=*/true, clock.Get()};
    // A hold under the threshold imposes nothing.
    BOOST_REQUIRE(queue.Acquire(0, 0));
    queue.Release(GuiBalanceScanQueue::BACKOFF_THRESHOLD_MS - 1);
    BOOST_REQUIRE(queue.Acquire(0, 0));
    // A hold of 400 ms: the next admission is not before release + 400 ms.
    queue.Release(400);
    BOOST_CHECK(!queue.Acquire(0, 0));
    clock.now += 399;
    BOOST_CHECK(!queue.Acquire(0, 0));
    clock.now += 1;
    BOOST_REQUIRE(queue.Acquire(0, 0));
    // A holder that reports no hold (it never took cs_main) imposes none, and
    // clears the earlier back-off.
    queue.Release(0);
    BOOST_REQUIRE(queue.Acquire(0, 0));
    // The back-off is clamped.
    queue.Release(60000);
    clock.now += GuiBalanceScanQueue::MAX_BACKOFF_MS - 1;
    BOOST_CHECK(!queue.Acquire(0, 0));
    clock.now += 1;
    BOOST_REQUIRE(queue.Acquire(0, 0));
    queue.Release(0);
    // A queue without the back-off ignores the hold.
    GuiBalanceScanQueue plain{1, /*backoff=*/false, clock.Get()};
    BOOST_REQUIRE(plain.Acquire(0, 0));
    plain.Release(5000);
    BOOST_CHECK(plain.Acquire(0, 0));
    plain.Release();
}

BOOST_AUTO_TEST_CASE(gui_balance_scan_queue_waits_out_the_back_off)
{
    // The wait for a back-off to end is a wait like any other: the caller is
    // admitted when the clock passes the end, not before.
    FakeClock clock;
    GuiBalanceScanQueue queue{1, /*backoff=*/true, clock.Get()};
    BOOST_REQUIRE(queue.Acquire(0, 0));
    queue.Release(300);
    std::atomic<bool> admitted{false};
    std::thread waiter([&] {
        admitted = queue.Acquire(0, 60000);
        if (admitted) queue.Release();
    });
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    BOOST_CHECK(!admitted);
    clock.now += 300;
    waiter.join();
    BOOST_CHECK(admitted);
}

BOOST_AUTO_TEST_CASE(gui_balance_scan_queue_phase_a_slot_limit)
{
    GuiBalanceScanQueue queue{GuiBalanceScanQueue::MAX_PHASE_A_WALLETS, /*backoff=*/false};
    BOOST_CHECK_EQUAL(GuiBalanceScanQueue::MAX_PHASE_A_WALLETS, 3);
    for (int i = 0; i < GuiBalanceScanQueue::MAX_PHASE_A_WALLETS; ++i) BOOST_REQUIRE(queue.Acquire(0, 0));
    BOOST_CHECK(!queue.Acquire(0, 0));
    BOOST_CHECK_EQUAL(queue.Running(), 3);
    queue.Release();
    BOOST_CHECK(queue.Acquire(0, 0));
    for (int i = 0; i < 3; ++i) queue.Release();
    BOOST_CHECK_EQUAL(queue.Running(), 0);

    // Many threads, never more than three at once.
    std::atomic<int> inside{0}, peak{0}, done{0}, refused{0};
    std::vector<std::thread> threads;
    for (int i = 0; i < 12; ++i) {
        threads.emplace_back([&, i] {
            for (int round = 0; round < 20; ++round) {
                if (!queue.Acquire(i, 30000)) {
                    ++refused;
                    continue;
                }
                const int now = ++inside;
                int p = peak.load();
                while (now > p && !peak.compare_exchange_weak(p, now)) {}
                std::this_thread::sleep_for(std::chrono::microseconds(200));
                --inside;
                queue.Release();
            }
            ++done;
        });
    }
    for (auto& t : threads) t.join();
    BOOST_CHECK_EQUAL(done.load(), 12);
    BOOST_CHECK_EQUAL(refused.load(), 0);
    BOOST_CHECK_LE(peak.load(), 3);
    BOOST_CHECK_GE(peak.load(), 2); // the slots really are used in parallel
}

BOOST_AUTO_TEST_CASE(gui_balance_scan_slot_releases_on_every_path)
{
    GuiBalanceScanQueue queue{1, /*backoff=*/true};
    {
        GuiBalanceScanSlot slot{queue, 0, 0};
        BOOST_CHECK(slot.Admitted());
        GuiBalanceScanSlot second{queue, 0, 0};
        BOOST_CHECK(!second.Admitted());
        // an early return: no hold reported, so no back-off
    }
    BOOST_CHECK_EQUAL(queue.Running(), 0);
    {
        GuiBalanceScanSlot again{queue, 0, 0};
        BOOST_CHECK(again.Admitted());
        again.Release(); // explicit, then the destructor must not release twice
        BOOST_CHECK_EQUAL(queue.Running(), 0);
        GuiBalanceScanSlot other{queue, 0, 0};
        BOOST_CHECK(other.Admitted());
        again.Release();
        BOOST_CHECK_EQUAL(queue.Running(), 1);
    }
    BOOST_CHECK_EQUAL(queue.Running(), 0);
    // The recorded stretches of cs_main add up and decide the back-off.
    FakeClock clock;
    GuiBalanceScanQueue timed{1, /*backoff=*/true, clock.Get()};
    {
        GuiBalanceScanSlot slot{timed, 0, 0};
        slot.AddMainHold(100);
        slot.AddMainHold(300);
    }
    BOOST_CHECK(!timed.Acquire(0, 0)); // 400 ms back-off from now
    clock.now += 400;
    BOOST_CHECK(timed.Acquire(0, 0));
    timed.Release();
    // An exception leaves the slot free too.
    try {
        GuiBalanceScanSlot slot{queue, 0, 0};
        BOOST_REQUIRE(slot.Admitted());
        throw std::runtime_error("scan failed");
    } catch (const std::runtime_error&) {}
    BOOST_CHECK_EQUAL(queue.Running(), 0);
}

BOOST_AUTO_TEST_CASE(gui_balance_scan_queue_stress_no_wallet_is_starved)
{
    // 34 wallet threads keep asking, as the 250 ms polls do. The wallet with
    // the oldest publish goes first, so turns are shared evenly, and the
    // cs_main phase is never held by two at once.
    constexpr int WALLETS{34};
    constexpr int TOTAL_TURNS{WALLETS * 40};
    GuiBalanceScanQueue main_phase{1, /*backoff=*/false};
    GuiBalanceScanQueue wallet_phase{GuiBalanceScanQueue::MAX_PHASE_A_WALLETS, /*backoff=*/false};
    std::atomic<int64_t> publish_clock{0};
    std::atomic<int> turns_total{0}, holders{0}, max_holders{0}, a_holders{0}, a_peak{0};
    std::vector<std::atomic<int64_t>> last_publish(WALLETS);
    std::vector<std::atomic<int>> turns(WALLETS);
    for (int i = 0; i < WALLETS; ++i) { last_publish[i] = 0; turns[i] = 0; }
    std::vector<std::thread> threads;
    for (int i = 0; i < WALLETS; ++i) {
        threads.emplace_back([&, i] {
            while (turns_total.load() < TOTAL_TURNS) {
                if (!wallet_phase.Acquire(last_publish[i], 100)) continue;
                const int a = ++a_holders;
                int ap = a_peak.load();
                while (a > ap && !a_peak.compare_exchange_weak(ap, a)) {}
                std::this_thread::sleep_for(std::chrono::microseconds(50));
                --a_holders;
                wallet_phase.Release();
                if (!main_phase.Acquire(last_publish[i], 100)) continue;
                const int h = ++holders;
                int m = max_holders.load();
                while (h > m && !max_holders.compare_exchange_weak(m, h)) {}
                std::this_thread::sleep_for(std::chrono::microseconds(100));
                --holders;
                ++turns[i];
                ++turns_total;
                last_publish[i] = ++publish_clock;
                main_phase.Release();
            }
        });
    }
    for (auto& t : threads) t.join();
    BOOST_CHECK_EQUAL(max_holders.load(), 1);
    BOOST_CHECK_LE(a_peak.load(), GuiBalanceScanQueue::MAX_PHASE_A_WALLETS);
    int min_turns{TOTAL_TURNS}, max_turns{0};
    for (int i = 0; i < WALLETS; ++i) {
        min_turns = std::min(min_turns, turns[i].load());
        max_turns = std::max(max_turns, turns[i].load());
    }
    BOOST_CHECK_GE(min_turns, 1);
    BOOST_CHECK_LE(max_turns, 2 * min_turns + 2);
    BOOST_CHECK_EQUAL(main_phase.Running(), 0);
    BOOST_CHECK_EQUAL(wallet_phase.Running(), 0);
}

BOOST_AUTO_TEST_CASE(gui_balance_scan_diagnostics_summary_and_first_balance)
{
    using Reason = GuiBalanceScanDiagnostics::Reason;
    GuiBalanceScanDiagnostics diag{1000};
    for (int i = 0; i < 5; ++i) diag.Attempt();
    diag.Count(Reason::DEFERRED);
    diag.Count(Reason::DEFERRED);
    diag.Count(Reason::MAIN_BUSY);
    diag.Count(Reason::GATE_TIMEOUT);
    BOOST_CHECK_EQUAL(diag.Counted(Reason::DEFERRED), 2U);
    // Not due yet.
    BOOST_CHECK(!diag.TakeWaitingSummary(1000 + GuiBalanceScanDiagnostics::SUMMARY_INTERVAL_MS - 1, "w", 7));
    const auto line = diag.TakeWaitingSummary(1000 + GuiBalanceScanDiagnostics::SUMMARY_INTERVAL_MS, "w", 7);
    BOOST_REQUIRE(line);
    BOOST_CHECK_EQUAL(*line, "GUI balance scan waiting: wallet=w since_load_s=60 attempts=5 deferred=2 main_busy=1 gate_timeout=1 memo_size=7");
    // Counters restart; at most one line per interval.
    BOOST_CHECK_EQUAL(diag.Counted(Reason::DEFERRED), 0U);
    BOOST_CHECK(!diag.TakeWaitingSummary(1000 + GuiBalanceScanDiagnostics::SUMMARY_INTERVAL_MS + 1, "w", 7));
    diag.Attempt();
    diag.Count(Reason::SLOT_TIMEOUT);
    const auto second = diag.TakeWaitingSummary(1000 + 2 * GuiBalanceScanDiagnostics::SUMMARY_INTERVAL_MS, "w", -1);
    BOOST_REQUIRE(second);
    BOOST_CHECK_EQUAL(*second, "GUI balance scan waiting: wallet=w since_load_s=120 attempts=1 slot_timeout=1 memo_size=unknown");
    // The first balance is reported once, with every attempt since load.
    BOOST_CHECK(!diag.HasPublished());
    const auto first = diag.OnPublished(1000 + 2 * GuiBalanceScanDiagnostics::SUMMARY_INTERVAL_MS + 5, "w");
    BOOST_REQUIRE(first);
    BOOST_CHECK_EQUAL(*first, "GUI balance scan: wallet=w first balance ready after 120005 ms (attempts=6)");
    BOOST_CHECK(!diag.OnPublished(1000 + 3 * GuiBalanceScanDiagnostics::SUMMARY_INTERVAL_MS, "w"));
    // Once published, no more waiting lines.
    BOOST_CHECK(diag.HasPublished());
    diag.Count(Reason::TIP_MOVED);
    BOOST_CHECK(!diag.TakeWaitingSummary(1000 + 10 * GuiBalanceScanDiagnostics::SUMMARY_INTERVAL_MS, "w", 1));
}

BOOST_AUTO_TEST_SUITE_END()
} // namespace wallet
