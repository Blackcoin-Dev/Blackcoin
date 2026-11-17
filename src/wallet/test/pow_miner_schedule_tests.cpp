// Copyright (c) 2026 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <wallet/pow_miner_tip_signal.h>
#include <wallet/pow_mining_duty_cycle.h>
#include <wallet/wallet.h>

#include <addresstype.h>
#include <interfaces/wallet.h>
#include <script/script.h>
#include <shadow.h>
#include <test/util/setup_common.h>
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
    nanoseconds max_debt{0};
};

ScheduleRun RunSchedule(int cpu_percent, nanoseconds spacing, nanoseconds interval,
                        uint64_t tips, nanoseconds batch, nanoseconds overhead,
                        uint64_t batches_to_proof)
{
    PowMiningDutyLedger ledger{cpu_percent, spacing};
    ScheduleRun run;
    nanoseconds now{0};
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
                ledger.Credit(wait);
                now = next_tip;
                break;
            }
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
            ledger.Charge(search, overhead);
            now += overhead + search;
            run.active += overhead + search;
            if (found) ++run.proofs;
            run.max_debt = std::max(run.max_debt, ledger.Debt());
            const bool tip_arrived = now >= next_tip;
            const bool pending = !found || tip_arrived;
            const bool below_cap = ledger.MayDefer();
            const nanoseconds wanted = ledger.SleepNeeded(pending);
            if (pending && below_cap) BOOST_REQUIRE_EQUAL(wanted.count(), 0);
            if (wanted.count() == 0 || tip_arrived) continue;
            // A new tip interrupts the sleep the moment it arrives.
            const nanoseconds slept = std::min(wanted, next_tip - now);
            if (slept < wanted) ++run.interrupted_sleeps;
            ledger.Credit(slept);
            now += slept;
            run.duty_sleep += slept;
            if (pending && below_cap) run.sleep_below_cap += slept;
            if (!found) run.sleep_before_proof += slept;
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
    return ledger.Ceiling() * 2 + PowMiningDutyDebt(iteration, cpu_percent) * 2 +
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
    // Two spacings of budget: 2 * 64 s * 99%.
    BOOST_CHECK_EQUAL(ledger.Ceiling().count(), nanoseconds{126'720ms}.count());
    BOOST_CHECK(ledger.MayDefer());
    BOOST_CHECK_EQUAL(ledger.SleepNeeded(true).count(), 0);
    BOOST_CHECK_EQUAL(ledger.SleepNeeded(false).count(), 0);
    ledger.Charge(/*search=*/1s, /*other=*/10ms);
    BOOST_CHECK_EQUAL(ledger.SearchDebt().count(), nanoseconds{99s}.count());
    BOOST_CHECK_EQUAL(ledger.OtherDebt().count(), nanoseconds{990ms}.count());
    BOOST_CHECK(ledger.MayDefer());
    BOOST_CHECK_EQUAL(ledger.SleepNeeded(true).count(), 0);
    BOOST_CHECK_EQUAL(ledger.SleepNeeded(false).count(), 99'990);
    // 1.28 s of search is the allowance at 1%; one more batch is over it and
    // only the excess is slept, which is the old interleaved delay.
    ledger.Charge(280ms, 0ns);
    BOOST_CHECK(ledger.MayDefer());
    ledger.Charge(64ms, 0ns);
    BOOST_CHECK(!ledger.MayDefer());
    BOOST_CHECK_EQUAL(ledger.SleepNeeded(true).count(),
                      PowMiningAdditionalDelay(64ms, 0ms, 1).count());
    // Lock waits and gate work are other debt: they never use the search
    // allowance, and they have their own ceiling.
    PowMiningDutyLedger contended{1, 64s};
    contended.Charge(0ns, 1200ms);
    contended.Charge(1200ms, 0ns);
    BOOST_CHECK(contended.MayDefer());
    contended.Charge(0ns, 200ms);
    BOOST_CHECK(!contended.MayDefer());
    BOOST_CHECK_EQUAL(contended.SleepNeeded(true).count(), 138'600 - 126'720);
    // Idle time pays search first, is never banked, and clears everything.
    contended.Credit(1h);
    BOOST_CHECK_EQUAL(contended.Debt().count(), 0);
    contended.Charge(10ms, 0ns);
    BOOST_CHECK_EQUAL(contended.SleepNeeded(false).count(), 990);
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
            BOOST_CHECK_GE(run.interrupted_sleeps + run.interrupted_batches, tips - 1);
        }
    }
}

