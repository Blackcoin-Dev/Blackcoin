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
 * Process-wide record of wallet block-connection activity.
 *
 * Every wallet stamps the time at the start and end of its blockConnected /
 * blockDisconnected callback. Since rc12 the GUI balance display no longer
 * reads this: the display balance worker (wallet/display_balance.h) asks the
 * validation interface itself whether it has callbacks queued or executing
 * (interfaces::Chain::validationCallbacksBusy), which also covers mempool
 * callbacks and a callback that is blocked on a wallet lock. The stamps are
 * kept as a cheap diagnostic of block dispatch; ShouldDefer() and
 * IsDispatching() have no caller in the display path.
 *
 * All state is atomic and advisory.
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

    /** True while a block dispatch has been seen within QUIET_MS. Unlike
     * ShouldDefer() it changes no state, so a scan that was let through the
     * deferral cap can ask it again without opening a new deferral window. */
    bool IsDispatching(int64_t now_ms) const
    {
        const int64_t last = m_last_ms.load(std::memory_order_relaxed);
        return last != 0 && now_ms - last < QUIET_MS;
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
