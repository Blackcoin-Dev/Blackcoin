// Copyright (c) 2026 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_WALLET_BLOCK_CONNECT_ACTIVITY_H
#define BITCOIN_WALLET_BLOCK_CONNECT_ACTIVITY_H

#include <tinyformat.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <mutex>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace wallet {

/**
 * Process-wide record of wallet block-connection activity, used only to let the
 * GUI balance poll yield to the validation scheduler (L15).
 *
 * Every wallet stamps the time at the start and end of its blockConnected /
 * blockDisconnected callback. The scheduler runs the wallets one after another,
 * so while a block is being dispatched the stamp stays fresh; the poll's
 * O(wallet outputs) scan, which needs cs_main for part of its work, defers until the stamp is older
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

/**
 * Fair, waiting admission to a limited number of slots, used by the GUI
 * balance scan (two instances: the cs_main phase, one slot with a back-off,
 * and the wallet-only phase, a few slots).
 *
 * The scan is O(wallet outputs). With many loaded wallets every GUI poll
 * thread would otherwise scan at once. A caller waits for a slot holding no
 * locks, for at most a bounded time; whichever caller is the best of those
 * waiting is admitted when a slot is free:
 *   1. a wallet that has never published a balance (last_publish_ms == 0),
 *   2. then the wallet whose last successful publish is the oldest,
 *   3. ties in arrival order.
 * A bare try (the old behaviour) let whichever timer fired first win, so one
 * wallet could get hundreds of turns while another got none.
 *
 * With the back-off enabled (single-slot queue guarding cs_main), a holder
 * that held cs_main for at least BACKOFF_THRESHOLD_MS (the caller reports the
 * time it really held it) delays the next admission until as much time has
 * passed since the release as the hold took (at most MAX_BACKOFF_MS), so the
 * scans hold cs_main at most about half of the time. A cheap hold imposes no
 * back-off, and neither does a holder that reports no hold.
 *
 * The clock is injectable so that tests need no real time except where a wait
 * is itself under test. Advisory only: it never touches wallet data.
 */
class GuiBalanceScanQueue
{
public:
    static constexpr int64_t BACKOFF_THRESHOLD_MS{250};
    static constexpr int64_t MAX_BACKOFF_MS{10000};
    /** Longest a caller waits (holding no locks) for admission. */
    static constexpr int64_t MAX_WAIT_MS{3000};
    /** Wallets that run the wallet-only phase (phase A) at the same time. */
    static constexpr int MAX_PHASE_A_WALLETS{3};
    /** A waiting caller looks at its give-up condition at least this often. */
    static constexpr int64_t POLL_MS{25};

    using Clock = std::function<int64_t()>;

    explicit GuiBalanceScanQueue(int slots, bool backoff, Clock clock = &BlockConnectActivity::NowMs)
        : m_slots(std::max(1, slots)), m_backoff(backoff), m_clock(std::move(clock)) {}

    /** The process-wide queue for the part of the scan that holds cs_main. */
    static GuiBalanceScanQueue& MainPhase()
    {
        static GuiBalanceScanQueue instance{1, /*backoff=*/true};
        return instance;
    }
    /** The process-wide queue for the part of the scan that reads the wallet only. */
    static GuiBalanceScanQueue& WalletPhase()
    {
        static GuiBalanceScanQueue instance{MAX_PHASE_A_WALLETS, /*backoff=*/false};
        return instance;
    }

