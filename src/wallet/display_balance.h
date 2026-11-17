// Copyright (c) 2026 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_WALLET_DISPLAY_BALANCE_H
#define BITCOIN_WALLET_DISPLAY_BALANCE_H

#include <consensus/amount.h>
#include <uint256.h>
#include <wallet/receive.h>
#include <wallet/spend.h>

#include <boost/signals2/signal.hpp>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <exception>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

namespace wallet {
class CWallet;

/**
 * The balance display of the GUI.
 *
 * What the GUI shows is a published snapshot: an immutable object behind a
 * leaf mutex. Reading it takes neither cs_main nor cs_wallet. One worker
 * thread for the whole process computes the snapshots of all wallets, slice
 * by slice (wallet/spend.h, "The sliced display balance engine"), so at most
 * one wallet lock is ever held for display purposes, for a bounded time, and
 * never while the validation interface has work.
 */

/** One published display balance. Immutable. */
struct DisplayBalanceSnapshot {
    //! The block the balance was computed for: the active tip and the last
    //! block the wallet had processed, at the same time.
    uint256 tip_hash;
    int tip_height{-1};
    //! CWallet::GetBalanceScanMarker() of the wallet state it was computed
    //! from. The snapshot is exact for as long as the wallet's marker has
    //! this value.
    uint64_t marker{0};
    Balance balance;
    WalletLifecycleSummary lifecycle;
    bool have_watch_only{false};
    //! The send-family balance that was asked for, when it could be computed
    //! within its bound (true = direct quantum, false = legacy).
    std::optional<bool> send_family_quantum;
    std::optional<CAmount> send_family_balance;
    //! Grows with every publish of this wallet.
    uint64_t sequence{0};
    int64_t published_ms{0};
};

/**
 * When the worker may start a slice (I4). It does not start one while the
 * validation interface has a callback queued or executing. So that a node
 * that is busy without pause still gets a balance, deference is bounded:
 * after MAX_DEFER_MS of uninterrupted busyness one slice is let through
 * every FORCED_INTERVAL_MS until a quiet moment is seen.
 *
 * Pure state machine; the time is passed in.
 */
class DisplayBusyGate
{
public:
    static constexpr int64_t MAX_DEFER_MS{5000};
    static constexpr int64_t FORCED_INTERVAL_MS{250};

    /** May a slice start now? now_ms must be > 0. */
    bool MayRun(int64_t now_ms, bool busy)
    {
        if (!busy) {
            m_busy_since_ms = 0;
            m_last_forced_ms = 0;
            return true;
        }
        if (m_busy_since_ms == 0) {
            m_busy_since_ms = now_ms;
            return false;
        }
        if (now_ms - m_busy_since_ms < MAX_DEFER_MS) return false;
        if (m_last_forced_ms == 0 || now_ms - m_last_forced_ms >= FORCED_INTERVAL_MS) {
            m_last_forced_ms = now_ms;
            return true;
        }
        return false;
    }
    /** True while slices are being let through a busy validation interface. */
    bool Forced() const { return m_last_forced_ms != 0; }

private:
    int64_t m_busy_since_ms{0};
    int64_t m_last_forced_ms{0};
};

/** What the worker knows about one wallet when it chooses the next one. */
struct DisplayCandidate {
    bool needs_work{false};
    bool never_published{false};
    //! The wallet that is shown, or one a caller is waiting for.
    bool foreground{false};
    int64_t last_publish_ms{0};
    int64_t last_served_ms{0};
    //! Since when the wallet has needed work (0 = unknown).
    int64_t need_since_ms{0};
};

/** A shown wallet that has waited this long goes first once, so that a long
 * queue of wallets that never published cannot starve the one on screen. */
static constexpr int64_t DISPLAY_FOREGROUND_MAX_WAIT_MS{5000};

/**
 * The wallet to serve next, or -1 when none needs work (I3):
 *   1. wallets that have never published a balance,
 *   2. then the wallet that is shown,
 *   3. then the wallet with the oldest snapshot.
 * Within a class the wallet served longest ago goes first; among those that
 * never published, the one that is shown goes before the others. A shown
 * wallet that has waited DISPLAY_FOREGROUND_MAX_WAIT_MS goes before class 1.
 */
int PickDisplayWallet(const std::vector<DisplayCandidate>& candidates, int64_t now_ms);

/** Counters between two log lines of a wallet. */
struct DisplayBalanceCounters {
    uint64_t slices{0};
    int64_t max_wallet_us{0};
    int64_t max_main_us{0};
    uint64_t restarts_tip{0};
    uint64_t restarts_marker{0};
    uint64_t busy_deferrals{0};
    uint64_t lock_busy{0};
    uint64_t not_synced{0};
    uint64_t passes{0};
    uint64_t failures{0};
};

/** Result of a synchronous request. */
struct DisplayBalanceOutcome {
    bool ok{false};
    std::shared_ptr<const DisplayBalanceSnapshot> snapshot;
    std::exception_ptr exception;
};

/**
 * Display balance state of one wallet. Created and owned through
 * DisplayBalanceWorker; the worker thread is the only one that runs RunJob().
 */
class WalletDisplayBalance
{
public:
    //! A wallet that is not shown is recomputed at most this often.
    static constexpr int64_t BACKGROUND_MIN_INTERVAL_MS{60000};
    //! Log line interval without and with an exact snapshot.
    static constexpr int64_t SUMMARY_INTERVAL_STALE_MS{60000};
    static constexpr int64_t SUMMARY_INTERVAL_EXACT_MS{600000};
    //! A pass that meets more deep outputs without a memo entry than this
    //! hands over to the memo warm-up.
    static constexpr uint64_t WARMUP_THRESHOLD{1024};
    //! Bound of the on-demand send-family balance (both locks, shown wallet
    //! only, once per snapshot).
    static constexpr std::chrono::milliseconds SEND_FAMILY_BUDGET{250};
    //! This many memo disagreements within MISMATCH_WINDOW_BLOCKS clear the memo.
    static constexpr size_t MISMATCH_CLEAR_COUNT{3};
    static constexpr int MISMATCH_WINDOW_BLOCKS{1000};

