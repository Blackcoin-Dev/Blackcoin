// Copyright (c) 2026 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_WALLET_POW_MINER_TIP_SIGNAL_H
#define BITCOIN_WALLET_POW_MINER_TIP_SIGNAL_H

#include <uint256.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <optional>

namespace wallet {

/** The tip the wallet last processed, as the PoW miner needs it. */
struct PowMinerTipInfo {
    uint256 hash;
    int height{-1};
    /** The block's own timestamp; zero when it is not known (a disconnect). */
    int64_t block_time{0};
    /** Steady time at which the wallet's block callback was entered. */
    std::chrono::steady_clock::time_point seen{};
    /** The same instant on the system clock, in milliseconds. */
    int64_t seen_unix_ms{0};
};

/** Wakes the PoW miner workers when the wallet's tip changes.
 *
 * The wallet's block callbacks call NotifyTip() under cs_wallet, in the same
 * critical section that updates the wallet's last processed block. A worker
 * samples a Baseline before it reads chain and wallet state, so a tip that
 * arrives at any later point of its iteration is never missed: every wait
 * against that baseline returns at once.
 *
 * This mutex is a leaf: nothing is locked while it is held. */
class PowMinerTipSignal
{
public:
    struct Baseline {
        uint64_t tip{0};
        uint64_t gate{0};
        uint64_t poke{0};
        uint64_t claim{0};
    };
    enum class Wake { TIMEOUT, TIP, GATE, POKE, CLAIM };

    /** The wallet moved to a new tip (connect or disconnect). */
    void NotifyTip(const PowMinerTipInfo& tip)
    {
        {
            std::lock_guard<std::mutex> lock{m_mutex};
            m_tip = tip;
            m_tip_seq.fetch_add(1, std::memory_order_release);
        }
        m_cv.notify_all();
    }

    /** Worker zero published a different mining gate for its siblings. */
    void NotifyGate()
    {
        {
            std::lock_guard<std::mutex> lock{m_mutex};
            ++m_gate_seq;
        }
        m_cv.notify_all();
    }

    /** Make every waiter re-check its own stop conditions now. */
    void Poke()
    {
        {
            std::lock_guard<std::mutex> lock{m_mutex};
            ++m_poke_seq;
        }
        m_cv.notify_all();
    }

    /** The mempool dropped a live claim of this wallet for a reason other
     * than a block: it may be relayed again or replaced now. */
    void NotifyClaimRemoved()
    {
        {
            std::lock_guard<std::mutex> lock{m_mutex};
            ++m_claim_seq;
        }
        m_cv.notify_all();
    }

    /** Lock-free; read once per hash by the proof search. */
    uint64_t TipSequence() const { return m_tip_seq.load(std::memory_order_acquire); }

    Baseline Sample() const
    {
        std::lock_guard<std::mutex> lock{m_mutex};
        return {m_tip_seq.load(std::memory_order_relaxed), m_gate_seq, m_poke_seq, m_claim_seq};
    }

    /** The recorded arrival of this exact tip, if it is the latest one. */
    std::optional<PowMinerTipInfo> TipInfo(const uint256& hash) const
    {
        std::lock_guard<std::mutex> lock{m_mutex};
        if (m_tip.height < 0 || m_tip.hash != hash) return std::nullopt;
        return m_tip;
    }

    /** Wait until something changed relative to baseline, or the duration
     * passed. A tip change wins over a gate change, which wins over a removed
     * claim, which wins over a poke. */
    Wake WaitFor(std::chrono::nanoseconds duration, const Baseline& baseline,
                 bool watch_gate) const
    {
        std::unique_lock<std::mutex> lock{m_mutex};
        const auto changed = [&] {
            return m_tip_seq.load(std::memory_order_relaxed) != baseline.tip ||
                   (watch_gate && m_gate_seq != baseline.gate) ||
                   m_claim_seq != baseline.claim ||
                   m_poke_seq != baseline.poke;
        };
        if (duration.count() > 0) m_cv.wait_for(lock, duration, changed);
        if (m_tip_seq.load(std::memory_order_relaxed) != baseline.tip) return Wake::TIP;
        if (watch_gate && m_gate_seq != baseline.gate) return Wake::GATE;
        if (m_claim_seq != baseline.claim) return Wake::CLAIM;
        if (m_poke_seq != baseline.poke) return Wake::POKE;
        return Wake::TIMEOUT;
    }

private:
    mutable std::mutex m_mutex;
    mutable std::condition_variable m_cv;
    std::atomic<uint64_t> m_tip_seq{0};
    uint64_t m_gate_seq{0};
    uint64_t m_poke_seq{0};
    uint64_t m_claim_seq{0};
    PowMinerTipInfo m_tip;
};

} // namespace wallet
#endif // BITCOIN_WALLET_POW_MINER_TIP_SIGNAL_H
