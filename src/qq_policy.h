// Copyright (c) 2026 The Blackcoin Core developers
// Distributed under the MIT software license, see COPYING.
#ifndef BITCOIN_QQ_POLICY_H
#define BITCOIN_QQ_POLICY_H

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstddef>

namespace qq {
using Clock = std::chrono::steady_clock;
constexpr auto PROBE_RESIDENCE = std::chrono::seconds{120};
constexpr auto RETRY_INTERVAL = std::chrono::seconds{30};
constexpr auto DNS_COOLDOWN = std::chrono::minutes{30};
constexpr size_t MAX_ADDR_FETCHES{64};
constexpr int MAX_CANDIDATE_DRAWS{100};
/** Full-relay peers that must be connected before QQ pursuit may use vacancies. */
constexpr int LEGACY_FIRST_FLOOR{4};
/** A legacy address that failed a legacy-first dial yields to QQ hints for this long. */
constexpr auto LEGACY_FIRST_FAILED_MEMORY = std::chrono::minutes{10};
/** How long a completed handshake with a QQ-capable peer counts as evidence that QQ peers are reachable. */
constexpr auto EVIDENCE_WINDOW = std::chrono::minutes{30};

inline int LegacyFirstFloor(int full_relay_capacity)
{
    return std::min(LEGACY_FIRST_FLOOR, std::max(0, full_relay_capacity));
}

/** The QQ deficit cannot be satisfied while the chain is not ready, unless a QQ peer is already connected. */
inline int EffectiveDeficit(int deficit, bool chain_ready, bool qq_peer_connected)
{
    return (chain_ready || qq_peer_connected) ? deficit : 0;
}

/**
 * Candidate selection is legacy-first (QQ-flagged addresses wait behind
 * legacy ones) unless QQ peers are known to be reachable and enough
 * full-relay peers are already connected. QQ pursuit then uses only the
 * slots above the floor.
 */
inline bool LegacyFirst(int qq_target, int connected_full_relay, int full_relay_capacity, bool qq_evidence)
{
    return qq_target > 0 && (!qq_evidence || connected_full_relay < LegacyFirstFloor(full_relay_capacity));
}

/**
 * Legacy-first keeps legacy addresses ahead of QQ hints, but a pool of mostly
 * dead legacy addresses must not starve the hints for ever (a QQ handshake is
 * the only thing that creates QQ evidence). After this many consecutive
 * failed legacy-first full-relay dials to non-QQ addresses, the next full-relay
 * selection is a QQ turn.
 */
constexpr unsigned LEGACY_FIRST_QQ_TURN_AFTER{2};

/** True when the next full-relay selection must be a QQ turn. Never true outside legacy-first. */
inline bool LegacyFirstQQTurn(bool legacy_first, unsigned consecutive_legacy_dials)
{
    return legacy_first && consecutive_legacy_dials >= LEGACY_FIRST_QQ_TURN_AFTER;
}

/**
 * The legacy-first dial counter after a full-relay dial attempt. Only dials
 * that fail count, since a legacy peer that connects shows the pool works. A
 * QQ turn resets it whatever it dialed; a failed legacy-first dial to a
 * non-QQ address adds one; a dial to a QQ address, a dial that connected, or
 * any attempt outside legacy-first resets it.
 */
inline unsigned NextLegacyFirstStreak(unsigned streak, bool legacy_first, bool qq_turn, bool dialed_qq_flagged, bool connected)
{
    if (!legacy_first || qq_turn || dialed_qq_flagged || connected) return 0;
    return streak + 1;
}

/** Retry delays after consecutive unproductive HTTPS rounds; afterwards the normal cadence applies. */
constexpr std::chrono::seconds HTTPS_BACKOFF[]{std::chrono::seconds{60}, std::chrono::seconds{120},
                                               std::chrono::seconds{300}, std::chrono::seconds{600}};
constexpr size_t HTTPS_BACKOFF_STEPS{sizeof(HTTPS_BACKOFF) / sizeof(HTTPS_BACKOFF[0])};

/** Seconds of no peers before the zero-peer line may be logged, and the minimum spacing between lines. */
constexpr std::chrono::seconds ZERO_PEER_LOG_AFTER{60};
constexpr std::chrono::minutes ZERO_PEER_LOG_EVERY{10};

inline int EffectiveTarget(int requested, int capacity)
{
    return requested < 0 ? capacity / 2 : std::min(requested, std::max(0, capacity - 1));
}

/** Lifetime shared by the socket and queued V1 fallback, with one absolute deadline. */
struct Probe {
    const Clock::time_point deadline;
    std::atomic_bool promoted{false};
    std::atomic_bool active{true};
    std::atomic<long long> retiring_peer{-1};
    explicit Probe(Clock::time_point now) : deadline{now + PROBE_RESIDENCE} {}
    bool Expired(Clock::time_point now) const { return !promoted && now >= deadline; }
};

/** Rotating admission prevents an always-due transient class from taking every permit. */
class Arbiter {
    size_t m_next{0};
public:
    static constexpr size_t CLASSES{6};
    template <typename Due> int Pick(const Due& due)
    {
        for (size_t i = 0; i < CLASSES; ++i) {
            const auto candidate = (m_next + i) % CLASSES;
            if (due[candidate]) {
                m_next = (candidate + 1) % CLASSES;
                return candidate;
            }
        }
        return -1;
    }
};
} // namespace qq
#endif // BITCOIN_QQ_POLICY_H
