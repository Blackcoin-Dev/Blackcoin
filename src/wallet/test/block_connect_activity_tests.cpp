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

BOOST_AUTO_TEST_CASE(gui_balance_scan_gate_clamps_the_back_off)
{
    GuiBalanceScanGate gate;
    // A very short scan still waits MIN_BACKOFF_MS.
    BOOST_CHECK(gate.TryBegin(1000));
    gate.End(1005);
    BOOST_CHECK(!gate.TryBegin(1005 + GuiBalanceScanGate::MIN_BACKOFF_MS - 1));
    BOOST_CHECK(gate.TryBegin(1005 + GuiBalanceScanGate::MIN_BACKOFF_MS));
    // A very long scan waits at most MAX_BACKOFF_MS.
    gate.End(1005 + GuiBalanceScanGate::MIN_BACKOFF_MS + 60000);
    const int64_t end = 1005 + GuiBalanceScanGate::MIN_BACKOFF_MS + 60000;
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
