// Copyright (c) 2026 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <policy/policy.h>
#include <test/util/setup_common.h>
#include <wallet/migration_batch.h>

#include <boost/test/unit_test.hpp>

#include <algorithm>
#include <set>

namespace wallet {
namespace {

MigrationBatchInput Input(uint32_t n, CAmount value, int64_t weight, bool anchor = false)
{
    MigrationBatchInput in;
    in.outpoint = COutPoint{Txid::FromUint256(uint256{static_cast<unsigned char>(n % 251 + 1)}), n};
    in.value = value;
    in.effective_value = value;
    in.input_weight = weight;
    in.anchor = anchor;
    return in;
}

} // namespace

BOOST_FIXTURE_TEST_SUITE(migration_batch_tests, BasicTestingSetup)

BOOST_AUTO_TEST_CASE(batch_is_bounded_by_count_and_weight)
{
    // Direct quantum payout inputs weigh 3,903 weight units each.
    std::vector<MigrationBatchInput> payouts;
    for (uint32_t i = 0; i < 300; ++i) payouts.push_back(Input(i, 1000 + i, 3903));

    const MigrationBatchPlan plan = PlanMigrationBatch(
        payouts, DEFAULT_GOLDRUSH_CONSOLIDATION_BATCH_INPUTS, MIGRATION_BATCH_FIXED_WEIGHT,
        MIGRATION_BATCH_WEIGHT_BUDGET, /*require_anchor=*/false);
    BOOST_CHECK_EQUAL(plan.selected.size(), size_t{DEFAULT_GOLDRUSH_CONSOLIDATION_BATCH_INPUTS});
    BOOST_CHECK(plan.estimated_weight <= MIGRATION_BATCH_WEIGHT_BUDGET);
    BOOST_CHECK(plan.estimated_weight < MAX_STANDARD_TX_WEIGHT);

    // A huge count cap is still held back by the weight budget.
    const MigrationBatchPlan unlimited = PlanMigrationBatch(
        payouts, MAX_MIGRATION_BATCH_INPUTS_OPTION, MIGRATION_BATCH_FIXED_WEIGHT,
        MIGRATION_BATCH_WEIGHT_BUDGET, false);
    BOOST_CHECK(unlimited.selected.size() < 300);
    BOOST_CHECK(unlimited.estimated_weight <= MIGRATION_BATCH_WEIGHT_BUDGET);
    BOOST_CHECK_EQUAL(unlimited.selected.size(), size_t{(MIGRATION_BATCH_WEIGHT_BUDGET - MIGRATION_BATCH_FIXED_WEIGHT) / 3903});

    // Boundary: exactly the number that fits is selected, one more is not.
    std::vector<MigrationBatchInput> few;
    for (uint32_t i = 0; i < 5; ++i) few.push_back(Input(i, 100 + i, 1000));
    const MigrationBatchPlan edge = PlanMigrationBatch(few, 10, 0, 3000, false);
    BOOST_CHECK_EQUAL(edge.selected.size(), size_t{3});
    BOOST_CHECK_EQUAL(edge.estimated_weight, 3000);
    const MigrationBatchPlan one_short = PlanMigrationBatch(few, 10, 0, 2999, false);
    BOOST_CHECK_EQUAL(one_short.selected.size(), size_t{2});
    // Nothing fits.
    BOOST_CHECK(PlanMigrationBatch(few, 10, 0, 999, false).selected.empty());
    BOOST_CHECK(PlanMigrationBatch(few, 0, 0, 100000, false).selected.empty());
}

BOOST_AUTO_TEST_CASE(selection_is_deterministic_largest_first)
{
    std::vector<MigrationBatchInput> inputs;
    for (uint32_t i = 0; i < 10; ++i) inputs.push_back(Input(i, 500 + (i % 3) * 100, 600));
    auto shuffled = inputs;
    std::reverse(shuffled.begin(), shuffled.end());

    const MigrationBatchPlan a = PlanMigrationBatch(inputs, 4, 0, 100000, false);
    const MigrationBatchPlan b = PlanMigrationBatch(shuffled, 4, 0, 100000, false);
    BOOST_REQUIRE_EQUAL(a.selected.size(), size_t{4});
    BOOST_REQUIRE_EQUAL(b.selected.size(), size_t{4});
    for (size_t i = 0; i < 4; ++i) BOOST_CHECK(a.selected[i].outpoint == b.selected[i].outpoint);
    // Largest values come first: the three 700s, then a 600.
    for (size_t i = 0; i < 3; ++i) BOOST_CHECK_EQUAL(a.selected[i].value, 700);
    BOOST_CHECK_EQUAL(a.selected[3].value, 600);
}

BOOST_AUTO_TEST_CASE(repeated_batches_cover_every_input_exactly_once)
{
    std::vector<MigrationBatchInput> remaining;
    std::set<COutPoint> all;
    for (uint32_t i = 0; i < 257; ++i) {
        remaining.push_back(Input(i, 10 + (i * 37) % 1000, 588));
        all.insert(remaining.back().outpoint);
    }
    std::set<COutPoint> seen;
    int batches{0};
    while (!remaining.empty()) {
        const MigrationBatchPlan plan = PlanMigrationBatch(remaining, 100, MIGRATION_BATCH_FIXED_WEIGHT,
                                                           MIGRATION_BATCH_WEIGHT_BUDGET, false);
        BOOST_REQUIRE(!plan.selected.empty());
        BOOST_CHECK(plan.selected.size() <= 100);
        for (const auto& in : plan.selected) {
            BOOST_CHECK(seen.insert(in.outpoint).second);
            remaining.erase(std::remove_if(remaining.begin(), remaining.end(),
                                           [&](const MigrationBatchInput& r) { return r.outpoint == in.outpoint; }),
                            remaining.end());
        }
        ++batches;
    }
    BOOST_CHECK_EQUAL(batches, 3);
    BOOST_CHECK(seen == all);
}

BOOST_AUTO_TEST_CASE(every_batch_keeps_an_anchor_and_spreads_them)
{
    // Three anchors, many witness-only inputs. Each batch needs one anchor, so
    // no batch may use more than one while non-anchors remain.
    std::vector<MigrationBatchInput> remaining;
    for (uint32_t i = 0; i < 3; ++i) remaining.push_back(Input(i, 5000 + i, 588, /*anchor=*/true));
    for (uint32_t i = 3; i < 30; ++i) remaining.push_back(Input(i, 100 + i, 272, /*anchor=*/false));

    int batches{0};
    while (!remaining.empty()) {
        const MigrationBatchPlan plan = PlanMigrationBatch(remaining, 10, 0, 1000000, /*require_anchor=*/true);
        BOOST_REQUIRE(!plan.blocked_no_anchor);
        BOOST_REQUIRE(!plan.selected.empty());
        const auto anchors = std::count_if(plan.selected.begin(), plan.selected.end(),
                                           [](const MigrationBatchInput& in) { return in.anchor; });
        const bool non_anchors_left = std::any_of(remaining.begin(), remaining.end(), [&](const MigrationBatchInput& r) {
            return !r.anchor && std::none_of(plan.selected.begin(), plan.selected.end(),
                                             [&](const MigrationBatchInput& s) { return s.outpoint == r.outpoint; });
        });
        BOOST_CHECK(anchors >= 1);
        if (non_anchors_left) BOOST_CHECK_EQUAL(anchors, 1);
        for (const auto& in : plan.selected) {
            remaining.erase(std::remove_if(remaining.begin(), remaining.end(),
                                           [&](const MigrationBatchInput& r) { return r.outpoint == in.outpoint; }),
                            remaining.end());
        }
        ++batches;
    }
    BOOST_CHECK_EQUAL(batches, 3);

    // Only witness-only candidates left: the plan says it is blocked.
    std::vector<MigrationBatchInput> witness_only{Input(1, 100, 272), Input(2, 200, 272)};
    const MigrationBatchPlan blocked = PlanMigrationBatch(witness_only, 10, 0, 100000, true);
    BOOST_CHECK(blocked.blocked_no_anchor);
    BOOST_CHECK(blocked.selected.empty());
    // The same candidates need no anchor when none is required.
    BOOST_CHECK_EQUAL(PlanMigrationBatch(witness_only, 10, 0, 100000, false).selected.size(), size_t{2});
}

BOOST_AUTO_TEST_CASE(option_clamp)
{
    BOOST_CHECK_EQUAL(ClampMigrationBatchInputs(0, 400), size_t{400});
    BOOST_CHECK_EQUAL(ClampMigrationBatchInputs(-5, 400), size_t{400});
    BOOST_CHECK_EQUAL(ClampMigrationBatchInputs(7, 400), size_t{7});
    BOOST_CHECK_EQUAL(ClampMigrationBatchInputs(1000000, 400), size_t{MAX_MIGRATION_BATCH_INPUTS_OPTION});
}

BOOST_AUTO_TEST_SUITE_END()

} // namespace wallet