    explicit WalletDisplayBalance(CWallet& wallet);

    /** The published snapshot, or null. Takes only the leaf mutex. */
    std::shared_ptr<const DisplayBalanceSnapshot> Snapshot() const;
    /** Whether the wallet has not changed since the snapshot (lock free). */
    bool IsCurrent(const DisplayBalanceSnapshot& snapshot) const;
    /** Whether the last attempt ended in an error (not a routine retry). */
    bool Failed() const;

    /** What the GUI wants: whether this wallet is the one shown, and which
     * send-family balance, if any. `retry_send` asks again for a send-family
     * balance that could not be computed for the current snapshot. Returns
     * true when the worker should be woken. */
    bool SetInterest(bool foreground, std::optional<bool> send_family_quantum, bool retry_send);

    /** Ask for a pass that starts after this call and wait for its outcome.
     * `wake` wakes the worker. */
    DisplayBalanceOutcome RequestAndWait(std::optional<bool> send_family_quantum,
                                         std::chrono::milliseconds timeout,
                                         const std::function<void()>& wake);

    /** Called after every publish and after a change of the failed state, on
     * the worker thread, with no lock held. */
    boost::signals2::signal<void()> NotifyChanged;

    // Worker thread only.
    DisplayCandidate Candidate(int64_t now_ms);
    /** Run slices of this wallet up to the next boundary: a finished or
     * restarted pass, one warm-up batch, or a back-off. `turn` is called
     * before every slice and returns false when the job must stop. */
    void RunJob(const std::function<bool()>& turn);
    void NoteDeferral();
    /** The periodic log line, when one is due. */
    void MaybeLogSummary(int64_t now_ms);
    bool ValidationBusy() const;
    bool ShutdownRequested() const;

    static int64_t NowMs();

    //! Test only: limits of every slice (deterministic slicing).
    void SetSliceLimitsForTest(const LifecycleSliceLimits& limits)
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_next_limits = limits;
    }

private:
    enum class End { OK, FAILED };
    void FinishOutcome(End end, std::exception_ptr exception);
    void Publish(std::shared_ptr<DisplayBalanceSnapshot> snapshot);
    void BackOff(int64_t first_ms, int64_t max_ms);
    void ClearBackOff();
    void Account(const LifecycleSliceReport& report);
    void SetFailed(bool failed);
    std::optional<bool> WantedSendFamily() const;
    bool SendFamilyDue(const DisplayBalanceSnapshot& snapshot, int64_t now_ms) const;
    void RunJobInner(const std::function<bool()>& turn);
    void RunWarmup(const std::function<bool()>& turn);
    void RunPass(const std::function<bool()>& turn);
    /** Fill the send-family balance of `snapshot` when one is wanted and due.
     * Returns false when nothing could be attempted (a lock was busy or the
     * wallet is no longer at the snapshot). */
    bool RunSendFamily(DisplayBalanceSnapshot& snapshot);
    void RunSendFamilyOnly();
    void NoteMismatches();

