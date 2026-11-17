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
 * documented accounting conservatively counts as work), and each part may be
 * carried up to Ceiling(): the idle time that BURST_SPACINGS target block
 * spacings of budget pay for. In CPU terms a worker may run ahead of its
 * budget by at most BURST_SPACINGS * spacing * cpu_percent / 100 of search
 * (1.28 s at the default 1% and 64 s spacing) and as much again of other
 * work. Above a ceiling the worker sleeps the excess after every iteration,
 * which is exactly the old interleaved duty cycle. Keeping the two parts
 * apart means a slow gate or a contended lock cannot use up the search
 * allowance.
 *
 * Because debt never exceeds the two ceilings plus two iterations (one whose
 * sleep a new tip cut short, and the first one for that tip), active time
 * over any window of length T is at most
 *   cpu_percent/100 * (T + 2 * BURST_SPACINGS * spacing) + two iterations. */
class PowMiningDutyLedger
{
public:
    static constexpr int BURST_SPACINGS{2};

    PowMiningDutyLedger(int cpu_percent, std::chrono::nanoseconds block_spacing)
        : m_cpu_percent{std::clamp(cpu_percent, 1, 100)},
          m_ceiling{std::max(std::chrono::nanoseconds{0}, block_spacing) / 100 *
                    (BURST_SPACINGS * (100 - std::clamp(cpu_percent, 1, 100)))} {}

    int CpuPercent() const { return m_cpu_percent; }
    std::chrono::nanoseconds Ceiling() const { return m_ceiling; }
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
     * Idle time beyond the debt is not banked. */
    void Credit(std::chrono::nanoseconds waited)
    {
        if (waited.count() <= 0) return;
        const auto search_paid = std::min(waited, m_search_debt);
        m_search_debt -= search_paid;
        m_other_debt -= std::min(waited - search_paid, m_other_debt);
    }

    /** Whether the whole debt may be carried while claim work is pending. */
    bool MayDefer() const
    {
        return m_search_debt <= m_ceiling && m_other_debt <= m_ceiling;
    }

    /** Sleep owed now. With claim work pending this is only the excess over
     * the ceilings (zero below them); otherwise it is the whole debt. */
    std::chrono::milliseconds SleepNeeded(bool work_pending) const
    {
        const auto owed = work_pending
            ? std::max(std::chrono::nanoseconds{0}, m_search_debt - m_ceiling) +
              std::max(std::chrono::nanoseconds{0}, m_other_debt - m_ceiling)
            : Debt();
        return std::chrono::ceil<std::chrono::milliseconds>(owed);
    }

private:
    static std::chrono::nanoseconds Add(std::chrono::nanoseconds a, std::chrono::nanoseconds b)
    {
        const auto limit = std::chrono::nanoseconds{std::numeric_limits<int64_t>::max() / 4};
        return a > limit - b ? limit : a + b;
    }

    int m_cpu_percent;
    std::chrono::nanoseconds m_ceiling;
    std::chrono::nanoseconds m_search_debt{0};
    std::chrono::nanoseconds m_other_debt{0};
};

} // namespace wallet
#endif // BITCOIN_WALLET_POW_MINING_DUTY_CYCLE_H
