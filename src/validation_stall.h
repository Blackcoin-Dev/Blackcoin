// Copyright (c) 2026 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_VALIDATION_STALL_H
#define BITCOIN_VALIDATION_STALL_H

#include <algorithm>
#include <chrono>

/**
 * Block-download timeouts are measured from m_downloading_since. When the
 * message handler thread is itself parked inside ProcessNewBlock (for example
 * waiting for the validation-interface queue to drain, L15), no peer can make
 * progress and the clock must not run against the peer for that time.
 *
 * These helpers are pure so they can be tested without a PeerManager.
 */
namespace validation_stall {

/** Stalls shorter than this are normal block processing and are not excused. */
static constexpr std::chrono::microseconds MIN_EXCUSED_STALL{std::chrono::seconds{1}};
/** One stall never excuses more than this, bounding what a silent peer can gain. */
static constexpr std::chrono::microseconds MAX_EXCUSED_STALL{std::chrono::seconds{300}};

/**
 * How far to move a timestamp that started a peer clock (m_downloading_since,
 * m_stalling_since) forward after our stall [stall_start, stall_end].
 * Returns 0 for clocks started at or after the stall end, and for stalls
 * shorter than MIN_EXCUSED_STALL. Only the overlap of the clock with the
 * (capped) stall is returned.
 */
inline std::chrono::microseconds ShiftForStall(std::chrono::microseconds clock_start,
                                              std::chrono::microseconds stall_start,
                                              std::chrono::microseconds stall_end)
{
    using us = std::chrono::microseconds;
    if (stall_end - stall_start < MIN_EXCUSED_STALL) return us{0};
    const us capped_end = std::min(stall_end, stall_start + MAX_EXCUSED_STALL);
    if (clock_start >= capped_end) return us{0};
    return capped_end - std::max(clock_start, stall_start);
}

} // namespace validation_stall

#endif // BITCOIN_VALIDATION_STALL_H
