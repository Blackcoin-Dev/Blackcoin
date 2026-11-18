// Copyright (c) 2026 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_WALLET_POW_MINING_DUTY_CYCLE_H
#define BITCOIN_WALLET_POW_MINING_DUTY_CYCLE_H

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <limits>

namespace wallet {

/** Whole-iteration duty budget. Explicit waits are excluded from active work
 * and credited against the target period. Lock waits count conservatively as
 * active work. This bounds duty over completed work/delay periods, not bursts
 * inside a batch, and does not promise an exact process CPU percentage. */
inline std::chrono::milliseconds PowMiningAdditionalDelay(
    std::chrono::nanoseconds elapsed, std::chrono::nanoseconds explicit_wait,
    int cpu_percent)
{
    cpu_percent = std::clamp(cpu_percent, 1, 100);
    const auto active = std::max(std::chrono::nanoseconds{0}, elapsed - explicit_wait);
    const int64_t whole = active.count() / cpu_percent;
    const int64_t remainder = active.count() % cpu_percent;
    const int64_t limit = std::numeric_limits<int64_t>::max();
    const int64_t fraction = (remainder * 100 + cpu_percent - 1) / cpu_percent;
    const auto target = std::chrono::nanoseconds{
        whole > (limit - fraction) / 100 ? limit : whole * 100 + fraction};
    if (target <= elapsed) return std::chrono::milliseconds{0};
    return std::chrono::ceil<std::chrono::milliseconds>(target - elapsed);
}

/** Duty debt owed for a span of active work: the idle time that makes the
 * span average out to cpu_percent. Rounded up, saturating. */
inline std::chrono::nanoseconds PowMiningDutyDebt(
    std::chrono::nanoseconds active, int cpu_percent)
{
    cpu_percent = std::clamp(cpu_percent, 1, 100);
    if (active.count() <= 0 || cpu_percent == 100) return std::chrono::nanoseconds{0};
    const int64_t idle = 100 - cpu_percent;
    const int64_t whole = active.count() / cpu_percent;
    const int64_t remainder = active.count() % cpu_percent;
    const int64_t fraction = (remainder * idle + cpu_percent - 1) / cpu_percent;
    const int64_t limit = std::numeric_limits<int64_t>::max() / 4;
    if (whole > (limit - fraction) / idle) return std::chrono::nanoseconds{limit};
    return std::chrono::nanoseconds{whole * idle + fraction};
}

/** What the end of an iteration does to the open telemetry period. */
enum class PowMiningPeriodClose {
    OPEN,      //!< Keep accumulating.
    COMPLETED, //!< Report as a completed period: it is within the duty budget.
    TRUNCATED, //!< Report as truncated: the burst allowance is spent.
};

/** A period that opened with start_debt and ends with debt_now has spent at
 * least as much idle time as its active work owes whenever debt_now is not
 * above start_debt, so its active fraction is at most cpu_percent and it may
 * be reported as completed. Requiring the debt to reach zero would never
 * complete a period of a worker whose debt sits at its ceiling (no proof found
 * for many blocks); instead, when the ceiling forces a duty sleep and the debt
 * is still above where the period began, the period is closed as truncated
 * and the next one opens at the pinned debt, where it completes. */
inline PowMiningPeriodClose PowMiningClosePeriod(
    std::chrono::nanoseconds debt_now, std::chrono::nanoseconds start_debt,
    bool excess_slept)
{
    if (debt_now <= start_debt) return PowMiningPeriodClose::COMPLETED;
    return excess_slept ? PowMiningPeriodClose::TRUNCATED : PowMiningPeriodClose::OPEN;
}

/** Sleep the worker owes at the end of an iteration, in two parts.
 * excess is the debt above the ceilings: it is the duty cycle itself and is
 * never cut short by a new tip. remainder is the rest of the carried debt, slept
 * only when no claim work is pending, and a new tip ends it at once. */
struct PowMiningSleepPlan {
    std::chrono::milliseconds excess{0};
    std::chrono::milliseconds remainder{0};
};

/** Whether an iteration must leave the carried debt below the ceilings for a
 * later iteration to sleep off.
 *
 * Claim work that is still pending and a tip that arrived during the
 * iteration are the work-first cases. The third case is an iteration that ran
 * a proof search and has no more work, typically the one that found the proof
 * and submitted the claim. What the miner reports (the hashrate, which reads
 * zero whenever the worker is not searching, the worker state, and the gate
 * worker zero publishes for its siblings) is brought up to date by the next
 * iteration, when it finds nothing to do. Sleeping the whole debt first left
 * the rate of the finished search on display for up to both ceilings (about
 * two minutes at 1%) while the worker was only waiting for the next block.
 * The next iteration takes its normal wait and then sleeps the debt, so
 * nothing is forgiven; it only costs one more gate evaluation. */
inline bool PowMiningCarryRemainder(bool work_pending, bool tip_arrived, bool searched)
{
    return work_pending || tip_arrived || searched;
}

/** Per-worker duty ledger for the work-first schedule.
 *
 * The long-run rule is the documented one: every span of active work owes
 * PowMiningDutyDebt() of idle time, and every explicit wait or duty sleep
 * pays that debt down. What changed is when the debt is paid. While a claim
 * for the current tip is still being worked on the worker does not sleep;
 * the debt is carried and slept off once the claim is submitted (or the tip
 * is given up), before any further optional work.
 *
 * The carry is bounded. Debt is kept in two parts, proof search and
 * everything else (gate evaluation, input selection, lock waits, which the
 * documented accounting conservatively counts as work). Each part may be
 * carried up to its ceiling, the idle time that BURST_SPACINGS target block
 * spacings of budget pay for; the search part is further bounded by the idle
 * time that SEARCH_BURST_WALL (10 s) of search owes, whichever is smaller.
 * In CPU terms a worker may run ahead of its budget by at most
 * min(BURST_SPACINGS * spacing * cpu_percent / 100, SEARCH_BURST_WALL) of
 * search (0.64 s at the default 1% and 64 s spacing, 10 s at 60%) and by at
 * most BURST_SPACINGS * spacing * cpu_percent / 100 of other work (38.4 s at
 * 60%). Above a ceiling the worker sleeps the excess after every iteration,
 * which is the old interleaved duty cycle: it sleeps what each iteration owes. Keeping the two parts
 * apart means a slow gate or a contended lock cannot use up the search
 * allowance. Debt is clamped at the ceilings after every sleep, so it cannot
 * grow without bound whatever happens.
 *
 * Because debt never exceeds the two ceilings plus two iterations, active time
 * over any window of length T is at most
 *   cpu_percent/100 * T + (search allowance + other allowance) + two iterations. */
class PowMiningDutyLedger
{
public:
    static constexpr int BURST_SPACINGS{1};
    /** Longest wall time of search that may run without a duty sleep. */
    static constexpr std::chrono::seconds SEARCH_BURST_WALL{10};

