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

BOOST_AUTO_TEST_SUITE_END()
} // namespace wallet
