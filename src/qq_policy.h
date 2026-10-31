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
