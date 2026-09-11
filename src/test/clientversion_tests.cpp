// Copyright (c) 2026 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <clientversion.h>

#include <boost/test/unit_test.hpp>

BOOST_AUTO_TEST_SUITE(clientversion_tests)

BOOST_AUTO_TEST_CASE(maintenance_revision_preserves_numeric_compatibility)
{
    BOOST_CHECK_EQUAL(CLIENT_VERSION, 30105);
    BOOST_CHECK_EQUAL(CLIENT_VERSION_MAJOR, 30);
    BOOST_CHECK_EQUAL(CLIENT_VERSION_MINOR, 1);
    BOOST_CHECK_EQUAL(CLIENT_VERSION_BUILD, 5);
    BOOST_CHECK_EQUAL(CLIENT_VERSION_REVISION, 1);
    BOOST_CHECK_EQUAL(CLIENT_VERSION_STRING, "30.1.5.1");
    BOOST_CHECK_EQUAL(PACKAGE_VERSION, "30.1.5.1");
    BOOST_CHECK(CLIENT_VERSION_IS_RELEASE);
}

BOOST_AUTO_TEST_CASE(peer_revision_is_explicit_and_historical_format_is_unchanged)
{
    BOOST_CHECK_EQUAL(FormatSubVersion("Test", 99900, {}), "/Test:9.99.0/");
    BOOST_CHECK_EQUAL(FormatSubVersion("Test", 99900, {"comment1", "Comment2"}),
                      "/Test:9.99.0(comment1; Comment2)/");
    BOOST_CHECK_EQUAL(FormatSubVersion("Blackcoin", 30105, {}, 0), "/Blackcoin:30.1.5/");
    BOOST_CHECK_EQUAL(FormatSubVersion(CLIENT_NAME, CLIENT_VERSION, {}, CLIENT_VERSION_REVISION),
                      "/Blackcoin:30.1.5.1/");
    BOOST_CHECK_EQUAL(FormatSubVersion(CLIENT_NAME, CLIENT_VERSION, {"comment1", "Comment2"}, CLIENT_VERSION_REVISION),
                      "/Blackcoin:30.1.5.1(comment1; Comment2)/");
    BOOST_CHECK_EQUAL(FormatSubVersion("Test", 30105, {}, 99), "/Test:30.1.5.99/");
}

BOOST_AUTO_TEST_SUITE_END()