    /** Wait up to max_wait_ms for a slot. last_publish_ms is when the caller's
     * wallet last published a balance, 0 if never. give_up is polled while
     * waiting (without the queue's lock held); when it returns true the wait
     * ends not admitted. A true result must be followed by Release(). If
     * waited_ms is set it receives the time spent in this call. */
    bool Acquire(int64_t last_publish_ms, int64_t max_wait_ms,
                 const std::function<bool()>& give_up = {}, int64_t* waited_ms = nullptr)
    {
        std::unique_lock<std::mutex> lock(m_mutex);
        const int64_t start = m_clock();
        const uint64_t seq = ++m_next_seq;
        m_waiters.push_back(Waiter{seq, last_publish_ms != 0, last_publish_ms});
        bool admitted{false};
        for (;;) {
            const int64_t now = m_clock();
            if (CanAdmit(seq, now)) {
                admitted = true;
                break;
            }
            const int64_t waited = now - start;
            if (waited >= max_wait_ms) break;
            if (give_up) {
                lock.unlock();
                const bool stop = give_up();
                lock.lock();
                if (stop) break;
            }
            int64_t sleep_ms = std::min(POLL_MS, max_wait_ms - waited);
            if (m_backoff && m_running == 0 && m_backoff_until_ms > now) {
                sleep_ms = std::min(sleep_ms, m_backoff_until_ms - now);
            }
            m_cv.wait_for(lock, std::chrono::milliseconds(std::max<int64_t>(1, sleep_ms)));
        }
        const int64_t end = m_clock();
        RemoveWaiter(seq);
        if (admitted) {
            ++m_running;
            m_admit_ms = end;
        }
        if (waited_ms) *waited_ms = std::max<int64_t>(0, end - start);
        // Whoever is next in line may be admissible now (a free slot is left,
        // or the best waiter gave up).
        m_cv.notify_all();
        return admitted;
    }

    /** Give a slot back. held_ms is the time the holder really held what the
     * queue guards (cs_main); only that decides the back-off. */
    void Release(int64_t held_ms = 0)
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        if (m_running > 0) --m_running;
        if (m_backoff) {
            m_backoff_until_ms = held_ms >= BACKOFF_THRESHOLD_MS
                ? m_clock() + std::min(held_ms, MAX_BACKOFF_MS) : 0;
        }
        m_cv.notify_all();
    }

    int Running() const { std::lock_guard<std::mutex> lock(m_mutex); return m_running; }
    size_t Waiting() const { std::lock_guard<std::mutex> lock(m_mutex); return m_waiters.size(); }

private:
    struct Waiter {
        uint64_t seq;
        bool published;
        int64_t last_publish_ms;
    };
    static bool Better(const Waiter& a, const Waiter& b)
    {
        if (a.published != b.published) return !a.published;
        if (a.published && a.last_publish_ms != b.last_publish_ms) return a.last_publish_ms < b.last_publish_ms;
        return a.seq < b.seq;
    }
    bool CanAdmit(uint64_t seq, int64_t now) const
    {
        if (m_running >= m_slots) return false;
        if (m_backoff && now < m_backoff_until_ms) return false;
        const Waiter* best{nullptr};
        for (const Waiter& w : m_waiters) {
            if (!best || Better(w, *best)) best = &w;
        }
        return best && best->seq == seq;
    }
    void RemoveWaiter(uint64_t seq)
    {
        m_waiters.erase(std::remove_if(m_waiters.begin(), m_waiters.end(),
                                       [&](const Waiter& w) { return w.seq == seq; }),
                        m_waiters.end());
    }

    const int m_slots;
    const bool m_backoff;
    const Clock m_clock;
    mutable std::mutex m_mutex;
    std::condition_variable m_cv;
    std::vector<Waiter> m_waiters;
    uint64_t m_next_seq{0};
    int m_running{0};
    int64_t m_admit_ms{0};
    int64_t m_backoff_until_ms{0};
};

/** Holds a slot of a GuiBalanceScanQueue for the current scope; released on
 * every exit path. AddMainHold() records each stretch spent holding cs_main
 * (the back-off of the next admission follows the sum); without one no
 * back-off is imposed. */
class GuiBalanceScanSlot
{
public:
    GuiBalanceScanSlot(GuiBalanceScanQueue& queue, int64_t last_publish_ms, int64_t max_wait_ms,
                       const std::function<bool()>& give_up = {})
        : m_queue(queue), m_admitted(queue.Acquire(last_publish_ms, max_wait_ms, give_up, &m_waited_ms)) {}
    ~GuiBalanceScanSlot() { Release(); }
    GuiBalanceScanSlot(const GuiBalanceScanSlot&) = delete;
    GuiBalanceScanSlot& operator=(const GuiBalanceScanSlot&) = delete;
    bool Admitted() const { return m_admitted; }
    int64_t WaitedMs() const { return m_waited_ms; }
    void AddMainHold(int64_t held_ms) { m_held_ms += std::max<int64_t>(0, held_ms); }
    /** Give the slot back before the end of the scope (idempotent). */
    void Release()
    {
        if (!m_admitted || m_released) return;
        m_released = true;
        m_queue.Release(m_held_ms);
    }

private:
    GuiBalanceScanQueue& m_queue;
    int64_t m_waited_ms{0};
    const bool m_admitted;
    bool m_released{false};
    int64_t m_held_ms{0};
};

