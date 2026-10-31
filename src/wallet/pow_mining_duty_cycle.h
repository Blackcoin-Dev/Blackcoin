// Copyright (c) 2026 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_WALLET_POW_MINING_DUTY_CYCLE_H
#define BITCOIN_WALLET_POW_MINING_DUTY_CYCLE_H

#include <algorithm>
#include <chrono>
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

} // namespace wallet
#endif // BITCOIN_WALLET_POW_MINING_DUTY_CYCLE_H
