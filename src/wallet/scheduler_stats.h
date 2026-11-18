// Copyright (c) 2026 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_WALLET_SCHEDULER_STATS_H
#define BITCOIN_WALLET_SCHEDULER_STATS_H

#include <array>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>

namespace wallet {

/**
 * Process-wide measurement of how long the wallet validation-interface
 * handlers wait for cs_wallet and how long they hold it. Every loaded wallet
 * runs these handlers one after another on the single validation scheduler
 * thread, so a long wait or hold in one wallet delays all the others. The
 * counters are advisory and lock-free; they never affect wallet data.
 */
enum class WalletCallbackKind : size_t {
    BLOCK_CONNECTED,
    MEMPOOL_ADDED,
    MEMPOOL_REMOVED,
    BLOCK_DISCONNECTED,
};
constexpr size_t WALLET_CALLBACK_KINDS{4};

/** Buckets: under 10 ms, 10 to 100 ms, 100 ms to 1 s, 1 to 10 s, over 10 s. */
constexpr size_t LATENCY_BUCKETS{5};
size_t LatencyBucket(std::chrono::microseconds duration);

struct CallbackLatencySnapshot {
    uint64_t count{0};
    uint64_t wait_total_us{0};
    uint64_t wait_max_us{0};
    uint64_t hold_total_us{0};
    uint64_t hold_max_us{0};
    std::array<uint64_t, LATENCY_BUCKETS> wait_histogram{};
    std::array<uint64_t, LATENCY_BUCKETS> hold_histogram{};
};

class SchedulerStats
{
public:
    static SchedulerStats& Instance();

    void Record(WalletCallbackKind kind, std::chrono::microseconds wait, std::chrono::microseconds hold);
    CallbackLatencySnapshot Snapshot(WalletCallbackKind kind) const;
    /** Forget every counter (unit tests). */
    void Reset();
    /** One log line with every handler's counters and the validation queue depth. */
    std::string FormatSummary() const;
    /**
     * Log the summary line and the process memory line unless one was logged
     * in the last interval. Safe to call from any thread and as often as
     * wanted: at most one caller per interval writes.
     */
    void MaybeLogSummary(std::chrono::steady_clock::time_point now = std::chrono::steady_clock::now());

    static constexpr std::chrono::seconds SUMMARY_INTERVAL{60};

private:
    struct Counters {
        std::atomic<uint64_t> count{0};
        std::atomic<uint64_t> wait_total_us{0};
        std::atomic<uint64_t> wait_max_us{0};
        std::atomic<uint64_t> hold_total_us{0};
        std::atomic<uint64_t> hold_max_us{0};
        std::array<std::atomic<uint64_t>, LATENCY_BUCKETS> wait_histogram{};
        std::array<std::atomic<uint64_t>, LATENCY_BUCKETS> hold_histogram{};
    };
    std::array<Counters, WALLET_CALLBACK_KINDS> m_counters;
    // steady_clock nanoseconds since epoch of the last summary, 0 when none yet.
    std::atomic<int64_t> m_last_summary_ns{0};
};

/**
 * SQLite commit measurement, to decide later whether WAL mode would help.
 * DURABLE and NON_DURABLE are explicit transactions ended by COMMIT (by the
 * flag given to TxnBegin), BULK_SCOPE is a grouped-writes scope's COMMIT, and
 * AUTOCOMMIT is a single write outside any transaction, where SQLite commits
 * implicitly (the timed span then includes the write itself). The nested
 * savepoint release of a unit inside a transaction is not a commit and is not
 * counted. Counters are lock-free and never affect wallet data.
 */
enum class SqliteCommitKind : size_t {
    DURABLE,
    NON_DURABLE,
    BULK_SCOPE,
    AUTOCOMMIT,
};
constexpr size_t SQLITE_COMMIT_KINDS{4};

struct SqliteCommitCounts {
    uint64_t count{0};
    uint64_t total_us{0};
    uint64_t max_us{0};
};
using SqliteCommitSnapshot = std::array<SqliteCommitCounts, SQLITE_COMMIT_KINDS>;

class SqliteCommitCounters
{
public:
    void Record(SqliteCommitKind kind, std::chrono::microseconds duration);
    SqliteCommitSnapshot Snapshot() const;
    /** Read and zero, so the next call reports only what happened since. */
    SqliteCommitSnapshot Take();
    void Reset();

private:
    struct Counters {
        std::atomic<uint64_t> count{0};
        std::atomic<uint64_t> total_us{0};
        std::atomic<uint64_t> max_us{0};
    };
    std::array<Counters, SQLITE_COMMIT_KINDS> m_counters;
};

/** Every SQLite wallet database of the process adds here as well as to its own counters. */
SqliteCommitCounters& ProcessSqliteCommits();
/** " | sqlite commits since last line: durable n=.. total=..ms max=..ms ..." (kinds with no commits are omitted). */
std::string FormatSqliteCommits(const SqliteCommitSnapshot& snapshot);

/**
 * Brackets one handler's use of cs_wallet. Declare it before the LOCK, call
 * LockAcquired() right after the LOCK, and let it go out of scope after the
 * lock is released:
 *
 *     WalletCallbackTimer timer{WalletCallbackKind::BLOCK_CONNECTED};
 *     LOCK(cs_wallet);
 *     timer.LockAcquired();
 *
 * A handler called from inside another handler on the same thread (the block
 * handler calls the mempool-removal handler for each block transaction) is
 * not counted a second time.
 */
class WalletCallbackTimer
{
public:
    explicit WalletCallbackTimer(WalletCallbackKind kind);
    ~WalletCallbackTimer();
    WalletCallbackTimer(const WalletCallbackTimer&) = delete;
    WalletCallbackTimer& operator=(const WalletCallbackTimer&) = delete;
    void LockAcquired();

private:
    const WalletCallbackKind m_kind;
    const bool m_counted;
    const std::chrono::steady_clock::time_point m_start;
    std::chrono::steady_clock::time_point m_acquired;
    bool m_have_acquired{false};
};

/**
 * True on a thread that is inside a wallet validation-interface handler (a
 * WalletCallbackTimer is alive). The handler holds cs_wallet for most of that
 * span, so a wallet database commit made now is a commit under cs_wallet.
 */
bool InWalletCallback();

/** Where the number of queued validation callbacks comes from; unset in tools that have no scheduler. */
void SetValidationQueueDepthProvider(std::function<size_t()> provider);
std::optional<size_t> GetValidationQueueDepth();

struct ProcessMemory {
    uint64_t resident_bytes{0};
    //! macOS only: phys_footprint, the figure Activity Monitor reports.
    std::optional<uint64_t> footprint_bytes;
    //! macOS only: bytes of this process held by the memory compressor.
    std::optional<uint64_t> compressed_bytes;
};
/** Memory use of this process; nullopt on a platform without a supported query. */
std::optional<ProcessMemory> GetProcessMemory();
std::string FormatProcessMemory(const ProcessMemory& memory);

} // namespace wallet

#endif // BITCOIN_WALLET_SCHEDULER_STATS_H