/**
 * Per-wallet record of why the GUI balance scan did not produce a balance, so
 * that the log can say why a wallet never got one. Counts each kind of
 * unsuccessful attempt; while the wallet has never published a balance, a
 * summary line is due at most every SUMMARY_INTERVAL_MS (the reason counters
 * restart after each one); the first published balance is reported once.
 * Thread safe; times are passed in.
 */
class GuiBalanceScanDiagnostics
{
public:
    static constexpr int64_t SUMMARY_INTERVAL_MS{60000};
    enum class Reason {
        DEFERRED,      //!< yielded to a block being dispatched, before doing anything
        SLOT_TIMEOUT,  //!< no wallet-phase slot within the bounded wait
        MAIN_BUSY,     //!< cs_main busy (TRY_LOCK failed)
        WALLET_BUSY,   //!< cs_wallet busy (TRY_LOCK failed)
        NOT_SYNCED,    //!< the wallet is not at the chain tip yet
        YIELDED,       //!< gave way to a block being dispatched while waiting or scanning
        TIP_MOVED,     //!< the chain tip moved while the scan was running
        WALLET_MOVED,  //!< the wallet changed while the scan was running
        GATE_TIMEOUT,  //!< no cs_main-phase slot within the bounded wait
        BUDGET,        //!< the chainstate part ran out of its budget
        SHUTDOWN,      //!< shutdown requested while waiting
        OTHER,         //!< anything else
        COUNT
    };
    static const char* Name(Reason reason)
    {
        static constexpr const char* names[] = {"deferred", "slot_timeout", "main_busy", "wallet_busy",
            "not_synced", "yielded", "tip_moved", "wallet_moved", "gate_timeout", "budget", "shutdown", "other"};
        return names[static_cast<size_t>(reason)];
    }

    explicit GuiBalanceScanDiagnostics(int64_t load_ms) : m_load_ms(load_ms), m_last_summary_ms(load_ms) {}

    void Attempt()
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        ++m_attempts;
        ++m_total_attempts;
    }
    void Count(Reason reason)
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        ++m_counts[static_cast<size_t>(reason)];
    }
    uint64_t Counted(Reason reason) const
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        return m_counts[static_cast<size_t>(reason)];
    }
    bool HasPublished() const
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        return m_published;
    }

    /** A balance was published. Returns the line to log the first time. */
    std::optional<std::string> OnPublished(int64_t now_ms, const std::string& wallet)
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        if (m_published) return std::nullopt;
        m_published = true;
        return strprintf("GUI balance scan: wallet=%s first balance ready after %d ms (attempts=%d)",
                         wallet, now_ms - m_load_ms, m_total_attempts);
    }

    /** The line to log now, if the wallet has never published a balance and
     * the last summary is at least SUMMARY_INTERVAL_MS old; resets the
     * counters. memo_size < 0 prints as unknown. */
    std::optional<std::string> TakeWaitingSummary(int64_t now_ms, const std::string& wallet, int64_t memo_size)
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        if (m_published || now_ms - m_last_summary_ms < SUMMARY_INTERVAL_MS) return std::nullopt;
        std::string line = strprintf("GUI balance scan waiting: wallet=%s since_load_s=%d attempts=%d",
                                     wallet, (now_ms - m_load_ms) / 1000, m_attempts);
        for (size_t i = 0; i < static_cast<size_t>(Reason::COUNT); ++i) {
            if (m_counts[i] == 0) continue;
            line += strprintf(" %s=%d", Name(static_cast<Reason>(i)), m_counts[i]);
        }
        line += memo_size >= 0 ? strprintf(" memo_size=%d", memo_size) : std::string{" memo_size=unknown"};
        m_counts.fill(0);
        m_attempts = 0;
        m_last_summary_ms = now_ms;
        return line;
    }

private:
    mutable std::mutex m_mutex;
    const int64_t m_load_ms;
    int64_t m_last_summary_ms;
    bool m_published{false};
    uint64_t m_attempts{0};
    uint64_t m_total_attempts{0};
    std::array<uint64_t, static_cast<size_t>(Reason::COUNT)> m_counts{};
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