    PowMiningDutyLedger(int cpu_percent, std::chrono::nanoseconds block_spacing)
        : m_cpu_percent{std::clamp(cpu_percent, 1, 100)},
          m_other_ceiling{std::max(std::chrono::nanoseconds{0}, block_spacing) / 100 *
                          (BURST_SPACINGS * (100 - std::clamp(cpu_percent, 1, 100)))},
          m_search_ceiling{std::min(m_other_ceiling,
                                    PowMiningDutyDebt(SEARCH_BURST_WALL, m_cpu_percent))} {}

    int CpuPercent() const { return m_cpu_percent; }
    /** Ceiling of the non-search debt (spacing based). */
    std::chrono::nanoseconds Ceiling() const { return m_other_ceiling; }
    std::chrono::nanoseconds SearchCeiling() const { return m_search_ceiling; }
    std::chrono::nanoseconds SearchDebt() const { return m_search_debt; }
    std::chrono::nanoseconds OtherDebt() const { return m_other_debt; }
    std::chrono::nanoseconds Debt() const { return m_search_debt + m_other_debt; }

    /** Record active work. search is time inside the proof search itself;
     * other is every other active span of the iteration. */
    void Charge(std::chrono::nanoseconds search, std::chrono::nanoseconds other)
    {
        m_search_debt = Add(m_search_debt, PowMiningDutyDebt(search, m_cpu_percent));
        m_other_debt = Add(m_other_debt, PowMiningDutyDebt(other, m_cpu_percent));
    }

