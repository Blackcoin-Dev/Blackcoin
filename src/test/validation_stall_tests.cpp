// Copyright (c) 2026 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <validation_stall.h>

#include <boost/test/unit_test.hpp>

#include <chrono>

using namespace std::chrono_literals;
using validation_stall::ShiftForStall;

BOOST_AUTO_TEST_SUITE(validation_stall_tests)

BOOST_AUTO_TEST_CASE(short_stall_is_not_excused)
{
    BOOST_CHECK(ShiftForStall(0us, 10s, 10s + 900ms) == 0us);
    BOOST_CHECK(ShiftForStall(5s, 10s, 10s + 999ms) == 0us);
}

BOOST_AUTO_TEST_CASE(clock_started_before_stall_gets_full_stall)
{
    BOOST_CHECK(ShiftForStall(0us, 100s, 240s) == 140s);
    BOOST_CHECK(ShiftForStall(100s, 100s, 240s) == 140s);
}

BOOST_AUTO_TEST_CASE(clock_started_during_stall_gets_only_the_overlap)
{
    BOOST_CHECK(ShiftForStall(200s, 100s, 240s) == 40s);
}

BOOST_AUTO_TEST_CASE(clock_started_after_stall_gets_nothing)
{
    BOOST_CHECK(ShiftForStall(240s, 100s, 240s) == 0us);
    BOOST_CHECK(ShiftForStall(300s, 100s, 240s) == 0us);
}

BOOST_AUTO_TEST_CASE(stall_excuse_is_capped)
{
    // A 1000 s stall excuses at most MAX_EXCUSED_STALL (300 s).
    BOOST_CHECK(ShiftForStall(0us, 100s, 1100s) == 300s);
    BOOST_CHECK(ShiftForStall(150s, 100s, 1100s) == 250s);
    // A clock that started after the capped window is not shifted.
    BOOST_CHECK(ShiftForStall(500s, 100s, 1100s) == 0us);
}

BOOST_AUTO_TEST_CASE(silent_peer_still_times_out)
{
    // Timeout budget 64 s. Peer asked for a block at t=0 and is silent. We stall
    // 100 s. The deadline moves by exactly 100 s, so the peer is judged on 64 s
    // of its own time, not on the 100 s that were ours.
    const auto since = 0us;
    const auto shift = ShiftForStall(since, 10s, 110s);
    BOOST_CHECK(shift == 100s);
    const auto new_since = since + shift;
    BOOST_CHECK(!(110s > new_since + 64s));   // not yet timed out at stall end
    BOOST_CHECK(  175s > new_since + 64s);    // timed out 65 s later
}

BOOST_AUTO_TEST_SUITE_END()
