// Copyright (c) 2018-2021 Blackcoin Core Developers
// Copyright (c) 2018-2021 Blackcoin More Developers
// Copyright (c) 2018-2021 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <util/string.h>
#include <util/thread.h>
#include <util/thread_qos.h>
#include <util/threadnames.h>

#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>

#if defined(HAVE_CONFIG_H)
#include <config/bitcoin-config.h>
#endif

#include <boost/test/unit_test.hpp>

BOOST_AUTO_TEST_SUITE(util_threadnames_tests)

const std::string TEST_THREAD_NAME_BASE = "test_thread.";

/**
 * Run a bunch of threads to all call util::ThreadRename.
 *
 * @return the set of name each thread has after attempted renaming.
 */
std::set<std::string> RenameEnMasse(int num_threads)
{
    std::vector<std::thread> threads;
    std::set<std::string> names;
    std::mutex lock;

    auto RenameThisThread = [&](int i) {
        util::ThreadRename(TEST_THREAD_NAME_BASE + ToString(i));
        std::lock_guard<std::mutex> guard(lock);
        names.insert(util::ThreadGetInternalName());
    };

    threads.reserve(num_threads);
    for (int i = 0; i < num_threads; ++i) {
        threads.emplace_back(RenameThisThread, i);
    }

    for (std::thread& thread : threads) thread.join();

    return names;
}

/**
 * Rename a bunch of threads with the same basename (expect_multiple=true), ensuring suffixes are
 * applied properly.
 */
BOOST_AUTO_TEST_CASE(util_threadnames_test_rename_threaded)
{
#if !defined(HAVE_THREAD_LOCAL)
    // This test doesn't apply to platforms where we don't have thread_local.
    return;
#endif

    std::set<std::string> names = RenameEnMasse(100);

    BOOST_CHECK_EQUAL(names.size(), 100U);

    // Names "test_thread.[n]" should exist for n = [0, 99]
    for (int i = 0; i < 100; ++i) {
        BOOST_CHECK(names.find(TEST_THREAD_NAME_BASE + ToString(i)) != names.end());
    }

}

BOOST_AUTO_TEST_CASE(thread_qos_and_cpu_time_helpers)
{
    // CPU time of this thread only grows, and is a few microseconds' reading on every supported platform.
    const auto cpu_before = util::CurrentThreadCpuMicros();
#if !defined(WIN32)
    BOOST_REQUIRE(cpu_before.has_value());
    volatile uint64_t sink{0};
    for (uint64_t i = 0; i < 2000000; ++i) sink = sink + i;
    const auto cpu_after = util::CurrentThreadCpuMicros();
    BOOST_REQUIRE(cpu_after.has_value());
    BOOST_CHECK_GT(*cpu_after, *cpu_before);
#endif

    // The class is set only where the platform has one, on the calling
    // thread only: a thread it starts begins at the default class (measured
    // on macOS), unless the process opted in for its TraceThread threads.
    std::optional<std::string> own, plain_child, traced_child;
    bool set{false};
    std::thread parent([&] {
        set = util::SetCurrentThreadQosUserInitiated();
        own = util::CurrentThreadQosName();
        std::thread child([&] { plain_child = util::CurrentThreadQosName(); });
        child.join();
        util::SetDefaultThreadQosUserInitiated(true);
        std::thread traced([&] { util::TraceThread("qos_test", [&] { traced_child = util::CurrentThreadQosName(); }); });
        traced.join();
        util::SetDefaultThreadQosUserInitiated(false);
    });
    parent.join();
#if defined(__APPLE__)
    BOOST_CHECK(set);
    BOOST_REQUIRE(own && plain_child && traced_child);
    BOOST_CHECK_EQUAL(*own, "user-initiated");
    BOOST_CHECK_NE(*plain_child, "user-initiated");
    BOOST_CHECK_EQUAL(*traced_child, "user-initiated");
#else
    BOOST_CHECK(!set);
    BOOST_CHECK(!own && !plain_child && !traced_child);
#endif

    // The application-active hint is unknown until the GUI says, and shows in the load context.
    BOOST_CHECK(!util::GetApplicationActiveHint().has_value());
    util::SetApplicationActiveHint(false);
    BOOST_CHECK_EQUAL(util::GetApplicationActiveHint().value(), false);
    BOOST_CHECK(util::FormatThreadLoadContext(cpu_before).find("app=inactive") != std::string::npos);
    util::SetApplicationActiveHint(true);
    BOOST_CHECK(util::FormatThreadLoadContext(std::nullopt).find("app=active") != std::string::npos);
}

BOOST_AUTO_TEST_SUITE_END()
