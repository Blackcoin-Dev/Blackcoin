// Copyright (c) 2026 Blackcoin Core Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_TEST_UTIL_RC14_GATE_H
#define BITCOIN_TEST_UTIL_RC14_GATE_H

#include <boost/test/unit_test.hpp>

#include <cstdlib>
#include <string>

/**
 * Slow-disk regression gates that depend on another RC14 track. Each test file
 * that has them declares a constant `RC14_GATES_ENFORCED` (false until the
 * tracks are merged; see TODO(rc14-integration) there). While it is false a
 * gate still runs its check and reports "holds" or "does not hold" in the test
 * log but does not fail the test. Setting RC14_ENFORCE_GATES=1 in the
 * environment enforces them without editing the file, which is how to see
 * what a build does today.
 */
inline bool Rc14GatesEnforced(bool file_constant)
{
    const char* env = std::getenv("RC14_ENFORCE_GATES");
    return file_constant || (env && std::string{env} == "1");
}

#define RC14_GATE_CHECK(enforced, condition, description)                                              \
    do {                                                                                               \
        const bool rc14_holds_ = static_cast<bool>(condition);                                         \
        if (Rc14GatesEnforced(enforced)) {                                                             \
            BOOST_CHECK_MESSAGE(rc14_holds_, description);                                             \
        } else {                                                                                       \
            BOOST_TEST_MESSAGE("[rc14 gate waits for integration] " << description << ": "          \
                               << (rc14_holds_ ? "HOLDS" : "does not hold yet"));                     \
        }                                                                                              \
    } while (0)

#endif // BITCOIN_TEST_UTIL_RC14_GATE_H