BOOST_AUTO_TEST_CASE(duty_average_searches_that_hit_the_cap)
{
    // (c) The default 1% with a search of 4 s of hashing per tip, more than
    // three times the 1.28 s allowance: the worker runs its allowance first,
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
    // allows 36 s plus both ceilings (2.56 s) plus two iterations.
    const auto hour = RunSchedule(1, 64s, 16s, 225, 62'500us, 500us, 1'000'000);
    BOOST_CHECK_GE(hour.total.count(), nanoseconds{1h}.count());
    BOOST_CHECK_LE(hour.total.count(), nanoseconds{1h + 1s}.count());
    BOOST_CHECK_LE(hour.active.count(), nanoseconds{36s + 2560ms + 200ms}.count());
    // A single interval never exceeds the budget of the interval plus the
    // allowance: on 16 s blocks that is 0.16 s + 2.56 s of work at most.
    const auto first = RunSchedule(1, 64s, 16s, 1, 62'500us, 500us, 1'000'000);
    BOOST_CHECK_LE(first.active.count(), nanoseconds{160ms + 2560ms + 200ms}.count());
    // Below the cap the first 1.28 s of search runs without any sleep.
    PowMiningDutyLedger ledger{1, 64s};
    nanoseconds searched{0};
    while (ledger.SleepNeeded(true).count() == 0) {
        ledger.Charge(62'500us, 0ns);
        searched += 62'500us;
    }
    BOOST_CHECK_GE(searched.count(), nanoseconds{1280ms}.count());
    BOOST_CHECK_LE(searched.count(), nanoseconds{1280ms + 62'500us}.count());
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

BOOST_AUTO_TEST_CASE(miner_thread_wakes_on_block_signal)
{
    // A wallet without a chain parks its miner in the one-second availability
    // wait, the same wait the loop uses for "wait for the next tip". Before
    // the tip signal the loop could only leave it when the second was over.
    CWallet wallet{nullptr, "miner-wake", CreateMockableWalletDatabase()};
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
        LOCK(wallet.m_pow_miner_mutex);
        wallet.threadPowMinerGroup = std::make_unique<std::vector<std::thread>>();
        wallet.threadPowMinerGroup->emplace_back([&] { wallet.ThreadShadowPoWMiner(0); });
    }
    const auto wait_for_iteration = [&](uint64_t after, std::chrono::milliseconds limit) {
        const auto deadline = std::chrono::steady_clock::now() + limit;
        while (wallet.m_pow_miner_iterations.load() <= after &&
               std::chrono::steady_clock::now() < deadline) {
            std::this_thread::sleep_for(1ms);
        }
        return wallet.m_pow_miner_iterations.load() > after;
    };
    BOOST_REQUIRE(wait_for_iteration(0, 5s));
    std::vector<int64_t> reaction_ms;
    for (int round = 0; round < 10; ++round) {
        // Let the worker settle into a fresh one-second wait.
        const uint64_t before = wallet.m_pow_miner_iterations.load();
        std::this_thread::sleep_for(50ms);
        if (wallet.m_pow_miner_iterations.load() != before) {
            --round; // The second ran out just now; take another sample.
            continue;
        }
        const auto notified = std::chrono::steady_clock::now();
        wallet.m_pow_tip_signal.NotifyTip(TipInfo(static_cast<unsigned char>(round + 1), round));
        BOOST_REQUIRE(wait_for_iteration(before, 5s));
        reaction_ms.push_back(std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - notified).count());
    }
    std::sort(reaction_ms.begin(), reaction_ms.end());
    BOOST_TEST_MESSAGE("signal to next miner iteration, ms: median "
        << reaction_ms[reaction_ms.size() / 2] << " max " << reaction_ms.back());
    // Far below the old one-second poll, with room for a loaded machine.
    BOOST_CHECK_LT(reaction_ms.back(), 200);

    // Without a signal the worker stays in its wait: no busy loop.
    const uint64_t idle_before = wallet.m_pow_miner_iterations.load();
    std::this_thread::sleep_for(300ms);
    BOOST_CHECK_LE(wallet.m_pow_miner_iterations.load(), idle_before + 1);

    // Stop is prompt from inside a wait.
    const auto stop_start = std::chrono::steady_clock::now();
    wallet.StopPowMining();
    BOOST_CHECK((std::chrono::steady_clock::now() - stop_start) < 200ms);
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
                            " hashes=145 ", "batches=2 ", "duty_sleep_ms=5"}) {
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
}

BOOST_AUTO_TEST_SUITE_END()
} // namespace wallet
