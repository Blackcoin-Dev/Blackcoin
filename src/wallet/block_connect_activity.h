// Copyright (c) 2026 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_WALLET_BLOCK_CONNECT_ACTIVITY_H
#define BITCOIN_WALLET_BLOCK_CONNECT_ACTIVITY_H

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>

namespace wallet {

/**
 * Process-wide record of wallet block-connection activity, used only to let the
 * GUI balance poll yield to the validation scheduler (L15).
 *
 * Every wallet stamps the time at the start and end of its blockConnected /
 * blockDisconnected callback. The scheduler runs the wallets one after another,
 * so while a block is being dispatched the stamp stays fresh; the poll's
 * O(wallet outputs) scan, which holds cs_main, defers until the stamp is older
 * than QUIET_MS. To keep the displayed balance current during long catch-up, a
 * deferral never lasts more than MAX_DEFER_MS: after that one poll is let
 * through, then deferral starts again.
 *
 * All state is atomic and advisory. A wrong answer only delays or allows one
 * poll; it never affects wallet data.
 */
class BlockConnectActivity
{
public:
    static constexpr int64_t QUIET_MS{750};
    static constexpr int64_t MAX_DEFER_MS{5000};

    void Note(int64_t now_ms) { m_last_ms.store(now_ms, std::memory_order_relaxed); }

    /** True if a poll that would scan should wait. now_ms must be > 0. */
    bool ShouldDefer(int64_t now_ms)
    {
        const int64_t last = m_last_ms.load(std::memory_order_relaxed);
        if (last == 0 || now_ms - last >= QUIET_MS) {
            m_defer_since_ms.store(0, std::memory_order_relaxed);
            return false;
        }
        const int64_t since = m_defer_since_ms.load(std::memory_order_relaxed);
        if (since == 0) {
            m_defer_since_ms.store(now_ms, std::memory_order_relaxed);
            return true;
        }
        if (now_ms - since >= MAX_DEFER_MS) {
            m_defer_since_ms.store(0, std::memory_order_relaxed);
            return false;
        }
        return true;
    }

    static int64_t NowMs()
    {
        return std::chrono::duration_cast<std::chrono::milliseconds>(
                   std::chrono::steady_clock::now().time_since_epoch()).count() + 1;
    }

    static BlockConnectActivity& Global()
    {
        static BlockConnectActivity instance;
        return instance;
    }

private:
    std::atomic<int64_t> m_last_ms{0};
    std::atomic<int64_t> m_defer_since_ms{0};
};

/**
 * Process-wide single-flight and back-off for the GUI balance scan.
 *
 * The scan is O(wallet outputs) and holds cs_main. With many loaded wallets
 * every GUI poll thread would otherwise scan at once and starve the validation
 * and message-handler threads of cs_main. TryBegin() admits one scan at a time
 * and refuses a new one until as much time has passed since the previous scan
 * ended as that scan took (clamped to MIN_BACKOFF_MS..MAX_BACKOFF_MS), so GUI
 * scans hold cs_main at most about half of the time. A poll that returned
 * early without scanning records no back-off. Advisory and atomic: a wrong
 * answer only delays or admits one poll; it never affects wallet data.
 */
class GuiBalanceScanGate
{
public:
    static constexpr int64_t MIN_BACKOFF_MS{250};
    static constexpr int64_t MAX_BACKOFF_MS{10000};

    /** True if the caller may scan now; the caller must then call End(). */
    bool TryBegin(int64_t now_ms)
    {
        bool expected{false};
        if (!m_running.compare_exchange_strong(expected, true, std::memory_order_acquire)) return false;
        const int64_t last_duration = m_last_duration_ms.load(std::memory_order_relaxed);
        const int64_t last_end = m_last_end_ms.load(std::memory_order_relaxed);
        if (last_duration > 0 && last_end != 0) {
            const int64_t backoff = std::clamp(last_duration, MIN_BACKOFF_MS, MAX_BACKOFF_MS);
            if (now_ms - last_end < backoff) {
                m_running.store(false, std::memory_order_release);
                return false;
            }
        }
        m_start_ms.store(now_ms, std::memory_order_relaxed);
        return true;
    }

    /** Release after a TryBegin() that returned true. scanned=false (an early
     * return that did no scan) records a zero duration and so no back-off. */
    void End(int64_t now_ms, bool scanned = true)
    {
        const int64_t duration = scanned ? std::max<int64_t>(0, now_ms - m_start_ms.load(std::memory_order_relaxed)) : 0;
        m_last_duration_ms.store(duration, std::memory_order_relaxed);
        m_last_end_ms.store(now_ms, std::memory_order_relaxed);
        m_running.store(false, std::memory_order_release);
    }

    static GuiBalanceScanGate& Global()
    {
        static GuiBalanceScanGate instance;
        return instance;
    }

private:
    std::atomic<bool> m_running{false};
    std::atomic<int64_t> m_start_ms{0};
    std::atomic<int64_t> m_last_end_ms{0};
    std::atomic<int64_t> m_last_duration_ms{0};
};

/** Holds the GUI balance scan gate for the current scope. Call MarkScanned()
 * once the scan has really started; otherwise no back-off is imposed. */
class GuiBalanceScanGuard
{
public:
    explicit GuiBalanceScanGuard(GuiBalanceScanGate& gate = GuiBalanceScanGate::Global())
        : m_gate(gate), m_admitted(gate.TryBegin(BlockConnectActivity::NowMs())) {}
    ~GuiBalanceScanGuard()
    {
        if (m_admitted) m_gate.End(BlockConnectActivity::NowMs(), m_scanned);
    }
    GuiBalanceScanGuard(const GuiBalanceScanGuard&) = delete;
    GuiBalanceScanGuard& operator=(const GuiBalanceScanGuard&) = delete;
    bool Admitted() const { return m_admitted; }
    void MarkScanned() { m_scanned = true; }

private:
    GuiBalanceScanGate& m_gate;
    const bool m_admitted;
    bool m_scanned{false};
};

/** Stamps activity on construction and destruction. */
class BlockConnectActivityScope
{
public:
    BlockConnectActivityScope() { BlockConnectActivity::Global().Note(BlockConnectActivity::NowMs()); }
    ~BlockConnectActivityScope() { BlockConnectActivity::Global().Note(BlockConnectActivity::NowMs()); }
    BlockConnectActivityScope(const BlockConnectActivityScope&) = delete;
    BlockConnectActivityScope& operator=(const BlockConnectActivityScope&) = delete;
};

} // namespace wallet

#endif // BITCOIN_WALLET_BLOCK_CONNECT_ACTIVITY_H
