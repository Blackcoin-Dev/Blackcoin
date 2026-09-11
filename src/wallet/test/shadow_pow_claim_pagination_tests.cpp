// Copyright (c) 2026 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <wallet/shadow_pow_claim_pagination.h>

#include <test/util/setup_common.h>
#include <util/string.h>

#include <boost/test/unit_test.hpp>

#include <algorithm>
#include <set>
#include <string>
#include <utility>
#include <vector>

namespace wallet {
namespace {

ShadowPowClaimRecoveryInventory PaginationInventory()
{
    ShadowPowClaimRecoveryInventory inventory;
    inventory.active_tip = uint256S("01");
    inventory.wallet_processed_tip = inventory.active_tip;
    inventory.active_height = inventory.wallet_processed_height = 100;
    inventory.wallet_generation = 7;
    inventory.candidate_state_fingerprint = uint256S("02");
    // One component larger than 1000 nodes must not escape the page bound.
    for (size_t family = 0; family < 2; ++family) {
        ShadowPowClaimRecoveryComponent component;
        component.anchor = COutPoint{uint256S(ToString(family + 10)), 0};
        component.fingerprint = uint256S(ToString(family + 20));
        for (size_t i = 0; i < (family == 0 ? 1007U : 3U); ++i) {
            ShadowPowClaimRecoveryNode node;
            node.txid = uint256S(ToString(family * 2000 + i + 100));
            component.nodes.push_back(node);
            component.claim_txids.push_back(node.txid);
        }
        component.root_claim_txids.push_back(component.nodes.front().txid);
        component.resolution_txids.push_back(uint256S(ToString(family + 50)));
        component.ordinary_or_mixed_txids.push_back(uint256S(ToString(family + 60)));
        inventory.components.push_back(std::move(component));
    }
    inventory.unanchored_claim_txids = {uint256S("ffff"), uint256S("fffe")};
    return inventory;
}

std::string RecordKey(const ShadowPowRecoveryPageRecord& record)
{
    return (record.component ? record.component->anchor.hash.GetHex() + ":" +
                                  ToString(record.component->anchor.n) : "unanchored") +
           ":" + ToString(static_cast<unsigned int>(record.kind)) + ":" +
           record.txid.GetHex();
}

} // namespace

BOOST_FIXTURE_TEST_SUITE(shadow_pow_claim_pagination_tests, BasicTestingSetup)

BOOST_AUTO_TEST_CASE(large_component_complete_bounded_and_deterministic)
{
    const auto inventory = PaginationInventory();
    std::vector<std::string> records;
    std::string cursor;
    uint256 snapshot;
    size_t total{0};
    do {
        const auto page = BuildShadowPowRecoveryPage(inventory, "wallet", 73, cursor);
        BOOST_REQUIRE(page.error.empty());
        BOOST_CHECK_LE(page.records.size(), 73U);
        BOOST_CHECK_EQUAL(page.offset, records.size());
        if (snapshot.IsNull()) snapshot = page.snapshot;
        BOOST_CHECK(page.snapshot == snapshot);
        total = page.total_records;
        for (const auto& record : page.records) records.push_back(RecordKey(record));
        cursor = page.next_cursor;
    } while (!cursor.empty());
    BOOST_CHECK_EQUAL(total, 2030U);
    BOOST_CHECK_EQUAL(records.size(), total);
    BOOST_CHECK_EQUAL(std::set<std::string>(records.begin(), records.end()).size(), total);

    auto reordered = inventory;
    std::reverse(reordered.components.begin(), reordered.components.end());
    std::reverse(reordered.unanchored_claim_txids.begin(), reordered.unanchored_claim_txids.end());
    for (auto& component : reordered.components) {
        std::reverse(component.nodes.begin(), component.nodes.end());
        std::reverse(component.claim_txids.begin(), component.claim_txids.end());
    }
    size_t offset{0};
    do {
        // Page size can change without creating a new snapshot or omission.
        const auto page = BuildShadowPowRecoveryPage(reordered, "wallet", 1000, cursor);
        BOOST_REQUIRE(page.error.empty());
        BOOST_CHECK(page.snapshot == snapshot);
        for (const auto& record : page.records) {
            BOOST_CHECK_EQUAL(RecordKey(record), records.at(offset++));
        }
        cursor = page.next_cursor;
    } while (!cursor.empty());
    BOOST_CHECK_EQUAL(offset, total);
}

BOOST_AUTO_TEST_CASE(cursor_rejects_wallet_tip_generation_and_classifier_drift)
{
    const auto inventory = PaginationInventory();
    const auto first = BuildShadowPowRecoveryPage(inventory, "wallet-0", 10);
    BOOST_REQUIRE(!first.next_cursor.empty());
    for (size_t i = 1; i < 31; ++i) {
        BOOST_CHECK_EQUAL(BuildShadowPowRecoveryPage(
            inventory, "wallet-" + ToString(i), 10, first.next_cursor).error,
            "recovery-page-cursor-stale");
    }
    const auto check_stale = [&](const ShadowPowClaimRecoveryInventory& changed) {
        BOOST_CHECK_EQUAL(BuildShadowPowRecoveryPage(
            changed, "wallet-0", 10, first.next_cursor).error,
            "recovery-page-cursor-stale");
    };
    auto changed = inventory;
    ++changed.wallet_generation;
    check_stale(changed);
    changed = inventory;
    changed.active_tip = uint256S("f0");
    check_stale(changed);
    changed = inventory;
    changed.candidate_state_fingerprint = uint256S("f1");
    check_stale(changed);
    changed = inventory;
    changed.components.front().fingerprint = uint256S("f2");
    check_stale(changed);
    changed = inventory;
    changed.components.front().nodes.front().proof_reject_reason = "deferred";
    check_stale(changed);
    changed = inventory;
    changed.unanchored_claim_txids.push_back(uint256S("f3"));
    check_stale(changed);
    // An unchanged reconstructed inventory can continue without a cache or
    // server-side cursor object, including after an unchanged restart.
    changed = inventory;
    BOOST_CHECK(BuildShadowPowRecoveryPage(changed, "wallet-0", 10,
                                          first.next_cursor).error.empty());
}

BOOST_AUTO_TEST_CASE(cursor_and_page_bounds_fail_closed)
{
    const auto inventory = PaginationInventory();
    const auto first = BuildShadowPowRecoveryPage(inventory, "wallet", 1);
    BOOST_REQUIRE(first.error.empty());
    const std::string prefix = "v1:" + first.snapshot.GetHex() + ":";
    for (const std::string& cursor : {
             std::string{"garbage"}, prefix + "-1", prefix + "+1", prefix + "01",
             prefix + "1 ", prefix + "", prefix + "18446744073709551616",
             "v2:" + first.snapshot.GetHex() + ":1", std::string(10000, 'a')}) {
        BOOST_CHECK_EQUAL(BuildShadowPowRecoveryPage(inventory, "wallet", 10, cursor).error,
                          "recovery-page-cursor-malformed");
    }
    for (size_t limit : {0U, 1001U}) {
        BOOST_CHECK_EQUAL(BuildShadowPowRecoveryPage(inventory, "wallet", limit).error,
                          "recovery-page-size-out-of-range");
    }
    BOOST_CHECK_EQUAL(BuildShadowPowRecoveryPage(
        inventory, "wallet", 10, prefix + ToString(first.total_records)).error,
        "recovery-page-cursor-out-of-range");
    const auto empty = BuildShadowPowRecoveryPage({}, "wallet", 100);
    BOOST_CHECK(empty.error.empty());
    BOOST_CHECK(empty.records.empty());
    BOOST_CHECK(empty.next_cursor.empty());
    BOOST_CHECK_EQUAL(empty.total_records, 0U);
}

BOOST_AUTO_TEST_SUITE_END()

} // namespace wallet