    /** Record idle time actually spent (an explicit wait or a duty sleep).
     * It pays what is above a ceiling first, so a duty sleep owed for one
     * part's excess is never spent on the other part's allowance; then the
     * search part, then the rest. Idle time beyond the debt is not banked. */
    void Credit(std::chrono::nanoseconds waited)
    {
        if (waited.count() <= 0) return;
        const auto pay = [&waited](std::chrono::nanoseconds& debt, std::chrono::nanoseconds limit) {
            const auto paid = std::min(waited, std::max(std::chrono::nanoseconds{0}, debt - limit));
            debt -= paid;
            waited -= paid;
        };
        pay(m_search_debt, m_search_ceiling);
        pay(m_other_debt, m_other_ceiling);
        pay(m_search_debt, std::chrono::nanoseconds{0});
        pay(m_other_debt, std::chrono::nanoseconds{0});
    }

    /** Hard stop on accumulation: neither part is ever carried above its
     * ceiling past the end of an iteration's sleeps. */
    void ClampToCeilings()
    {
        m_search_debt = std::min(m_search_debt, m_search_ceiling);
        m_other_debt = std::min(m_other_debt, m_other_ceiling);
    }

    /** Whether the whole debt may be carried while claim work is pending. */
    bool MayDefer() const
    {
        return m_search_debt <= m_search_ceiling && m_other_debt <= m_other_ceiling;
    }

    /** Sleep owed now. With claim work pending this is only the excess over
     * the ceilings (zero below them); otherwise it is the whole debt. */
    std::chrono::milliseconds SleepNeeded(bool work_pending) const
    {
        const auto owed = work_pending
            ? std::max(std::chrono::nanoseconds{0}, m_search_debt - m_search_ceiling) +
              std::max(std::chrono::nanoseconds{0}, m_other_debt - m_other_ceiling)
            : Debt();
        return std::chrono::ceil<std::chrono::milliseconds>(owed);
    }

    /** The sleep for the end of an iteration, split into the part a tip may
     * not cut short and the part it may. iteration_debt is the debt this
     * iteration created. When either part is over its ceiling the worker has
     * left the burst and is on the interleaved duty cycle: it sleeps at least
     * what the iteration itself owes, so debt stops growing at once and the
     * telemetry period can close. */
    PowMiningSleepPlan Plan(bool work_pending,
                            std::chrono::nanoseconds iteration_debt = std::chrono::nanoseconds{0}) const
    {
        PowMiningSleepPlan plan;
        auto excess = std::max(std::chrono::nanoseconds{0}, m_search_debt - m_search_ceiling) +
                      std::max(std::chrono::nanoseconds{0}, m_other_debt - m_other_ceiling);
        if (excess.count() > 0) {
            excess = std::max(excess, std::min(std::max(std::chrono::nanoseconds{0}, iteration_debt), Debt()));
        }
        plan.excess = std::chrono::ceil<std::chrono::milliseconds>(excess);
        if (!work_pending) {
            plan.remainder = std::max(std::chrono::milliseconds{0},
                                      SleepNeeded(/*work_pending=*/false) - plan.excess);
        }
        return plan;
    }

private:
    static std::chrono::nanoseconds Add(std::chrono::nanoseconds a, std::chrono::nanoseconds b)
    {
        const auto limit = std::chrono::nanoseconds{std::numeric_limits<int64_t>::max() / 4};
        return a > limit - b ? limit : a + b;
    }

    int m_cpu_percent;
    std::chrono::nanoseconds m_other_ceiling;
    std::chrono::nanoseconds m_search_ceiling;
    std::chrono::nanoseconds m_search_debt{0};
    std::chrono::nanoseconds m_other_debt{0};
};

} // namespace wallet
#endif // BITCOIN_WALLET_POW_MINING_DUTY_CYCLE_H
