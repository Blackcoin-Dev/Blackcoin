// Copyright (c) 2026 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_WALLET_BLOCK_CONNECT_ACTIVITY_H
#define BITCOIN_WALLET_BLOCK_CONNECT_ACTIVITY_H

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