    CWallet& m_wallet;
    const int64_t m_load_ms;

    // Leaf mutex: nothing else is locked while it is held. It guards every
    // member up to the "worker thread only" block.
    mutable std::mutex m_mutex;
    std::condition_variable m_cv;
    std::shared_ptr<const DisplayBalanceSnapshot> m_snapshot;
    uint64_t m_sequence{0};
    bool m_foreground{false};
    std::optional<bool> m_send_family;
    //! (tip, marker, family) of the last send-family attempt.
    std::optional<std::tuple<uint256, uint64_t, bool>> m_send_attempted;
    bool m_failed{false};
    //! The wallet change marker when the last error was recorded.
    uint64_t m_failed_marker{0};
    //! Compute the send-family balance again even though the snapshot has one.
    bool m_send_force{false};
    int64_t m_not_before_ms{0};
    int64_t m_backoff_ms{0};
    int64_t m_need_since_ms{0};
    // Synchronous requests: tickets handed out, the ticket the pass in
    // progress serves, and the last ticket that has an outcome.
    uint64_t m_ticket_requested{0};
    uint64_t m_ticket_serving{0};
    uint64_t m_ticket_done{0};
    std::optional<bool> m_ticket_send_family;
    bool m_outcome_ok{false};
    std::exception_ptr m_outcome_exception;
    DisplayBalanceCounters m_counters;
    uint64_t m_total_slices{0};
    bool m_first_exact_logged{false};
    int64_t m_last_summary_ms;
    int64_t m_send_not_before_ms{0};
    int m_last_seen_tip_height{-1};
    //! For the log line: what the warm-up has left (-1 = not running).
    int64_t m_warmup_waiting{-1};
    int m_warmup_walked_percent{100};

    LifecycleSliceLimits m_next_limits; // taken over at the start of a job

    // Worker thread only.
    LifecycleSliceLimits m_limits;
    LifecyclePass m_pass;
    LifecycleMemoJournal m_journal;
    LifecycleAttestationCache m_attestations;
    std::optional<LifecycleWarmup> m_warmup;
    std::atomic<bool> m_warmup_armed{false};
    bool m_warmup_was_useless{false};
    uint64_t m_journal_mismatches_seen{0};
    std::deque<int> m_mismatch_heights;
    int64_t m_pass_start_ms{0};
    int64_t m_pass_wallet_us{0};
    int64_t m_pass_main_us{0};
    int m_consecutive_busy{0};
    int m_tip_height_seen{-1};
    uint64_t m_warmup_stored_base{0};
};

/**
 * The process-wide display balance worker (I3): one thread, started with the
 * first wallet that asks for a display balance and joined when the last one
 * is released.
 */
class DisplayBalanceWorker
{
public:
    static DisplayBalanceWorker& Global();
    ~DisplayBalanceWorker();

    /** The display state of a wallet; created on first use. Every Acquire()
     * is matched by one Release(). The wallet must outlive that Release(). */
    std::shared_ptr<WalletDisplayBalance> Acquire(CWallet& wallet);
    /** Give up one reference. With the last one the wallet is taken off the
     * worker: this returns only once no slice of it is running, after which
     * the worker never touches the wallet again. */
    void Release(CWallet& wallet);
    void Wake();

    /** Number of wallets served, for tests. */
    size_t WalletCount();

private:
    struct Entry {
        std::shared_ptr<WalletDisplayBalance> state;
        int refs{0};
        bool running{false};
        bool removing{false};
        int64_t last_served_ms{0};
    };
    void Run();
    bool WaitTurn(Entry& entry);
    //! Pause between two slices.
    static constexpr std::chrono::milliseconds SLICE_GAP{1};

    std::mutex m_lifecycle_mutex; // serializes Acquire and Release
    std::mutex m_mutex;
    std::condition_variable m_cv;
    std::map<CWallet*, Entry> m_entries; // guarded by m_mutex
    bool m_stop{false};                  // guarded by m_mutex
    bool m_wake{false};                  // guarded by m_mutex
    std::thread m_thread;                // guarded by m_lifecycle_mutex
    DisplayBusyGate m_gate;              // worker thread only
    bool m_deferring{false};             // worker thread only
};

} // namespace wallet

#endif // BITCOIN_WALLET_DISPLAY_BALANCE_H
