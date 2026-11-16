// Copyright (c) 2026 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <wallet/block_connect_activity.h>

#include <boost/test/unit_test.hpp>

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

BOOST_AUTO_TEST_CASE(gui_balance_scan_gate_backs_off_on_cs_main_time_only)
{
    // A scan that ran 5 s, of which only 40 ms with cs_main: no back-off.
    {
        GuiBalanceScanGate gate;
        BOOST_CHECK(gate.TryBegin(1000));
        gate.End(6000, /*scanned=*/true, /*held_ms=*/40);
        BOOST_CHECK(gate.TryBegin(6001));
        gate.End(6001, /*scanned=*/false);
    }
    // The same scan holding cs_main for 400 ms: the next waits 400 ms.
    {
        GuiBalanceScanGate gate;
        BOOST_CHECK(gate.TryBegin(1000));
        gate.End(6000, /*scanned=*/true, /*held_ms=*/400);
        BOOST_CHECK(!gate.TryBegin(6399));
        BOOST_CHECK(gate.TryBegin(6400));
        gate.End(6400, /*scanned=*/false);
    }
    // Without a held time the elapsed time counts, as before.
    {
        GuiBalanceScanGate gate;
        BOOST_CHECK(gate.TryBegin(1000));
        gate.End(1600);
        BOOST_CHECK(!gate.TryBegin(2199));
        BOOST_CHECK(gate.TryBegin(2200));
        gate.End(2200, /*scanned=*/false);
    }
}

BOOST_AUTO_TEST_CASE(gui_balance_scan_guard_reports_main_hold)
{
    GuiBalanceScanGate gate;
    {
        GuiBalanceScanGuard guard{gate};
        BOOST_REQUIRE(guard.Admitted());
        guard.AddMainHold(100);
        guard.AddMainHold(300); // phase 0 and phase B add up
    }
    BOOST_CHECK(!gate.TryBegin(BlockConnectActivity::NowMs())); // 400 ms back-off from now
    {
        GuiBalanceScanGuard guard{gate};
        BOOST_CHECK(!guard.Admitted());
    }
    GuiBalanceScanGate quiet;
    {
        GuiBalanceScanGuard guard{quiet};
        BOOST_REQUIRE(guard.Admitted());
        guard.AddMainHold(10); // cheap hold: no pause
    }
    BOOST_CHECK(quiet.TryBegin(BlockConnectActivity::NowMs()));
    quiet.End(BlockConnectActivity::NowMs(), false);
}

BOOST_AUTO_TEST_CASE(gui_balance_scan_gate_single_flight)
{
    GuiBalanceScanGate gate;
    BOOST_CHECK(gate.TryBegin(1000));
    BOOST_CHECK(!gate.TryBegin(1001)); // one scan at a time
    BOOST_CHECK(!gate.TryBegin(60000));
    gate.End(1100);
    BOOST_CHECK(gate.TryBegin(100000)); // long after the last scan
    gate.End(100000, /*scanned=*/false);
}

BOOST_AUTO_TEST_CASE(gui_balance_scan_gate_backs_off_for_the_last_duration)
{
    GuiBalanceScanGate gate;
    // A 2 s scan: nothing is admitted for the next 2 s.
    BOOST_CHECK(gate.TryBegin(10000));
    gate.End(12000);
    BOOST_CHECK(!gate.TryBegin(12000));
    BOOST_CHECK(!gate.TryBegin(13999));
    BOOST_CHECK(gate.TryBegin(14000));
    gate.End(14000, /*scanned=*/false);
    BOOST_CHECK(gate.TryBegin(14001)); // a no-op scan imposes no back-off
    gate.End(14001, /*scanned=*/false);
}

BOOST_AUTO_TEST_CASE(gui_balance_scan_gate_cheap_scans_impose_no_back_off)
{
    GuiBalanceScanGate gate;
    BOOST_CHECK(gate.TryBegin(1000));
    gate.End(1005); // 5 ms scan
    BOOST_CHECK(gate.TryBegin(1005)); // immediately admitted again
    gate.End(1005 + GuiBalanceScanGate::BACKOFF_THRESHOLD_MS - 1); // just under the threshold
    BOOST_CHECK(gate.TryBegin(1005 + GuiBalanceScanGate::BACKOFF_THRESHOLD_MS - 1));
    gate.End(2000, /*scanned=*/false);
}

BOOST_AUTO_TEST_CASE(gui_balance_scan_gate_clamps_the_back_off)
{
    GuiBalanceScanGate gate;
    // A 300 ms scan: refused until 300 ms after it ended.
    BOOST_CHECK(gate.TryBegin(1000));
    gate.End(1300);
    BOOST_CHECK(!gate.TryBegin(1300));
    BOOST_CHECK(!gate.TryBegin(1599));
    BOOST_CHECK(gate.TryBegin(1600));
    // A 60 s scan waits at most MAX_BACKOFF_MS.
    gate.End(1600 + 60000);
    const int64_t end = 1600 + 60000;
    BOOST_CHECK(!gate.TryBegin(end + GuiBalanceScanGate::MAX_BACKOFF_MS - 1));
    BOOST_CHECK(gate.TryBegin(end + GuiBalanceScanGate::MAX_BACKOFF_MS));
    gate.End(end + GuiBalanceScanGate::MAX_BACKOFF_MS, /*scanned=*/false);
}

BOOST_AUTO_TEST_CASE(gui_balance_scan_guard_releases_on_every_path)
{
    GuiBalanceScanGate gate;
    {
        GuiBalanceScanGuard guard{gate};
        BOOST_CHECK(guard.Admitted());
        GuiBalanceScanGuard second{gate};
        BOOST_CHECK(!second.Admitted());
        // an early return: never marked scanned
    }
    GuiBalanceScanGuard again{gate};
    BOOST_CHECK(again.Admitted()); // released, and no back-off recorded
}

BOOST_AUTO_TEST_SUITE_END()
} // namespace wallet
