// Copyright (c) 2026 Blackcoin Core Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_UTIL_IO_COUNTERS_H
#define BITCOIN_UTIL_IO_COUNTERS_H

#include <span.h>

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

/**
 * Process-wide counters of the disk reads and syncs that make a node slow on a
 * spinning disk. A test reads them as deltas; nothing in the node consults
 * them, so a count never changes what the node does. Every counter is a relaxed
 * atomic, cheap enough to stay on in release builds.
 *
 * Two test-only facilities share one predictable branch on the read path: an
 * injected delay per chainstate database read and per wallet database commit
 * (to reproduce a slow disk on a fast one), and a recorder of the keys read
 * (to check that reads come in key order). Both are off unless a test turns
 * them on, and the options that set them are refused outside regtest.
 */
namespace iocounters {

struct Snapshot {
    //! CCoinsViewDB::GetCoin and HaveCoin calls (the chainstate point lookups).
    uint64_t chainstate_get_coin{0};
    uint64_t chainstate_have_coin{0};
    //! CDBWrapper reads and existence checks of any LevelDB (chainstate, block index, indexes).
    uint64_t db_reads{0};
    uint64_t db_exists{0};
    //! Wallet SQLite commits (explicit COMMIT and implicit single-statement commits).
    uint64_t wallet_commits{0};
    /**
     * Of those, commits made on a thread inside a wallet validation-interface
     * handler (block connected or disconnected, transaction added to or removed
     * from the mempool), where the handler holds cs_wallet. A commit made under
     * cs_wallet by another path (an RPC, the GUI) is counted only in
     * wallet_commits: the SQLite layer cannot tell, without a lock-order build,
     * whether the caller holds cs_wallet.
     */
    uint64_t wallet_commits_in_handler{0};
    //! Of the wallet commits, single statements outside any transaction that SQLite committed by itself.
    uint64_t wallet_autocommits{0};
};

// Hot-path state. Only the functions below touch it.
inline std::atomic<uint64_t> g_chainstate_get_coin{0};
inline std::atomic<uint64_t> g_chainstate_have_coin{0};
inline std::atomic<uint64_t> g_db_reads{0};
inline std::atomic<uint64_t> g_db_exists{0};
inline std::atomic<uint64_t> g_wallet_commits{0};
inline std::atomic<uint64_t> g_wallet_commits_in_handler{0};
inline std::atomic<uint64_t> g_wallet_autocommits{0};
//! Nonzero while a delay is set or the recorder is on: the only branch of the read path.
inline std::atomic<bool> g_read_hook{false};
inline std::atomic<bool> g_commit_hook{false};

//! The slow path of a read: sleeps the injected delay and records the key.
void ReadHook(Span<const std::byte> key);
//! The slow path of a commit: sleeps the injected delay.
void CommitHook();

inline void OnGetCoin() { g_chainstate_get_coin.fetch_add(1, std::memory_order_relaxed); }
inline void OnHaveCoin() { g_chainstate_have_coin.fetch_add(1, std::memory_order_relaxed); }
inline void OnDbRead(Span<const std::byte> key)
{
    g_db_reads.fetch_add(1, std::memory_order_relaxed);
    if (g_read_hook.load(std::memory_order_relaxed)) ReadHook(key);
}
inline void OnDbExists(Span<const std::byte> key)
{
    g_db_exists.fetch_add(1, std::memory_order_relaxed);
    if (g_read_hook.load(std::memory_order_relaxed)) ReadHook(key);
}
inline void OnWalletCommit(bool in_wallet_handler, bool autocommit = false)
{
    if (autocommit) g_wallet_autocommits.fetch_add(1, std::memory_order_relaxed);
    g_wallet_commits.fetch_add(1, std::memory_order_relaxed);
    if (in_wallet_handler) g_wallet_commits_in_handler.fetch_add(1, std::memory_order_relaxed);
    if (g_commit_hook.load(std::memory_order_relaxed)) CommitHook();
}

Snapshot Read();

/** Microseconds to sleep per chainstate database read (0 turns it off). */
void SetDbReadDelayUs(int64_t us);
/** Microseconds to sleep per wallet database commit (0 turns it off). */
void SetWalletCommitDelayUs(int64_t us);
int64_t GetDbReadDelayUs();
int64_t GetWalletCommitDelayUs();

/** Record the key of every database read (at most MAX_RECORDED_KEYS; later reads are counted and dropped). */
void SetKeyRecorder(bool on);
//! Forget what was recorded.
void ClearRecordedKeys();
//! Number of keys recorded so far (not counting dropped ones).
size_t RecordedKeyCount();
//! Keys recorded at positions [first, end), as raw LevelDB keys.
std::vector<std::string> RecordedKeys(size_t first = 0);
static constexpr size_t MAX_RECORDED_KEYS{4'000'000};

/**
 * Of the recorded keys at positions >= first that start with `prefix`, the
 * number and the count of adjacent pairs that are out of order (a key lower
 * than the one before it). Zero inversions means the reads were sorted.
 */
struct KeyOrderReport {
    size_t keys{0};
    size_t inversions{0};
};
KeyOrderReport RecordedKeyOrder(unsigned char prefix, size_t first = 0);
//! The same over keys given directly.
KeyOrderReport KeyOrder(const std::vector<std::string>& keys, unsigned char prefix);

/**
 * Check a test delay option. A delay is allowed only on regtest and must be
 * between 0 and MAX_TEST_DELAY_US. Returns an error message, or nullopt.
 */
static constexpr int64_t MAX_TEST_DELAY_US{1'000'000};
std::optional<std::string> CheckTestDelayOption(const std::string& name, int64_t value, bool is_regtest);

} // namespace iocounters

#endif // BITCOIN_UTIL_IO_COUNTERS_H
