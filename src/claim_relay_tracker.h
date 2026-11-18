// Copyright (c) 2026 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_CLAIM_RELAY_TRACKER_H
#define BITCOIN_CLAIM_RELAY_TRACKER_H

#include <primitives/transaction.h>
#include <uint256.h>

#include <chrono>
#include <cstdint>
#include <deque>
#include <map>
#include <mutex>
#include <optional>

/** When a Gold Rush claim was first announced to peers, and to how many. */
struct ClaimRelayStats {
    uint256 txid;
    std::chrono::steady_clock::time_point first_announced{};
    /** Peers the claim was announced to within one second of the first. */
    uint32_t peers_1s{0};
    /** Of those, the peers that were sent the whole transaction. */
    uint32_t pushed_1s{0};
    uint32_t peers_total{0};
};

/** Process-wide, bounded record of claim announcements, written by the
 * message handler when it sends an inv for a claim and read by the wallet's
 * miner for its timing line. Claims are keyed by the fee input their proof is
 * bound to, which the miner knows before the transaction exists. The
 * statistics are measurements only and feed no decision.
 *
 * It also carries the miner's one-shot marks for claims it is about to
 * submit itself. The message handler sends such a claim to peers as a whole
 * transaction, once, when it first relays it. Only the wallet's miner sets a
 * mark, so nothing a peer sends can cause a push.
 *
 * The mutex is a leaf: nothing is locked while it is held. */
class ClaimRelayTracker
{
public:
    static constexpr size_t MAX_ENTRIES{256};

    static constexpr size_t MAX_LOCAL_MARKS{16};

    /** The miner is about to submit a claim bound to this fee input. */
    void MarkLocalClaim(const COutPoint& claim_input)
    {
        std::lock_guard<std::mutex> lock{m_mutex};
        if (m_local_marks.size() >= MAX_LOCAL_MARKS) m_local_marks.erase(m_local_marks.begin());
        m_local_marks[claim_input] = true;
    }

    /** The submission ended; a mark the relay did not use is withdrawn. */
    void UnmarkLocalClaim(const COutPoint& claim_input)
    {
        std::lock_guard<std::mutex> lock{m_mutex};
        m_local_marks.erase(claim_input);
    }

    /** True once per mark: the first relay of the marked claim. */
    bool ConsumeLocalClaim(const COutPoint& claim_input)
    {
        std::lock_guard<std::mutex> lock{m_mutex};
        return m_local_marks.erase(claim_input) > 0;
    }

    void NoteAnnounced(const COutPoint& claim_input, const uint256& txid,
                       std::chrono::steady_clock::time_point now,
                       bool pushed = false)
    {
        std::lock_guard<std::mutex> lock{m_mutex};
        auto it = m_stats.find(claim_input);
        if (it != m_stats.end() && it->second.txid != txid) {
            // Another claim transaction on the same input starts over.
            it->second = ClaimRelayStats{};
        } else if (it == m_stats.end()) {
            if (m_order.size() >= MAX_ENTRIES) {
                m_stats.erase(m_order.front());
                m_order.pop_front();
            }
            m_order.push_back(claim_input);
            it = m_stats.emplace(claim_input, ClaimRelayStats{}).first;
        }
        ClaimRelayStats& stats = it->second;
        if (stats.peers_total == 0) {
            stats.txid = txid;
            stats.first_announced = now;
        }
        ++stats.peers_total;
        if (now - stats.first_announced <= std::chrono::seconds{1}) {
            ++stats.peers_1s;
            if (pushed) ++stats.pushed_1s;
        }
    }

    std::optional<ClaimRelayStats> Get(const COutPoint& claim_input) const
    {
        std::lock_guard<std::mutex> lock{m_mutex};
        const auto it = m_stats.find(claim_input);
        if (it == m_stats.end()) return std::nullopt;
        return it->second;
    }

private:
    mutable std::mutex m_mutex;
    std::map<COutPoint, ClaimRelayStats> m_stats;
    std::deque<COutPoint> m_order;
    std::map<COutPoint, bool> m_local_marks;
};

inline ClaimRelayTracker& GetClaimRelayTracker()
{
    static ClaimRelayTracker tracker;
    return tracker;
}

#endif // BITCOIN_CLAIM_RELAY_TRACKER_H
