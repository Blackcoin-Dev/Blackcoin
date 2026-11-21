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

MigrationBatchInput Input(uint32_t n, CAmount value, int64_t weight, bool anchor = false, bool auxiliary = false)
{
    MigrationBatchInput in;
    in.outpoint = COutPoint{Txid::FromUint256(uint256{static_cast<unsigned char>(n % 251 + 1)}), n};
    in.value = value;
    in.effective_value = value;
    in.input_weight = weight;
    in.anchor = anchor;
    in.auxiliary = auxiliary;
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

BOOST_AUTO_TEST_CASE(a_sole_anchor_does_not_strand_witness_inputs_when_a_quantum_output_can_anchor)
{
    // One legacy anchor and five witness inputs, two inputs per batch. The first batch takes
    // the sole anchor. Without an auxiliary quantum output the rest has no anchor (the failure
    // the review found); with the earlier batch's confirmed output it continues.
    std::vector<MigrationBatchInput> legacy;
    legacy.push_back(Input(1, 100, 600, /*anchor=*/true));
    for (uint32_t i = 2; i <= 6; ++i) legacy.push_back(Input(i, 1000 + i, 600));
    const MigrationBatchPlan first = PlanMigrationBatch(legacy, 2, 0, 100000, /*require_anchor=*/true);
    BOOST_REQUIRE_EQUAL(first.selected.size(), size_t{2});
    BOOST_CHECK(first.selected[0].anchor || first.selected[1].anchor);
    BOOST_CHECK(first.auxiliary.empty());

    std::vector<MigrationBatchInput> rest;
    for (const MigrationBatchInput& in : legacy) {
        if (std::none_of(first.selected.begin(), first.selected.end(), [&](const MigrationBatchInput& s) { return s.outpoint == in.outpoint; })) rest.push_back(in);
    }
    BOOST_REQUIRE_EQUAL(rest.size(), size_t{4});
    BOOST_CHECK(PlanMigrationBatch(rest, 2, 0, 100000, true).blocked_no_anchor);

    // The first batch's own output is a confirmed quantum output: it anchors the next batch.
    rest.push_back(Input(100, 5000, 4000, /*anchor=*/true, /*auxiliary=*/true));
    const MigrationBatchPlan second = PlanMigrationBatch(rest, 2, 0, 100000, true);
    BOOST_CHECK(!second.blocked_no_anchor);
    BOOST_CHECK_EQUAL(second.selected.size(), size_t{2}); // the auxiliary input is not counted in max_inputs
    BOOST_REQUIRE_EQUAL(second.auxiliary.size(), size_t{1});
    for (const MigrationBatchInput& in : second.selected) BOOST_CHECK(!in.auxiliary);
    BOOST_CHECK_EQUAL(second.estimated_weight, 600 * 2 + 4000);
}

BOOST_AUTO_TEST_CASE(max_inputs_one_still_finishes_with_an_auxiliary_output)
{
    std::vector<MigrationBatchInput> rest;
    for (uint32_t i = 2; i <= 4; ++i) rest.push_back(Input(i, 900 + i, 600));
    rest.push_back(Input(100, 5000, 4000, true, true));
    size_t batches{0};
    while (!rest.empty() && batches < 10) {
        const MigrationBatchPlan plan = PlanMigrationBatch(rest, 1, 0, 100000, true);
        BOOST_REQUIRE(!plan.blocked_no_anchor);
        BOOST_REQUIRE_EQUAL(plan.selected.size(), size_t{1});
        rest.erase(std::remove_if(rest.begin(), rest.end(), [&](const MigrationBatchInput& in) {
            return !in.auxiliary && in.outpoint == plan.selected[0].outpoint;
        }), rest.end());
        ++batches;
        if (std::all_of(rest.begin(), rest.end(), [](const MigrationBatchInput& in) { return in.auxiliary; })) break;
    }
    BOOST_CHECK_EQUAL(batches, size_t{3});
}

BOOST_AUTO_TEST_CASE(an_auxiliary_output_can_fund_a_tail_even_when_a_legacy_anchor_serves)
{
    std::vector<MigrationBatchInput> tail;
    tail.push_back(Input(1, 3, 600, /*anchor=*/true)); // a few units: cannot pay its own fee
    tail.push_back(Input(100, 50000000, 4000, true, true));
    const MigrationBatchPlan plain = PlanMigrationBatch(tail, 5, 0, 100000, true);
    BOOST_CHECK(plain.auxiliary.empty());
    const MigrationBatchPlan funded = PlanMigrationBatch(tail, 5, 0, 100000, true, /*force_auxiliary=*/true);
    BOOST_REQUIRE_EQUAL(funded.auxiliary.size(), size_t{1});
    BOOST_CHECK_EQUAL(funded.selected.size(), size_t{1});
    // An auxiliary input never makes up a plan on its own: it is not legacy value to move.
    std::vector<MigrationBatchInput> only_aux{Input(100, 50000000, 4000, true, true)};
    BOOST_CHECK(PlanMigrationBatch(only_aux, 5, 0, 100000, true).selected.empty());
    // It still counts toward the weight budget.
    BOOST_CHECK(PlanMigrationBatch(tail, 5, 0, 4500, true, true).auxiliary.empty() ||
                PlanMigrationBatch(tail, 5, 0, 4500, true, true).estimated_weight <= 4500);
}

BOOST_AUTO_TEST_SUITE_END()

} // namespace wallet
