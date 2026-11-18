// Copyright (c) 2026 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <wallet/pow_miner_tip_signal.h>
#include <wallet/pow_mining_duty_cycle.h>
#include <wallet/wallet.h>

#include <addresstype.h>
#include <claim_relay_tracker.h>
#include <interfaces/wallet.h>
#include <script/script.h>
#include <shadow.h>
#include <test/util/setup_common.h>
#include <tinyformat.h>
#include <wallet/test/util.h>
#include <wallet/test/wallet_test_fixture.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <future>
#include <thread>
#include <vector>

#include <boost/test/unit_test.hpp>

namespace wallet {
namespace {

using namespace std::chrono_literals;
using std::chrono::nanoseconds;

/** The miner's schedule replayed on a simulated clock. It follows the rule in
 * PowMinerIterationBudget: charge the iteration, credit its explicit wait,
 * sleep what the ledger asks for, and let a new tip cut short both a sleep
 * and a batch. No real time passes. */
struct ScheduleRun {
    nanoseconds total{0};
    nanoseconds active{0};
    nanoseconds duty_sleep{0};
    /** Duty sleep taken while a search was pending and below the ceilings. */
    nanoseconds sleep_below_cap{0};
    /** Duty sleep taken between a tip and the proof found for it. */
    nanoseconds sleep_before_proof{0};
    uint64_t proofs{0};
    uint64_t tips{0};
    uint64_t interrupted_sleeps{0};
    uint64_t interrupted_batches{0};
    /** Duty sleeps (excess over the ceilings) that ran across a tip: a tip
     * never cuts these short. */
    uint64_t sleeps_across_tip{0};
    /** Debt right after the end-of-iteration sleeps, the largest seen. */
    nanoseconds max_debt_after_sleep{0};
    nanoseconds max_debt{0};
    uint64_t completed_periods{0};
    uint64_t truncated_periods{0};
    /** Active and total time of the completed periods only. */
    nanoseconds completed_active{0};
    nanoseconds completed_total{0};
};

ScheduleRun RunSchedule(int cpu_percent, nanoseconds spacing, nanoseconds interval,
                        uint64_t tips, nanoseconds batch, nanoseconds overhead,
                        uint64_t batches_to_proof)
{
    PowMiningDutyLedger ledger{cpu_percent, spacing};
    ScheduleRun run;
    nanoseconds now{0};
    // The telemetry period, closed by the same rule the miner uses.
    bool period_open{false};
    nanoseconds period_start_debt{0};
    nanoseconds period_active{0};
    nanoseconds period_total{0};
    const auto end_iteration = [&](nanoseconds active, nanoseconds slept, nanoseconds waited,
                                   bool excess_slept) {
        period_active += active;
        period_total += active + slept + waited;
        switch (PowMiningClosePeriod(ledger.Debt(), period_start_debt, excess_slept)) {
        case PowMiningPeriodClose::COMPLETED:
            ++run.completed_periods;
            run.completed_active += period_active;
            run.completed_total += period_total;
            period_open = false;
            break;
        case PowMiningPeriodClose::TRUNCATED:
            ++run.truncated_periods;
            period_open = false;
            break;
        case PowMiningPeriodClose::OPEN:
            break;
        }
    };
    const auto open_period = [&] {
        if (period_open) return;
        period_open = true;
        period_start_debt = ledger.Debt();
        period_active = period_total = nanoseconds{0};
    };
    for (uint64_t tip = 0; tip < tips; ++tip) {
        const nanoseconds next_tip = interval * static_cast<int64_t>(tip + 1);
        ++run.tips;
        uint64_t batches{0};
        bool found{false};
        while (now < next_tip) {
            if (found) {
                // Claim submitted: the idle wait for the next tip is an
                // explicit wait and pays debt like any other.
                const nanoseconds wait = next_tip - now;
                open_period();
                ledger.Credit(wait);
                now = next_tip;
                end_iteration(nanoseconds{0}, nanoseconds{0}, wait, false);
                break;
            }
            open_period();
            // One loop iteration: selection and preparation, then a batch.
            // A tip that arrives inside the batch ends it at once.
            nanoseconds search = batch;
            if (now + overhead + batch > next_tip) {
                search = std::max(nanoseconds{0}, next_tip - now - overhead);
                ++run.interrupted_batches;
            } else {
                ++batches;
                found = batches >= batches_to_proof;
            }
            const nanoseconds debt_before = ledger.Debt();
            ledger.Charge(search, overhead);
            const nanoseconds iteration_debt = ledger.Debt() - debt_before;
            now += overhead + search;
            run.active += overhead + search;
            if (found) ++run.proofs;
            run.max_debt = std::max(run.max_debt, ledger.Debt());
            const bool tip_arrived = now >= next_tip;
            const bool pending = !found || tip_arrived;
            const bool below_cap = ledger.MayDefer();
            const PowMiningSleepPlan plan = ledger.Plan(pending, iteration_debt);
            if (pending && below_cap) {
                BOOST_REQUIRE_EQUAL(plan.excess.count(), 0);
                BOOST_REQUIRE_EQUAL(plan.remainder.count(), 0);
            }
            nanoseconds slept{0};
            // The excess is the duty cycle itself: a tip does not cut it short.
            if (plan.excess.count() > 0) {
                const nanoseconds excess = plan.excess;
                if (now + excess > next_tip) ++run.sleeps_across_tip;
                ledger.Credit(excess);
                now += excess;
                slept += excess;
                if (pending && below_cap) run.sleep_below_cap += excess;
                if (!found) run.sleep_before_proof += excess;
            }
            // The rest of the debt is slept only when nothing is pending, and
            // a new tip interrupts it the moment it arrives.
            if (plan.remainder.count() > 0 && now < next_tip) {
                const nanoseconds part = std::min<nanoseconds>(plan.remainder, next_tip - now);
                if (part < plan.remainder) ++run.interrupted_sleeps;
                ledger.Credit(part);
                now += part;
                slept += part;
                if (!found) run.sleep_before_proof += part;
            }
            run.duty_sleep += slept;
            ledger.ClampToCeilings();
            run.max_debt_after_sleep = std::max(run.max_debt_after_sleep, ledger.Debt());
            end_iteration(overhead + search, slept, nanoseconds{0}, plan.excess.count() > 0);
        }
    }
    run.total = now;
    return run;
}

double Fraction(const ScheduleRun& run)
{
    return static_cast<double>(run.active.count()) / static_cast<double>(run.total.count());
}

/** Largest debt the ledger may hold: both ceilings plus two iterations (one
 * whose sleep a new tip cut short, and the first one for that tip). */
nanoseconds DebtBound(int cpu_percent, nanoseconds spacing, nanoseconds iteration)
{
    const PowMiningDutyLedger ledger{cpu_percent, spacing};
    return ledger.SearchCeiling() + ledger.Ceiling() + PowMiningDutyDebt(iteration, cpu_percent) * 2 +
           nanoseconds{2'000'000};
}

ShadowPowWork NeverSolvedWork()
{
    ShadowPowWork work;
    work.valid = true;
    work.target = CScript{} << OP_TRUE;
    work.quantum_payout_script = GetScriptForDestination(WitnessUnknown{
        QUANTUM_MIGRATION_WITNESS_VERSION,
        std::vector<unsigned char>(QUANTUM_MIGRATION_PROGRAM_SIZE, 0x5a)});
    work.bits = 255;
    return work;
}

PowMinerTipInfo TipInfo(unsigned char tag, int height)
{
    PowMinerTipInfo tip;
    tip.hash = uint256{tag};
    tip.height = height;
    tip.block_time = 1'700'000'000 + height;
    tip.seen = std::chrono::steady_clock::now();
    tip.seen_unix_ms = 1'700'000'000'000 + height;
    return tip;
}

} // namespace

BOOST_FIXTURE_TEST_SUITE(pow_miner_schedule_tests, WalletTestingSetup)

BOOST_AUTO_TEST_CASE(duty_debt_arithmetic)
{
    BOOST_CHECK_EQUAL(PowMiningDutyDebt(100ms, 1).count(), nanoseconds{9900ms}.count());
    BOOST_CHECK_EQUAL(PowMiningDutyDebt(100ms, 25).count(), nanoseconds{300ms}.count());
    BOOST_CHECK_EQUAL(PowMiningDutyDebt(120ms, 60).count(), nanoseconds{80ms}.count());
    BOOST_CHECK_EQUAL(PowMiningDutyDebt(100ms, 100).count(), 0);
    BOOST_CHECK_EQUAL(PowMiningDutyDebt(0ns, 1).count(), 0);
    BOOST_CHECK_EQUAL(PowMiningDutyDebt(-5ms, 1).count(), 0);
    BOOST_CHECK_EQUAL(PowMiningDutyDebt(1ns, 3).count(), 33); // rounded up
    // The debt of a span is the old per-iteration delay of the same span.
    for (const int cpu : {1, 7, 25, 60, 99}) {
        BOOST_CHECK_EQUAL(
            std::chrono::ceil<std::chrono::milliseconds>(PowMiningDutyDebt(120ms, cpu)).count(),
            PowMiningAdditionalDelay(120ms, 0ms, cpu).count());
    }
    BOOST_CHECK_GT(PowMiningDutyDebt(nanoseconds::max(), 1).count(), 0); // saturates

    PowMiningDutyLedger ledger{1, 64s};
    // One spacing of budget: 64 s * 99%. The search part is also bounded by
    // 10 s of search, which at 1% owes far more, so the spacing rule wins.
    BOOST_CHECK_EQUAL(ledger.Ceiling().count(), nanoseconds{63'360ms}.count());
    BOOST_CHECK_EQUAL(ledger.SearchCeiling().count(), nanoseconds{63'360ms}.count());
    BOOST_CHECK(ledger.MayDefer());
    BOOST_CHECK_EQUAL(ledger.SleepNeeded(true).count(), 0);
    BOOST_CHECK_EQUAL(ledger.SleepNeeded(false).count(), 0);
    ledger.Charge(/*search=*/500ms, /*other=*/10ms);
    BOOST_CHECK_EQUAL(ledger.SearchDebt().count(), nanoseconds{49'500ms}.count());
    BOOST_CHECK_EQUAL(ledger.OtherDebt().count(), nanoseconds{990ms}.count());
    BOOST_CHECK(ledger.MayDefer());
    BOOST_CHECK_EQUAL(ledger.SleepNeeded(true).count(), 0);
    BOOST_CHECK_EQUAL(ledger.SleepNeeded(false).count(), 50'490);
    // 0.64 s of search is the allowance at 1%; the batch that crosses it is
    // slept for only the excess, which is the old interleaved delay.
    ledger.Charge(100ms, 0ns);
    BOOST_CHECK(ledger.MayDefer());
    ledger.Charge(64ms, 0ns);
    BOOST_CHECK(!ledger.MayDefer());
    BOOST_CHECK_EQUAL(ledger.SleepNeeded(true).count(), 65'736 - 63'360);
    // The plan splits it: the excess is the duty cycle (a tip never cuts it
    // short), the rest is slept only with nothing pending.
    BOOST_CHECK_EQUAL(ledger.Plan(true).excess.count(), 65'736 - 63'360);
    BOOST_CHECK_EQUAL(ledger.Plan(true).remainder.count(), 0);
    BOOST_CHECK_EQUAL(ledger.Plan(false).excess.count(), 65'736 - 63'360);
    BOOST_CHECK_EQUAL(ledger.Plan(false).remainder.count(), 50'490 + 9'900 + 6'336 - (65'736 - 63'360));
    // Debt is never carried above a ceiling past the end of an iteration.
    ledger.ClampToCeilings();
    BOOST_CHECK(ledger.MayDefer());
    BOOST_CHECK_EQUAL(ledger.SearchDebt().count(), nanoseconds{63'360ms}.count());
    // Lock waits and gate work are other debt: they never use the search
    // allowance, and they have their own ceiling.
    PowMiningDutyLedger contended{1, 64s};
    contended.Charge(0ns, 500ms);
    contended.Charge(500ms, 0ns);
    BOOST_CHECK(contended.MayDefer());
    contended.Charge(0ns, 200ms);
    BOOST_CHECK(!contended.MayDefer());
    BOOST_CHECK_EQUAL(contended.SleepNeeded(true).count(), 69'300 - 63'360);
    // Idle time pays search first, is never banked, and clears everything.
    contended.Credit(1h);
    BOOST_CHECK_EQUAL(contended.Debt().count(), 0);
    contended.Charge(10ms, 0ns);
    BOOST_CHECK_EQUAL(contended.SleepNeeded(false).count(), 990);
    // At 60% one spacing pays for 25.6 s of idle time (38.4 s of work), but
    // the search part is held to 10 s of search: 6.667 s of debt.
    PowMiningDutyLedger sixty{60, 64s};
    BOOST_CHECK_EQUAL(sixty.Ceiling().count(), nanoseconds{25'600ms}.count());
    BOOST_CHECK_EQUAL(sixty.SearchCeiling().count(), PowMiningDutyDebt(10s, 60).count());
    BOOST_CHECK_LT(sixty.SearchCeiling().count(), sixty.Ceiling().count());
    sixty.Charge(10s, 0ns);
    BOOST_CHECK(sixty.MayDefer());
    BOOST_CHECK_EQUAL(sixty.SleepNeeded(true).count(), 0);
    sixty.Charge(100ms, 0ns);
    BOOST_CHECK(!sixty.MayDefer());
    BOOST_CHECK_EQUAL(sixty.SleepNeeded(true).count(), 67); // 66.7 ms of debt, rounded up
    // 100% never owes anything.
    PowMiningDutyLedger full{100, 64s};
    full.Charge(1h, 1h);
    BOOST_CHECK_EQUAL(full.Debt().count(), 0);
    BOOST_CHECK(full.MayDefer());
}

BOOST_AUTO_TEST_CASE(duty_average_short_searches)
{
    // (a) Searches much shorter than the interval: 8 batches of 62.5 ms plus
    // 2 ms of selection each, once per 64 s block. The worker never owes more
    // than it can pay before the next tip, so it never sleeps before a proof,
    // every tip gets its proof, and the average stays far below the target.
    for (const int cpu : {1, 5, 25, 60}) {
        BOOST_TEST_CONTEXT("cpu " << cpu) {
            const auto run = RunSchedule(cpu, 64s, 64s, 2000, 62'500us, 2ms, 8);
            BOOST_CHECK_EQUAL(run.proofs, 2000U);
            BOOST_CHECK_EQUAL(run.sleep_before_proof.count(), 0);
            BOOST_CHECK_EQUAL(run.sleep_below_cap.count(), 0);
            const double expected = 8 * 0.0645 / 64.0;
            BOOST_CHECK_CLOSE(Fraction(run), expected, 0.01);
            BOOST_CHECK_LE(Fraction(run), cpu / 100.0);
            BOOST_CHECK_LE(run.max_debt.count(), DebtBound(cpu, 64s, 64'500us).count());
        }
    }
    // The same search on 16 s blocks at 25%: still inside the budget.
    const auto fast = RunSchedule(25, 64s, 16s, 2000, 62'500us, 2ms, 8);
    BOOST_CHECK_EQUAL(fast.proofs, 2000U);
    BOOST_CHECK_EQUAL(fast.sleep_before_proof.count(), 0);
    BOOST_CHECK_LE(Fraction(fast), 0.25);
}

BOOST_AUTO_TEST_CASE(duty_average_searches_as_long_as_the_interval)
{
    // (b) Every search needs about a whole interval of hashing. The worker is
    // saturated: the average must come out at the configured percentage.
    for (const int cpu : {5, 25, 60}) {
        BOOST_TEST_CONTEXT("cpu " << cpu) {
            const uint64_t tips = 4000;
            const auto run = RunSchedule(cpu, 64s, 64s, tips, 62'500us, 2ms, 1000);
            const double target = cpu / 100.0;
            // Never above the target by more than the bounded carry.
            const double slack = static_cast<double>(DebtBound(cpu, 64s, 64'500us).count()) *
                                 target / (1.0 - target) /
                                 static_cast<double>(run.total.count());
            BOOST_CHECK_LE(Fraction(run), target + slack + 1e-9);
            BOOST_CHECK_GE(Fraction(run), target - 0.001);
            BOOST_CHECK_LE(std::abs(Fraction(run) - target), 0.001);
            BOOST_CHECK_EQUAL(run.sleep_below_cap.count(), 0);
            BOOST_CHECK_LE(run.max_debt.count(), DebtBound(cpu, 64s, 64'500us).count());
            // Every tip cut a sleep or a batch short.
            BOOST_CHECK_GE(run.interrupted_sleeps + run.interrupted_batches + run.sleeps_across_tip, tips - 1);
        }
    }
}

BOOST_AUTO_TEST_CASE(duty_average_searches_that_hit_the_cap)
{
    // (c) The default 1% with a search of 4 s of hashing per tip, more than
    // six times the 0.64 s allowance: the worker runs its allowance first,
    // then falls back to sleeping after every batch.
    const uint64_t tips = 6000;
    const auto run = RunSchedule(1, 64s, 64s, tips, 62'500us, 500us, 64);
    const double slack = static_cast<double>(DebtBound(1, 64s, 63ms).count()) *
                         (0.01 / 0.99) / static_cast<double>(run.total.count());
    BOOST_CHECK_LE(Fraction(run), 0.01 + slack + 1e-9);
    BOOST_CHECK_LE(std::abs(Fraction(run) - 0.01), 0.0001);
    BOOST_CHECK_EQUAL(run.sleep_below_cap.count(), 0);
    BOOST_CHECK_GT(run.sleep_before_proof.count(), 0);
    BOOST_CHECK_LE(run.max_debt.count(), DebtBound(1, 64s, 63ms).count());
    // One hour, worst case: the old schedule allowed 36 s of work; this one
    // allows 36 s plus both allowances (0.64 s each) plus two iterations.
    const auto hour = RunSchedule(1, 64s, 16s, 225, 62'500us, 500us, 1'000'000);
    BOOST_CHECK_GE(hour.total.count(), nanoseconds{1h}.count());
    BOOST_CHECK_LE(hour.total.count(), nanoseconds{1h + 7s}.count());
    BOOST_CHECK_LE(hour.active.count(), nanoseconds{36s + 1280ms + 200ms}.count());
    // A single interval never exceeds the budget of the interval plus the
    // allowance: on 16 s blocks that is 0.16 s + 1.28 s of work at most.
    const auto first = RunSchedule(1, 64s, 16s, 1, 62'500us, 500us, 1'000'000);
    BOOST_CHECK_LE(first.active.count(), nanoseconds{160ms + 1280ms + 200ms}.count());
    // Below the cap the first 0.64 s of search runs without any sleep.
    PowMiningDutyLedger ledger{1, 64s};
    nanoseconds searched{0};
    while (ledger.SleepNeeded(true).count() == 0) {
        ledger.Charge(62'500us, 0ns);
        searched += 62'500us;
    }
    BOOST_CHECK_GE(searched.count(), nanoseconds{640ms}.count());
    BOOST_CHECK_LE(searched.count(), nanoseconds{640ms + 62'500us}.count());
}

BOOST_AUTO_TEST_CASE(tip_burst_cannot_inflate_debt_or_duty)
{
    // A burst of 10,000 tip signals (initial sync, reindex, a long catch-up):
    // a tip is pending after every iteration, so only the excess over the
    // ceilings is slept, and a tip never cuts that sleep short. Debt stays at
    // or below the ceilings however long the burst lasts, and the worker's
    // active time stays at the configured share plus the bounded allowance and
    // one iteration.
    for (const int cpu : {1, 60}) {
        BOOST_TEST_CONTEXT("cpu " << cpu) {
            PowMiningDutyLedger ledger{cpu, 64s};
            const nanoseconds search{62'500us};
            const nanoseconds other{2ms};
            nanoseconds active{0};
            nanoseconds total{0};
            for (int tip = 0; tip < 10'000; ++tip) {
                const nanoseconds debt_before = ledger.Debt();
                ledger.Charge(search, other);
                active += search + other;
                total += search + other;
                const PowMiningSleepPlan plan =
                    ledger.Plan(/*work_pending=*/true, ledger.Debt() - debt_before);
                BOOST_REQUIRE_EQUAL(plan.remainder.count(), 0);
                ledger.Credit(plan.excess);
                total += plan.excess;
                ledger.ClampToCeilings();
                BOOST_REQUIRE_LE(ledger.SearchDebt().count(), ledger.SearchCeiling().count());
                BOOST_REQUIRE_LE(ledger.OtherDebt().count(), ledger.Ceiling().count());
            }
            const auto active_for = [&](nanoseconds ceiling) {
                return nanoseconds{ceiling.count() * cpu / (100 - cpu)};
            };
            const nanoseconds allowance =
                active_for(ledger.SearchCeiling()) + active_for(ledger.Ceiling());
            const nanoseconds bound = nanoseconds{total.count() * cpu / 100} + allowance +
                                      search + other;
            BOOST_CHECK_LE(active.count(), bound.count());
            BOOST_CHECK_GE(active.count(), total.count() * cpu / 100 - nanoseconds{1s}.count());
        }
    }
}

BOOST_AUTO_TEST_CASE(search_burst_is_bounded_by_wall_time)
{
    // At 60% one spacing would pay for 38.4 s of search without a sleep; the
    // 10 s wall bound cuts that to 10 s, after which the interleaved duty
    // cycle applies for the rest of the tip.
    PowMiningDutyLedger ledger{60, 64s};
    nanoseconds searched{0};
    while (ledger.SleepNeeded(true).count() == 0) {
        ledger.Charge(62'500us, 0ns);
        searched += 62'500us;
    }
    BOOST_CHECK_GE(searched.count(), nanoseconds{10s}.count());
    BOOST_CHECK_LE(searched.count(), nanoseconds{10s + 62'500us}.count());
    // One whole block interval of unfindable work: active time is at most the
    // configured share of the interval plus the allowance and one iteration.
    const auto run = RunSchedule(60, 64s, 64s, 1, 62'500us, 500us, 1'000'000);
    const nanoseconds allowance =
        nanoseconds{ledger.SearchCeiling().count() * 60 / 40} +
        nanoseconds{ledger.Ceiling().count() * 60 / 40};
    BOOST_CHECK_LE(run.active.count(),
                   (nanoseconds{64s * 60 / 100} + allowance + 63ms).count());
    BOOST_CHECK_GT(run.sleep_before_proof.count(), 0);
    BOOST_CHECK_EQUAL(run.sleep_below_cap.count(), 0);
    // Two workers on one host over a minute, then an hour, stay inside it too.
    const auto minute = RunSchedule(60, 64s, 60s, 1, 62'500us, 500us, 1'000'000);
    BOOST_CHECK_LE(minute.active.count(),
                   (nanoseconds{60s * 60 / 100} + allowance + 63ms).count());
    const auto hour = RunSchedule(60, 64s, 16s, 225, 62'500us, 500us, 1'000'000);
    BOOST_CHECK_LE(hour.active.count(),
                   (nanoseconds{hour.total.count() * 60 / 100} + allowance + 63ms).count());
}

BOOST_AUTO_TEST_CASE(periods_complete_when_no_proof_is_found)
{
    // No proof for many blocks: the debt sits at its ceiling and never returns
    // to zero. Periods must still complete, each within the duty budget; the
    // burst that first reached the ceiling is reported as truncated.
    for (const int cpu : {1, 25, 60}) {
        BOOST_TEST_CONTEXT("cpu " << cpu) {
            const auto run = RunSchedule(cpu, 64s, 64s, 300, 62'500us, 500us, 1'000'000);
            BOOST_CHECK_GT(run.completed_periods, 100U);
            BOOST_CHECK_GE(run.truncated_periods, 1U);
            BOOST_CHECK_GT(run.completed_total.count(), 0);
            BOOST_CHECK_LE(static_cast<double>(run.completed_active.count()) /
                               static_cast<double>(run.completed_total.count()),
                           cpu / 100.0 + 1e-6);
            BOOST_CHECK_LE(run.max_debt_after_sleep.count(),
                           (PowMiningDutyLedger{cpu, 64s}.SearchCeiling() +
                            PowMiningDutyLedger{cpu, 64s}.Ceiling()).count());
        }
    }
    // The rule itself.
    BOOST_CHECK(PowMiningClosePeriod(0ns, 0ns, false) == PowMiningPeriodClose::COMPLETED);
    BOOST_CHECK(PowMiningClosePeriod(5s, 5s, true) == PowMiningPeriodClose::COMPLETED);
    BOOST_CHECK(PowMiningClosePeriod(6s, 5s, true) == PowMiningPeriodClose::TRUNCATED);
    BOOST_CHECK(PowMiningClosePeriod(6s, 5s, false) == PowMiningPeriodClose::OPEN);
}

BOOST_AUTO_TEST_CASE(pending_claim_work_is_not_delayed_by_the_carried_debt)
{
    // After a retained claim (relay failure) or a same-anchor refresh the
    // worker re-enters the gate on the same tip with claim work pending: below
    // the ceilings nothing is slept, while without the pending mark the whole
    // carried debt would be slept first (tens of seconds at 1%).
    PowMiningDutyLedger ledger{1, 64s};
    ledger.Charge(300ms, 5ms);
    BOOST_CHECK(ledger.MayDefer());
    BOOST_CHECK_GT(ledger.Plan(/*work_pending=*/false).remainder.count(), 30'000);
    BOOST_CHECK_EQUAL(ledger.Plan(/*work_pending=*/true).excess.count(), 0);
    BOOST_CHECK_EQUAL(ledger.Plan(/*work_pending=*/true).remainder.count(), 0);
    // Above the ceilings it is the same bounded duty cycle as everywhere else.
    ledger.Charge(500ms, 0ns);
    BOOST_CHECK_GT(ledger.Plan(/*work_pending=*/true).excess.count(), 0);
    BOOST_CHECK_EQUAL(ledger.Plan(/*work_pending=*/true).remainder.count(), 0);
}

BOOST_AUTO_TEST_CASE(debt_is_not_slept_before_the_idle_state_is_published)
{
    BOOST_CHECK(!PowMiningCarryRemainder(false, false, false));
    BOOST_CHECK(PowMiningCarryRemainder(true, false, false));
    BOOST_CHECK(PowMiningCarryRemainder(false, true, false));
    BOOST_CHECK(PowMiningCarryRemainder(false, false, true));

    // 1%: a search of 0.5 s finds its proof and the claim is submitted. That
    // iteration has no pending work, but it searched, so it sleeps nothing:
    // the worker goes straight to the iteration that publishes the idle
    // state (hashrate zero, waiting for the next tip).
    PowMiningDutyLedger ledger{1, 64s};
    ledger.Charge(/*search=*/500ms, /*other=*/5ms);
    BOOST_CHECK(ledger.MayDefer());
    const auto owed = ledger.Debt();
    BOOST_CHECK_EQUAL(owed.count(), nanoseconds{49'995ms}.count());
    const PowMiningSleepPlan submitted = ledger.Plan(
        PowMiningCarryRemainder(/*work_pending=*/false, /*tip_arrived=*/false, /*searched=*/true));
    BOOST_CHECK_EQUAL(submitted.excess.count(), 0);
    BOOST_CHECK_EQUAL(submitted.remainder.count(), 0);
    // Without the rule the stale state would have stayed up this long.
    BOOST_CHECK_EQUAL(ledger.Plan(/*work_pending=*/false).remainder.count(), 49'995);

    // The idle iteration: a gate evaluation, the one-second wait for the next
    // tip, then the rest of the debt. Nothing is forgiven.
    ledger.Charge(/*search=*/0ns, /*other=*/1ms);
    ledger.Credit(1s);
    const PowMiningSleepPlan idle = ledger.Plan(
        PowMiningCarryRemainder(/*work_pending=*/false, /*tip_arrived=*/false, /*searched=*/false));
    BOOST_CHECK_EQUAL(idle.excess.count(), 0);
    BOOST_CHECK_EQUAL(idle.remainder.count(), 49'995 + 99 - 1'000);
    ledger.Credit(idle.remainder);
    BOOST_CHECK_EQUAL(ledger.Debt().count(), 0);

    // Above a ceiling the excess is still slept by the searching iteration.
    PowMiningDutyLedger over{1, 64s};
    over.Charge(/*search=*/700ms, /*other=*/0ns);
    const PowMiningSleepPlan capped = over.Plan(
        PowMiningCarryRemainder(false, false, /*searched=*/true));
    BOOST_CHECK_EQUAL(capped.excess.count(), 69'300 - 63'360);
    BOOST_CHECK_EQUAL(capped.remainder.count(), 0);
}

BOOST_AUTO_TEST_CASE(tip_signal_wakes_waiters)
{
    PowMinerTipSignal signal;
    // Nothing changed: the wait runs its full time.
    const auto baseline = signal.Sample();
    auto start = std::chrono::steady_clock::now();
    BOOST_CHECK(signal.WaitFor(30ms, baseline, false) == PowMinerTipSignal::Wake::TIMEOUT);
    BOOST_CHECK((std::chrono::steady_clock::now() - start) >= 30ms);

    // A tip that arrives during a long wait ends it at once.
    for (int round = 0; round < 5; ++round) {
        const auto base = signal.Sample();
        std::promise<void> waiting;
        auto waiter = std::async(std::launch::async, [&] {
            waiting.set_value();
            return signal.WaitFor(10s, base, false);
        });
        waiting.get_future().wait();
        std::this_thread::sleep_for(20ms);
        const auto notified = std::chrono::steady_clock::now();
        signal.NotifyTip(TipInfo(static_cast<unsigned char>(round + 1), round));
        BOOST_REQUIRE(waiter.wait_for(5s) == std::future_status::ready);
        BOOST_CHECK(waiter.get() == PowMinerTipSignal::Wake::TIP);
        BOOST_CHECK((std::chrono::steady_clock::now() - notified) < 200ms);
    }
    // A tip that arrived before the wait, but after the baseline, is not lost.
    const auto early = signal.Sample();
    signal.NotifyTip(TipInfo(9, 9));
    start = std::chrono::steady_clock::now();
    BOOST_CHECK(signal.WaitFor(10s, early, false) == PowMinerTipSignal::Wake::TIP);
    BOOST_CHECK((std::chrono::steady_clock::now() - start) < 200ms);
    BOOST_CHECK(signal.TipInfo(uint256{9}).has_value());
    BOOST_CHECK(!signal.TipInfo(uint256{8}).has_value());
    BOOST_CHECK_EQUAL(signal.TipInfo(uint256{9})->height, 9);

    // A gate publication wakes only waiters that watch the gate; a poke wakes
    // every waiter without looking like a tip.
    const auto gate_base = signal.Sample();
    signal.NotifyGate();
    BOOST_CHECK(signal.WaitFor(20ms, gate_base, false) == PowMinerTipSignal::Wake::TIMEOUT);
    BOOST_CHECK(signal.WaitFor(10s, gate_base, true) == PowMinerTipSignal::Wake::GATE);
    const auto poke_base = signal.Sample();
    signal.Poke();
    BOOST_CHECK(signal.WaitFor(10s, poke_base, false) == PowMinerTipSignal::Wake::POKE);

    // A removed claim wakes every waiter, also one that does not watch the
    // gate, and is not lost when it arrives between the baseline and the wait.
    const auto claim_base = signal.Sample();
    signal.NotifyClaimRemoved();
    start = std::chrono::steady_clock::now();
    BOOST_CHECK(signal.WaitFor(10s, claim_base, false) == PowMinerTipSignal::Wake::CLAIM);
    BOOST_CHECK((std::chrono::steady_clock::now() - start) < 200ms);
    BOOST_CHECK(signal.WaitFor(20ms, signal.Sample(), false) == PowMinerTipSignal::Wake::TIMEOUT);
    {
        const auto base = signal.Sample();
        std::promise<void> waiting;
        auto waiter = std::async(std::launch::async, [&] {
            waiting.set_value();
            return signal.WaitFor(10s, base, false);
        });
        waiting.get_future().wait();
        std::this_thread::sleep_for(20ms);
        signal.NotifyClaimRemoved();
        BOOST_REQUIRE(waiter.wait_for(5s) == std::future_status::ready);
        BOOST_CHECK(waiter.get() == PowMinerTipSignal::Wake::CLAIM);
    }
}

BOOST_AUTO_TEST_CASE(found_proof_stops_sibling_search)
{
    const ShadowPowWork work = NeverSolvedWork();
    CWallet wallet{nullptr, "found-stops-siblings", CreateMockableWalletDatabase()};
    wallet.m_pow_mining_enabled = true;
    wallet.m_pow_state = interfaces::WalletPowMiningState::READY;
    const uint64_t generation = wallet.m_pow_wallet_authority_generation.load();
    const uint64_t tip_sequence = wallet.m_pow_tip_signal.TipSequence();
    std::chrono::steady_clock::time_point next_error_log{};
    std::vector<unsigned char> proof;
    auto batch = std::async(std::launch::async, [&] {
        return wallet.RunShadowPowMiningBatch(
            work, 0, 1, uint64_t{1} << 40, generation, proof, 1, next_error_log,
            tip_sequence);
    });
    BOOST_CHECK(batch.wait_for(300ms) == std::future_status::timeout);
    // Another worker found the proof for this tip.
    const auto marked = std::chrono::steady_clock::now();
    wallet.m_pow_proof_found_tip_seq = tip_sequence + 1;
    BOOST_REQUIRE(batch.wait_for(5s) == std::future_status::ready);
    const auto reaction = std::chrono::steady_clock::now() - marked;
    const auto result = batch.get();
    BOOST_CHECK(result.status == WalletPowMiningGrindStatus::EXHAUSTED);
    BOOST_CHECK_GT(result.successful_hashes, 0U);
    BOOST_CHECK(reaction < 200ms);
    BOOST_CHECK(proof.empty());
    // While the mark stands, a batch for that tip ends before its first hash.
    auto marked_batch = wallet.RunShadowPowMiningBatch(
        work, 0, 1, 4, generation, proof, 1, next_error_log, tip_sequence);
    BOOST_CHECK(marked_batch.status == WalletPowMiningGrindStatus::EXHAUSTED);
    BOOST_CHECK_EQUAL(marked_batch.successful_hashes, 0U);
    // A mark for another tip, or none, does not stop the search; neither
    // does any mark for a caller that passes no tip sequence.
    wallet.m_pow_proof_found_tip_seq = tip_sequence + 2;
    auto other_tip = wallet.RunShadowPowMiningBatch(
        work, 0, 1, 4, generation, proof, 1, next_error_log, tip_sequence);
    BOOST_CHECK_EQUAL(other_tip.successful_hashes, 4U);
    wallet.m_pow_proof_found_tip_seq = tip_sequence + 1;
    auto plain = wallet.RunShadowPowMiningBatch(
        work, 0, 1, 4, generation, proof, 1, next_error_log);
    BOOST_CHECK_EQUAL(plain.successful_hashes, 4U);
    wallet.m_pow_proof_found_tip_seq = 0;
    auto cleared = wallet.RunShadowPowMiningBatch(
        work, 0, 1, 4, generation, proof, 1, next_error_log, tip_sequence);
    BOOST_CHECK_EQUAL(cleared.successful_hashes, 4U);
    wallet.m_pow_mining_enabled = false;
}

BOOST_AUTO_TEST_CASE(tip_change_interrupts_a_search)
{
    const ShadowPowWork work = NeverSolvedWork();
    CWallet wallet{nullptr, "tip-interrupts-search", CreateMockableWalletDatabase()};
    wallet.m_pow_mining_enabled = true;
    wallet.m_pow_state = interfaces::WalletPowMiningState::READY;
    const uint64_t generation = wallet.m_pow_wallet_authority_generation.load();
    const uint64_t tip_sequence = wallet.m_pow_tip_signal.TipSequence();
    std::chrono::steady_clock::time_point next_error_log{};
    std::vector<unsigned char> proof;
    auto batch = std::async(std::launch::async, [&] {
        return wallet.RunShadowPowMiningBatch(
            work, 0, 1, uint64_t{1} << 40, generation, proof, 0, next_error_log,
            tip_sequence);
    });
    // The search is running and would not end on its own.
    BOOST_CHECK(batch.wait_for(300ms) == std::future_status::timeout);
    const auto notified = std::chrono::steady_clock::now();
    wallet.m_pow_tip_signal.NotifyTip(TipInfo(1, 1));
    BOOST_REQUIRE(batch.wait_for(5s) == std::future_status::ready);
    const auto reaction = std::chrono::steady_clock::now() - notified;
    const auto result = batch.get();
    // The batch simply ends early; the hashes it did are kept.
    BOOST_CHECK(result.status == WalletPowMiningGrindStatus::EXHAUSTED);
    BOOST_CHECK_GT(result.successful_hashes, 0U);
    BOOST_CHECK_LT(result.successful_hashes, uint64_t{1} << 40);
    BOOST_CHECK((reaction) < 200ms);
    BOOST_CHECK(proof.empty());
    BOOST_TEST_MESSAGE("Argon2id proof hashes per second on this build: "
        << (result.successful_hashes * 1000 / std::max<int64_t>(1, result.elapsed.count())));

    // Without a tip sequence the batch ignores the signal (other callers).
    auto plain = wallet.RunShadowPowMiningBatch(
        work, 0, 1, 4, generation, proof, 0, next_error_log);
    BOOST_CHECK(plain.status == WalletPowMiningGrindStatus::EXHAUSTED);
    BOOST_CHECK_EQUAL(plain.successful_hashes, 4U);
    // A sequence that is already stale ends the batch before the first hash.
    auto stale = wallet.RunShadowPowMiningBatch(
        work, 0, 1, 4, generation, proof, 0, next_error_log, tip_sequence);
    BOOST_CHECK(stale.status == WalletPowMiningGrindStatus::EXHAUSTED);
    BOOST_CHECK_EQUAL(stale.successful_hashes, 0U);
    wallet.m_pow_mining_enabled = false;
}

BOOST_AUTO_TEST_CASE(miner_thread_ignores_tips_and_lock_waits_while_chain_not_ready)
{
    // A wallet without a chain parks its miner in the one-second wait the
    // loop uses while the node is syncing, reindexing or has no chain. That
    // wait is not woken by a tip: a burst of block callbacks must not start
    // iterations that would only find the chain not ready. And time spent
    // waiting for cs_wallet before the iteration starts is not work.
    CWallet wallet{nullptr, "miner-not-ready", CreateMockableWalletDatabase()};
    wallet.m_pow_mining_enabled = true;
    wallet.m_pow_cpu_percent = 1;
    wallet.m_pow_state = interfaces::WalletPowMiningState::READY;
    {
        LOCK(wallet.cs_wallet);
        wallet.ResetPowMiningDutyCycleLocked(1, 1);
        wallet.m_pow_worker_states.assign(1, interfaces::WalletPowMiningState::READY);
        wallet.m_pow_worker_successful_hashes.assign(1, 0);
    }
    {
        // The worker's first iteration waits 600 ms for the wallet lock.
        LOCK(wallet.cs_wallet);
        LOCK(wallet.m_pow_miner_mutex);
        wallet.threadPowMinerGroup = std::make_unique<std::vector<std::thread>>();
        wallet.threadPowMinerGroup->emplace_back([&] { wallet.ThreadShadowPoWMiner(0); });
        std::this_thread::sleep_for(600ms);
    }
    const auto wait_for_period = [&](std::chrono::milliseconds limit) {
        const auto deadline = std::chrono::steady_clock::now() + limit;
        while (std::chrono::steady_clock::now() < deadline) {
            if (wallet.GetPowMiningDutyCycle().workers[0].completed_periods > 0) return true;
            std::this_thread::sleep_for(10ms);
        }
        return false;
    };
    BOOST_REQUIRE(wait_for_period(5s));
    const auto duty = wallet.GetPowMiningDutyCycle().workers[0];
    // The lock wait is in neither the active nor the explicit wait time.
    BOOST_CHECK_LT(duty.completed_active_ns, uint64_t{300'000'000});
    BOOST_CHECK_GT(duty.completed_explicit_wait_ns, uint64_t{900'000'000});

    // Let the worker settle into a fresh wait, then deliver a burst of tips.
    uint64_t before;
    do {
        before = wallet.m_pow_miner_iterations.load();
        std::this_thread::sleep_for(50ms);
    } while (wallet.m_pow_miner_iterations.load() != before);
    for (int tip = 0; tip < 10'000; ++tip) {
        wallet.m_pow_tip_signal.NotifyTip(TipInfo(static_cast<unsigned char>(tip % 200 + 1), tip));
    }
    std::this_thread::sleep_for(300ms);
    // At most the iteration that its own second brings round; never one per tip.
    BOOST_CHECK_LE(wallet.m_pow_miner_iterations.load(), before + 1);

    // Stop is prompt from inside the wait.
    const auto stop_start = std::chrono::steady_clock::now();
    wallet.StopPowMining();
    BOOST_CHECK((std::chrono::steady_clock::now() - stop_start) < 400ms);
    BOOST_CHECK(!wallet.m_pow_mining_enabled.load());
}

BOOST_AUTO_TEST_CASE(claim_attempt_timing_record)
{
    CWallet wallet{nullptr, "claim-timing", CreateMockableWalletDatabase()};
    BOOST_CHECK(!wallet.GetPowClaimTiming().valid);
    const PowMinerTipInfo tip = TipInfo(7, 1234);
    wallet.m_pow_tip_signal.NotifyTip(tip);
    {
        LOCK(wallet.m_pow_miner_mutex);
        BOOST_CHECK(wallet.BeginPowClaimAttemptLocked(tip.hash, tip.height, tip.block_time).empty());
        // A second begin for the same tip keeps the open attempt.
        BOOST_CHECK(wallet.BeginPowClaimAttemptLocked(tip.hash, tip.height, tip.block_time).empty());
    }
    wallet.NotePowClaimAttemptFirstHash(tip.hash);
    wallet.NotePowClaimAttemptBatch(tip.hash, 128, false);
    wallet.NotePowClaimAttemptBatch(uint256{8}, 999, true); // another tip: ignored
    wallet.NotePowClaimAttemptDutySleep(tip.hash, 5ms);
    wallet.NotePowClaimAttemptBatch(tip.hash, 17, true);
    // Still open: nothing published yet.
    BOOST_CHECK(!wallet.GetPowClaimTiming().valid);
    wallet.FinishPowClaimAttempt(uint256{8}, "submitted", false); // another tip: ignored
    BOOST_CHECK(!wallet.GetPowClaimTiming().valid);
    std::string line;
    {
        LOCK(wallet.m_pow_miner_mutex);
        line = wallet.FinishPowClaimAttemptLocked("submitted", false);
        BOOST_CHECK(wallet.FinishPowClaimAttemptLocked("submitted", false).empty());
    }
    const WalletPowClaimTiming timing = wallet.GetPowClaimTiming();
    BOOST_CHECK(timing.valid);
    BOOST_CHECK(timing.tip == tip.hash);
    BOOST_CHECK_EQUAL(timing.height, 1234);
    BOOST_CHECK_EQUAL(timing.block_time, tip.block_time);
    BOOST_CHECK(timing.tip_seen_known);
    BOOST_CHECK_EQUAL(timing.tip_seen_unix_ms, tip.seen_unix_ms);
    BOOST_CHECK_EQUAL(timing.result, "submitted");
    BOOST_CHECK(!timing.tip_changed);
    BOOST_CHECK_GE(timing.gate_ready_ms, 0);
    BOOST_CHECK_GE(timing.first_hash_ms, timing.gate_ready_ms);
    BOOST_CHECK_GE(timing.proof_found_ms, timing.first_hash_ms);
    BOOST_CHECK_GE(timing.mempool_accept_ms, timing.proof_found_ms);
    BOOST_CHECK_EQUAL(timing.hashes, 145U);
    BOOST_CHECK_EQUAL(timing.batches, 2U);
    BOOST_CHECK_EQUAL(timing.duty_sleep_ms, 5);
    // One line, every key present, in a fixed order.
    BOOST_CHECK_EQUAL(std::count(line.begin(), line.end(), '\n'), 0);
    size_t at{0};
    for (const char* key : {"Gold Rush PoW claim timing: tip=", " height=1234 ",
                            "block_time=", " tip_seen_unix_ms=", " tip_seen_known=1 ",
                            "result=submitted ", "tip_changed=0 ", "gate_ready_ms=",
                            " first_hash_ms=", " proof_found_ms=", " mempool_accept_ms=",
                            " hashes=145 ", "batches=2 ", "duty_sleep_ms=5 ",
                            "first_inv_ms=-1 ", "inv_peers_1s=0"}) {
        const size_t found = line.find(key, at);
        BOOST_CHECK_MESSAGE(found != std::string::npos, key);
        if (found != std::string::npos) at = found;
    }
    BOOST_CHECK(line.find(tip.hash.ToString().substr(0, 16)) != std::string::npos);

    // An attempt overtaken by another tip is closed as tip_changed, and a tip
    // whose block callback was not seen is marked as such.
    const uint256 unseen{11};
    {
        LOCK(wallet.m_pow_miner_mutex);
        // The claim for the first tip is submitted: a sibling worker ending
        // its last batch on that tip does not open a second record.
        BOOST_CHECK(wallet.BeginPowClaimAttemptLocked(tip.hash, tip.height, tip.block_time).empty());
        BOOST_CHECK(wallet.FinishPowClaimAttemptLocked("failed", false).empty());
        const uint256 abandoned{10};
        BOOST_CHECK(wallet.BeginPowClaimAttemptLocked(abandoned, 1235, tip.block_time + 16).empty());
        const std::string replaced =
            wallet.BeginPowClaimAttemptLocked(unseen, 1236, tip.block_time + 32);
        BOOST_CHECK(replaced.find("result=tip_changed tip_changed=1") != std::string::npos);
        BOOST_CHECK(replaced.find("mempool_accept_ms=-1") != std::string::npos);
        BOOST_CHECK(replaced.find("proof_found_ms=-1") != std::string::npos);
        BOOST_CHECK(!wallet.FinishPowClaimAttemptLocked("conflict", false).empty());
    }
    const WalletPowClaimTiming second = wallet.GetPowClaimTiming();
    BOOST_CHECK(second.tip == unseen);
    BOOST_CHECK(!second.tip_seen_known);
    BOOST_CHECK_EQUAL(second.result, "conflict");
    BOOST_CHECK_EQUAL(second.mempool_accept_ms, -1);
    BOOST_CHECK_EQUAL(second.first_hash_ms, -1);
    BOOST_CHECK_EQUAL(second.first_inv_ms, -1);
    BOOST_CHECK_EQUAL(second.inv_peers_1s, 0U);
}

BOOST_AUTO_TEST_CASE(claim_relay_timing_is_appended_when_known)
{
    CWallet wallet{nullptr, "claim-relay-timing", CreateMockableWalletDatabase()};
    const PowMinerTipInfo tip = TipInfo(21, 2000);
    wallet.m_pow_tip_signal.NotifyTip(tip);
    const COutPoint claim_input{uint256{77}, 3};
    const COutPoint earlier_input{uint256{78}, 0};
    // An announcement from before the attempt belongs to an earlier claim on
    // the same input and is never reported for this one.
    GetClaimRelayTracker().NoteAnnounced(
        earlier_input, uint256{1}, std::chrono::steady_clock::now() - 1h);
    std::this_thread::sleep_for(5ms);
    {
        LOCK(wallet.m_pow_miner_mutex);
        BOOST_CHECK(wallet.BeginPowClaimAttemptLocked(tip.hash, tip.height, tip.block_time).empty());
    }
    wallet.NotePowClaimAttemptFirstHash(tip.hash);
    wallet.NotePowClaimAttemptBatch(tip.hash, 9, true);
    {
        LOCK(wallet.m_pow_miner_mutex);
        // The line of a submitted claim is held for its relay figures.
        BOOST_CHECK(wallet.FinishPowClaimAttemptLocked("submitted", false, &claim_input).empty());
        BOOST_CHECK(wallet.FlushPowClaimRelayTimingLocked(/*force=*/false).empty());
    }
    WalletPowClaimTiming timing = wallet.GetPowClaimTiming();
    BOOST_CHECK(timing.valid);
    BOOST_CHECK_EQUAL(timing.result, "submitted");
    BOOST_CHECK_EQUAL(timing.first_inv_ms, -1);
    BOOST_CHECK_EQUAL(timing.inv_peers_1s, 0U);

    // The message handler announces the claim to two peers, then to a third
    // more than a second later.
    const auto announced = std::chrono::steady_clock::now();
    GetClaimRelayTracker().NoteAnnounced(claim_input, uint256{5}, announced);
    GetClaimRelayTracker().NoteAnnounced(claim_input, uint256{5}, announced + 10ms);
    GetClaimRelayTracker().NoteAnnounced(claim_input, uint256{5}, announced + 1500ms);
    timing = wallet.GetPowClaimTiming();
    BOOST_CHECK_GE(timing.first_inv_ms, timing.proof_found_ms);
    BOOST_CHECK_EQUAL(timing.inv_peers_1s, 2U);
    std::string line;
    {
        LOCK(wallet.m_pow_miner_mutex);
        // Less than a second after the first announcement: still held.
        BOOST_CHECK(wallet.FlushPowClaimRelayTimingLocked(/*force=*/false).empty());
        line = wallet.FlushPowClaimRelayTimingLocked(/*force=*/true);
        BOOST_CHECK(wallet.FlushPowClaimRelayTimingLocked(/*force=*/true).empty());
    }
    BOOST_CHECK_EQUAL(std::count(line.begin(), line.end(), '\n'), 0);
    BOOST_CHECK(line.find("result=submitted ") != std::string::npos);
    BOOST_CHECK(line.find(strprintf(" duty_sleep_ms=0 first_inv_ms=%d inv_peers_1s=2", timing.first_inv_ms)) != std::string::npos);
    BOOST_CHECK_EQUAL(line.substr(line.size() - 14), "inv_peers_1s=2");
    // The published record keeps the figures after the line went out.
    timing = wallet.GetPowClaimTiming();
    BOOST_CHECK_GE(timing.first_inv_ms, 0);
    BOOST_CHECK_EQUAL(timing.inv_peers_1s, 2U);

    // A held line goes out with the next attempt's line, never after it.
    const PowMinerTipInfo next_tip = TipInfo(22, 2001);
    wallet.m_pow_tip_signal.NotifyTip(next_tip);
    {
        LOCK(wallet.m_pow_miner_mutex);
        BOOST_CHECK(wallet.BeginPowClaimAttemptLocked(next_tip.hash, next_tip.height, next_tip.block_time).empty());
        BOOST_CHECK(wallet.FinishPowClaimAttemptLocked("submitted", false, &earlier_input).empty());
        BOOST_CHECK(wallet.BeginPowClaimAttemptLocked(uint256{23}, 2002, next_tip.block_time + 16).empty());
        const std::string both = wallet.FinishPowClaimAttemptLocked("failed", false);
        BOOST_CHECK_EQUAL(std::count(both.begin(), both.end(), '\n'), 1);
        const size_t held_at = both.find("result=submitted ");
        const size_t failed_at = both.find("result=failed ");
        BOOST_CHECK(held_at != std::string::npos && failed_at != std::string::npos && held_at < failed_at);
        // The stale announcement of the earlier input was not attributed.
        BOOST_CHECK(both.find("first_inv_ms=-1 inv_peers_1s=0\n") != std::string::npos);
    }

    // Another claim transaction on the same input starts its record over.
    GetClaimRelayTracker().NoteAnnounced(claim_input, uint256{6}, announced + 2s);
    const auto restarted = GetClaimRelayTracker().Get(claim_input);
    BOOST_REQUIRE(restarted.has_value());
    BOOST_CHECK(restarted->txid == uint256{6});
    BOOST_CHECK_EQUAL(restarted->peers_total, 1U);
    BOOST_CHECK_EQUAL(restarted->peers_1s, 1U);
}

BOOST_AUTO_TEST_SUITE_END()
} // namespace wallet
